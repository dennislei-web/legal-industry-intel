"""
司法院官方案件統計管線（各級法院各案類新收及終結件數統計）

資料來源：司法院資料開放平臺 datasetId 43994「各級法院各案類新收及終結件數統計」，
公開資料集（不需會員 token），單一 ODS 檔（~18MB，解壓後 content.xml ~600MB），
民國 90 年起、月 × 法院 × 案件種類 × 三層訴訟程序別的新收/終結件數，約 50 萬列。

處理：串流解析 ODS（不整檔載入記憶體）→ 去除欄位值的數字編號前綴 →
聚合到訴訟程序別第 1 層 → 全量 upsert 到 court_case_stats（冪等，來源修訂會覆蓋）。

已知來源特性：
- 最高法院各案類新收件數恆為 0（來源只填終結），前端呈現最高法院時用終結數
- 「民事」案件種類含民執程序（proc_l1='民執'），與統計月報「強制執行」口徑不同

用法:
  python judicial_official_stats.py download        # 下載 ODS 到 work dir
  python judicial_official_stats.py parse           # 解析 + 聚合 → JSON
  python judicial_official_stats.py upload          # JSON → Supabase（批次 upsert）
  python judicial_official_stats.py run             # download + parse + upload 一條龍
"""
import io
import os
import re
import sys
import json
import time
import zipfile
import xml.etree.ElementTree as ET
from collections import defaultdict
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}
OPENDATA = 'https://opendata.judicial.gov.tw'
FILESET_ID = os.environ.get('JUDICIAL_COURT_STATS_FILESET', '55709')  # datasetId 43994 的檔案集

WORK_DIR = os.environ.get('JUDICIAL_STATS_WORK_DIR') or os.path.join(os.path.dirname(__file__), '.official_stats_work')
os.makedirs(WORK_DIR, exist_ok=True)
ODS_PATH = os.path.join(WORK_DIR, 'court_case_stats.ods')
AGG_PATH = os.path.join(WORK_DIR, 'court_case_stats.json')

NS_TABLE = '{urn:oasis:names:tc:opendocument:xmlns:table:1.0}'
NS_TEXT = '{urn:oasis:names:tc:opendocument:xmlns:text:1.0}'

PREFIX_RE = re.compile(r'^\d+')


def strip_prefix(v):
    """'06地方法院' → '地方法院'；'01臺灣臺北地方法院' → '臺灣臺北地方法院'"""
    return PREFIX_RE.sub('', v).strip()


# ============================================================
# 下載
# ============================================================

def download():
    url = f'{OPENDATA}/api/FilesetLists/{FILESET_ID}/file'
    print(f'下載 {url} ...')
    r = requests.get(url, timeout=600, verify=False, stream=True)
    r.raise_for_status()
    tmp = ODS_PATH + '.part'
    size = 0
    with open(tmp, 'wb') as f:
        for chunk in r.iter_content(1 << 20):
            f.write(chunk)
            size += len(chunk)
    os.replace(tmp, ODS_PATH)
    print(f'完成，{size / 1e6:.1f} MB → {ODS_PATH}')
    # 基本健檢：必須是 zip（ODS）
    if not zipfile.is_zipfile(ODS_PATH):
        raise RuntimeError('下載的檔案不是 ODS/zip，來源可能異動')


# ============================================================
# 解析 + 聚合
# ============================================================

