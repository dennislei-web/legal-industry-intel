"""
終結案件資料月包 → 案件層級微資料聚合管線

資料來源：司法院資料開放平臺「YYY年M月司法院及所屬各級法院之終結案件資料與欄位說明」
（公開、免會員 token），每月一個 7z（~1MB），內含每法院×案類一個 `!` 分隔 txt，
每案一筆。晚約 1.5 個月發布（例：2026-06 中發布 115年5月包）。

目前只解析「民事訴訟」「家事訴訟」檔（兩者同版式）：
  欄位：0控制碼 1法院別 2案號年 3字別 4號 5案由 6-8法官名 9-12原審
        13原告有律師 14被告有律師 15-17終結年月日 18-21終結情形1-4
        22-25得上訴/抗告 26-27上訴/結果 28幣別 29標的金額 ...
版式防呆：15-17 必須是合理民國日期，不符的列跳過並計數（保護版式漂移/其他檔型）。
court_name 用月包資料夾名（地院與 judge_month_stats 格式一致）。
刑事檔是階層式（案-被告-罪名，被告列含「選任律師辯護」），尚未納入。

產出：closed_case_month_stats（月×法院×檔型：委任率/終結情形分布/標的金額）

用法:
  python closed_case_stats.py run 202605      # 跑指定西元年月
  python closed_case_stats.py auto            # 找最新月包，DB 沒有才跑（workflow 用）
  python closed_case_stats.py backfill        # 回填 API 上所有月包（跳過 DB 已有的）

需要 7z 可執行檔（本機 scoop 已裝；GitHub Actions 需 apt install p7zip-full）。
"""
import io
import os
import re
import sys
import json
import time
import glob
import shutil
import subprocess
from collections import defaultdict, Counter
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}
OPENDATA = 'https://opendata.judicial.gov.tw'
SEVENZ = os.environ.get('SEVENZ_PATH', '7z')
WORK_DIR = os.environ.get('CLOSED_CASE_WORK_DIR') or os.path.join(os.path.dirname(__file__), '.closed_case_work')
os.makedirs(WORK_DIR, exist_ok=True)

FILE_TYPES = ('民事訴訟', '家事訴訟')
TITLE_RE = re.compile(r'^(\d{3})年(\d{1,2})月司法院及所屬各級法院之終結案件資料')


# ============================================================
# 資料集清單
# ============================================================

def list_datasets():
    """回傳 {西元yyyymm: fileSetId}（只含月包，不含 105/106/108 年整年包）"""
    out = {}
    page = 1
    while True:
        r = requests.get(f'{OPENDATA}/api/Datasets', params={
            'Keyword': '終結案件資料', 'ItemsPerPage': 50, 'Page': page,
        }, timeout=60, verify=False)
        r.raise_for_status()
        items = r.json()['pagedList']['items']
        if not items:
            break
        for it in items:
            m = TITLE_RE.match(it['title'])
            if not m:
                continue
            ym = f'{int(m.group(1)) + 1911}{int(m.group(2)):02d}'
            for fs in it.get('filesetLists') or []:
                if '終結案件資料' in (fs.get('resourceDescription') or ''):
                    out[ym] = fs['fileSetId']
        page += 1
        if page > 20:
            break
    return out