def parse():
    if not os.path.exists(ODS_PATH):
        raise RuntimeError(f'找不到 {ODS_PATH}，先跑 download')
    print(f'串流解析 {ODS_PATH} ...')
    z = zipfile.ZipFile(ODS_PATH)
    f = z.open('content.xml')
    agg = defaultdict(lambda: [0, 0])  # key → [new, closed]
    levels = {}                        # court_name → court_level
    rows = bad = 0
    years = set()
    t0 = time.time()
    for _, el in ET.iterparse(f, events=('end',)):
        if el.tag != NS_TABLE + 'table-row':
            continue
        cells = []
        for c in el.iter(NS_TABLE + 'table-cell'):
            rep = int(c.get(NS_TABLE + 'number-columns-repeated', 1))
            txt = ''.join(p.text or '' for p in c.iter(NS_TEXT + 'p'))
            cells.extend([txt] * min(rep, 12))
        el.clear()
        rows += 1
        # 欄位：年別 月別 各級法院 法院別 案件種類 程序別1 程序別2 程序別3 新收 終結
        if len(cells) < 10 or not cells[0].isdigit() or not cells[1].isdigit():
            continue  # 表頭或空列
        try:
            y, m = int(cells[0]), int(cells[1])
            new, closed = int(cells[8] or 0), int(cells[9] or 0)
        except ValueError:
            bad += 1
            continue
        level = strip_prefix(cells[2])
        court = strip_prefix(cells[3])
        cat = strip_prefix(cells[4])
        l1 = strip_prefix(cells[5])
        if not court or not cat:
            bad += 1
            continue
        k = (y, m, court, cat, l1)
        agg[k][0] += new
        agg[k][1] += closed
        levels[court] = level
        years.add(y)
        if rows % 100000 == 0:
            print(f'  ...{rows} 列（{time.time() - t0:.0f}s）')
    out = [
        {'year_tw': y, 'month': m, 'court_level': levels[court], 'court_name': court,
         'case_category': cat, 'proc_l1': l1, 'new_cases': v[0], 'closed_cases': v[1]}
        for (y, m, court, cat, l1), v in agg.items()
    ]
    with io.open(AGG_PATH, 'w', encoding='utf-8') as fo:
        json.dump(out, fo, ensure_ascii=False)
    print(f'完成：原始 {rows} 列 → 聚合 {len(out)} 列（壞列 {bad}），'
          f'年度 {min(years)}-{max(years)}，{time.time() - t0:.0f}s → {AGG_PATH}')


# ============================================================
# 上傳
# ============================================================

def upload(batch_size=1000):
    if not os.path.exists(AGG_PATH):
        raise RuntimeError(f'找不到 {AGG_PATH}，先跑 parse')
    records = json.load(io.open(AGG_PATH, encoding='utf-8'))
    print(f'上傳 {len(records)} 列到 court_case_stats（batch {batch_size}）...')
    url = (f'{SUPABASE_URL}/rest/v1/court_case_stats'
           f'?on_conflict=year_tw,month,court_name,case_category,proc_l1')
    headers = {**HEADERS_SB, 'Content-Type': 'application/json',
               'Prefer': 'resolution=merge-duplicates,return=minimal'}
    t0 = time.time()
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        for attempt in range(3):
            r = requests.post(url, headers=headers, json=batch, timeout=120)
            if r.status_code in (200, 201, 204):
                break
            print(f'  batch {i // batch_size} 失敗 HTTP {r.status_code}: {r.text[:200]}，重試 {attempt + 1}/3')
            time.sleep(5 * (attempt + 1))
        else:
            raise RuntimeError(f'batch {i // batch_size} 連續失敗，中止')
        if (i // batch_size) % 20 == 0:
            print(f'  ...{i + len(batch)}/{len(records)}（{time.time() - t0:.0f}s）')
        time.sleep(0.3)  # Micro compute，別打太兇
    # 驗證
    r = requests.get(f'{SUPABASE_URL}/rest/v1/court_case_stats?select=*&limit=0',
                     headers={**HEADERS_SB, 'Prefer': 'count=exact'}, timeout=60)
    total = r.headers.get('content-range', '?').split('/')[-1]
    print(f'完成，{time.time() - t0:.0f}s；DB 現有總列數: {total}')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'run'
    requests.packages.urllib3.disable_warnings()
    if cmd == 'download':
        download()
    elif cmd == 'parse':
        parse()
    elif cmd == 'upload':
        upload()
    elif cmd == 'run':
        download()
        parse()
        upload()
    else:
        print(__doc__)
        sys.exit(1)