def existing_months():
    """DB 已有資料的 yyyymm 集合"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/closed_case_month_stats?select=yyyymm&limit=10000',
                     headers=HEADERS_SB, timeout=60)
    r.raise_for_status()
    return {x['yyyymm'] for x in r.json()}


# ============================================================
# 單月處理
# ============================================================

def parse_line(line):
    """回傳 (p_rep, d_rep, outcome, amount) 或 None（版式不符）"""
    c = line.split('!')
    if len(c) < 30 or c[0] != '0':
        return None
    try:
        y, m, d = int(c[15]), int(c[16]), int(c[17])
    except ValueError:
        return None
    if not (90 <= y <= 130 and 1 <= m <= 12 and 1 <= d <= 31):
        return None
    p_rep = c[13] == '1'
    d_rep = c[14] == '1'
    outcome = c[18].strip() or '未填'
    amount = None
    if c[28] == '新台幣':
        try:
            amount = float(c[29])
        except ValueError:
            pass
    return p_rep, d_rep, outcome, amount


def run_month(yyyymm, fileset_id):
    print(f'=== {yyyymm}（fileSetId {fileset_id}）===')
    arc = os.path.join(WORK_DIR, f'{yyyymm}.7z')
    ext = os.path.join(WORK_DIR, yyyymm)
    r = requests.get(f'{OPENDATA}/api/FilesetLists/{fileset_id}/file',
                     timeout=600, verify=False)
    r.raise_for_status()
    with open(arc, 'wb') as f:
        f.write(r.content)
    print(f'  下載 {len(r.content) / 1e6:.1f} MB')
    if os.path.isdir(ext):
        shutil.rmtree(ext)
    subprocess.run([SEVENZ, 'x', '-y', arc, f'-o{ext}'],
                   check=True, capture_output=True)

    agg = defaultdict(lambda: {'total': 0, 'p': 0, 'd': 0, 'both': 0,
                               'outcomes': Counter(), 'amt': 0.0, 'amt_n': 0})
    skipped = 0
    for ft in FILE_TYPES:
        for path in glob.glob(os.path.join(ext, '**', f'*.{ft}.txt'), recursive=True):
            court = os.path.basename(os.path.dirname(path))
            try:
                lines = io.open(path, encoding='utf-8-sig').read().splitlines()
            except UnicodeDecodeError:
                lines = io.open(path, encoding='cp950', errors='replace').read().splitlines()
            for line in lines:
                if not line or line == '#':
                    continue
                parsed = parse_line(line)
                if parsed is None:
                    if line.startswith('0!'):
                        skipped += 1
                    continue
                p_rep, d_rep, outcome, amount = parsed
                a = agg[(court, ft)]
                a['total'] += 1
                a['p'] += p_rep
                a['d'] += d_rep
                a['both'] += (p_rep and d_rep)
                a['outcomes'][outcome] += 1
                if amount:
                    a['amt'] += amount
                    a['amt_n'] += 1

    records = [
        {'yyyymm': yyyymm, 'court_name': court, 'file_type': ft,
         'total_cases': a['total'], 'plaintiff_rep': a['p'], 'defendant_rep': a['d'],
         'both_rep': a['both'], 'outcomes': dict(a['outcomes']),
         'amount_sum': a['amt'] or None, 'amount_n': a['amt_n']}
        for (court, ft), a in agg.items()
    ]
    print(f'  解析 {sum(r["total_cases"] for r in records)} 案 → {len(records)} 列（跳過 {skipped} 列）')
    if records:
        url = f'{SUPABASE_URL}/rest/v1/closed_case_month_stats?on_conflict=yyyymm,court_name,file_type'
        headers = {**HEADERS_SB, 'Content-Type': 'application/json',
                   'Prefer': 'resolution=merge-duplicates,return=minimal'}
        resp = requests.post(url, headers=headers, json=records, timeout=120)
        if resp.status_code not in (200, 201, 204):
            raise RuntimeError(f'上傳失敗 HTTP {resp.status_code}: {resp.text[:300]}')
        print(f'  上傳 OK')
    # 清理磁碟
    os.remove(arc)
    shutil.rmtree(ext, ignore_errors=True)


# ============================================================
# 模式
# ============================================================

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'auto'
    requests.packages.urllib3.disable_warnings()
    datasets = list_datasets()
    print(f'API 月包清單：{min(datasets)} ~ {max(datasets)}（{len(datasets)} 個月）')
    if cmd == 'run':
        ym = sys.argv[2]
        if ym not in datasets:
            raise RuntimeError(f'{ym} 不在 API 清單中')
        run_month(ym, datasets[ym])
    elif cmd == 'auto':
        have = existing_months()
        todo = sorted(set(datasets) - have)
        if not todo:
            print('DB 已是最新，無事可做')
            return
        # 只跑最新的缺月（避免排程一次跑太久；歷史缺口用 backfill）
        ym = todo[-1]
        run_month(ym, datasets[ym])
    elif cmd == 'backfill':
        have = existing_months()
        todo = sorted(set(datasets) - have)
        print(f'待回填 {len(todo)} 個月：{todo[:5]}...{todo[-3:]}' if todo else '無缺月')
        for ym in todo:
            run_month(ym, datasets[ym])
            time.sleep(1)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
