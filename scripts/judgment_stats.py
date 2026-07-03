"""
裁判書開放資料 → 法官統計管線

資料來源：司法院資料開放平臺（opendata.judicial.gov.tw），每月一個 RAR 打包
（每份裁判書一個 JSON，欄位：ID/JYEAR/JCASE/JNO/JDATE/JTITLE/JFULL/JPDF），
發布晚兩個月（例：2026-06 發布 2025-04 的包）。不需帳號、不需爬網頁。

產出：judge_month_stats 表（每法官×法院×月的聚合），再由 DB 端 RPC
refresh_judge_judgment_stats() 彙總成 judge_judgment_stats 供前端 view 使用。

用法:
  python judgment_stats.py download 202504          # 下載該月 RAR 到 work dir
  python judgment_stats.py parse 202504             # 解析 RAR → 聚合 JSON
  python judgment_stats.py upload 202504            # 聚合 JSON → Supabase
  python judgment_stats.py run 202504               # download + parse + upload 一條龍
  python judgment_stats.py backfill 202001 202504   # 依序跑一段區間（跳過已上傳的月份）

需要 7z 可執行檔（本機 scoop 已裝；GitHub Actions 需 apt install p7zip-full p7zip-rar）。
"""
import io
import os
import re
import sys
import json
import time
import subprocess
from collections import defaultdict
from datetime import date
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}
OPENDATA = 'https://opendata.judicial.gov.tw'
# 裁判書資料集是「會員限定」，下載需先登入取 token（效期約 24h，不需 Turnstile）
OD_USER = os.environ.get('JUDICIAL_OPENDATA_USER', '').strip()
OD_PWD = os.environ.get('JUDICIAL_OPENDATA_PWD', '').strip()
_od_token = None


def get_od_token():
    global _od_token
    if _od_token:
        return _od_token
    if not OD_USER:
        raise RuntimeError('缺 JUDICIAL_OPENDATA_USER/PWD（opendata.judicial.gov.tw 會員帳號）')
    r = requests.post(f'{OPENDATA}/api/MemberTokens', json={
        'memberAccount': OD_USER, 'pwd': OD_PWD,
    }, timeout=60, verify=False)
    r.raise_for_status()
    _od_token = r.json()['token']
    return _od_token
WORK_DIR = os.environ.get('JUDGMENT_WORK_DIR') or os.path.join(os.path.dirname(__file__), '.judgment_work')
SEVENZ = os.environ.get('SEVENZ_PATH', '7z')

os.makedirs(WORK_DIR, exist_ok=True)


# ============================================================
# 下載
# ============================================================

def find_fileset(yyyymm):
    """用關鍵字搜尋該月資料集，回傳 fileSetId"""
    r = requests.get(f'{OPENDATA}/api/Datasets', params={
        'Keyword': f'{yyyymm}裁判書', 'ItemsPerPage': 10, 'Page': 1,
    }, timeout=60, verify=False)
    r.raise_for_status()
    for it in r.json()['pagedList']['items']:
        # 標題格式：202504裁判書 或 202504裁判書--(20260615Update)
        if it['title'].startswith(f'{yyyymm}裁判書'):
            fs = it.get('filesetLists') or []
            if fs:
                return fs[0]['fileSetId'], it['title']
    return None, None


def download(yyyymm):
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    if os.path.exists(rar_path) and os.path.getsize(rar_path) > 1024 * 1024:
        print(f'  {yyyymm}.rar 已存在（{os.path.getsize(rar_path)/1e6:.0f} MB），跳過下載')
        return rar_path
    fileset_id, title = find_fileset(yyyymm)
    if not fileset_id:
        raise RuntimeError(f'找不到 {yyyymm} 的裁判書資料集（可能尚未發布）')
    print(f'  下載 {title}（fileSetId={fileset_id}）...')
    t0 = time.time()
    with requests.get(f'{OPENDATA}/api/FilesetLists/{fileset_id}/file',
                      headers={'Authorization': f'Bearer {get_od_token()}'},
                      stream=True, timeout=7200, verify=False) as r:
        r.raise_for_status()
        with open(rar_path + '.part', 'wb') as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
    os.replace(rar_path + '.part', rar_path)
    print(f'  完成：{os.path.getsize(rar_path)/1e6:.0f} MB，{(time.time()-t0)/60:.1f} 分鐘')
    return rar_path


# ============================================================
# 解析
# ============================================================

# 只取判決書結尾的合議庭/獨任法官署名。抓最後 3000 字內的
# 「(審判長)法 官 姓名」列，姓名 2-4 個漢字（不含空白時）或全形空白分隔。
RE_JUDGE = re.compile(
    r'(?:審判長)?法\s*官\s+([一-鿿][一-鿿\s　]{0,8}[一-鿿])\s*(?:\r|\n|$)')
RE_COURT = re.compile(r'^([一-鿿]{2,15}法院)')
RE_NOT_JUDGE_LINE = re.compile(r'書\s*記\s*官|檢\s*察\s*官|辯\s*護\s*人|司法事務官|法官助理')

# 字別 → 案類（粗分）。JID 內含裁判類別碼，但月包檔名/ID 較可靠的是全文首行。
CAT_BY_DOCNAME = [('刑事', '刑事'), ('民事', '民事'), ('行政', '行政'),
                  ('家事', '家事'), ('少年', '少年'), ('懲戒', '懲戒')]


def extract_judges(jfull):
    """從裁判書全文結尾抽出法官姓名（去重、排除書記官等）"""
    tail = jfull[-3000:]
    names = []
    for m in RE_JUDGE.finditer(tail):
        # 該列若同時含書記官等字樣則跳過
        line_start = tail.rfind('\n', 0, m.start()) + 1
        line = tail[line_start: m.end()]
        if RE_NOT_JUDGE_LINE.search(line):
            continue
        name = re.sub(r'[\s　]', '', m.group(1))
        if 2 <= len(name) <= 4 and name not in names:
            names.append(name)
    return names


def classify(jfull_head, jcase):
    for kw, cat in CAT_BY_DOCNAME:
        if kw in jfull_head:
            return cat
    return '其他'


def parse(yyyymm):
    """解壓並逐檔解析，聚合成 (法官, 法院) × 月 的統計 JSON"""
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_agg.json')
    if os.path.exists(out_path):
        print(f'  {yyyymm}_agg.json 已存在，跳過解析')
        return out_path

    # 7z 列出檔名，逐檔用 7z e -so 串流讀出（避免全部解壓佔磁碟）
    # 實測月包內為多層目錄，JSON 檔數十萬個 → 全解壓到暫存目錄較快
    extract_dir = os.path.join(WORK_DIR, yyyymm)
    if not os.path.isdir(extract_dir):
        print(f'  解壓 {yyyymm}.rar ...')
        r = subprocess.run([SEVENZ, 'x', rar_path, f'-o{extract_dir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 解壓失敗: {r.stderr[:500]}')

    # 聚合鍵：(name, court) → {n, sum_days, cats{}, years{}}
    agg = defaultdict(lambda: {'n': 0, 'sum_days': 0, 'n_days': 0,
                               'cats': defaultdict(int)})
    n_files = 0
    n_no_judge = 0
    t0 = time.time()
    for root, _dirs, files in os.walk(extract_dir):
        for fn in files:
            if not fn.endswith('.json'):
                continue
            n_files += 1
            try:
                with open(os.path.join(root, fn), encoding='utf-8-sig') as f:
                    doc = json.load(f)
            except (json.JSONDecodeError, OSError):
                continue
            jfull = doc.get('JFULL') or ''
            if not jfull:
                continue
            judges = extract_judges(jfull)
            if not judges:
                n_no_judge += 1
                continue
            head = jfull[:60]
            mc = RE_COURT.search(head.strip())
            court = mc.group(1) if mc else '未知法院'
            cat = classify(head, doc.get('JCASE') or '')
            # 審理天數估算：裁判日 - 案號年度起算日（民國年 1/1）。有一致性偏差，
            # 僅供法官間相對比較，前端標示「估算」。
            days = None
            try:
                jdate = str(doc.get('JDATE') or '')
                jyear = int(doc.get('JYEAR') or 0)
                if len(jdate) == 8 and jyear > 0:
                    d = date(int(jdate[:4]), int(jdate[4:6]), int(jdate[6:8]))
                    days = (d - date(1911 + jyear, 1, 1)).days
                    if days < 0 or days > 3650:
                        days = None
            except ValueError:
                days = None
            for name in judges:
                a = agg[(name, court)]
                a['n'] += 1
                a['cats'][cat] += 1
                if days is not None:
                    a['sum_days'] += days
                    a['n_days'] += 1
            if n_files % 50000 == 0:
                print(f'  ...{n_files} 檔，{(time.time()-t0)/60:.1f} 分', flush=True)

    rows = [{'name': k[0], 'court_name': k[1], 'yyyymm': yyyymm,
             'case_count': v['n'], 'sum_days': v['sum_days'], 'n_days': v['n_days'],
             'cats': dict(v['cats'])} for k, v in agg.items()]
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False)
    print(f'  解析完成：{n_files} 份裁判書，{len(rows)} 個 (法官,法院) 組合，'
          f'{n_no_judge} 份未抽到法官，{(time.time()-t0)/60:.1f} 分鐘')
    return out_path


# ============================================================
# 上傳
# ============================================================

def month_uploaded(yyyymm):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/judge_month_stats',
                     params={'yyyymm': f'eq.{yyyymm}', 'select': 'yyyymm', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def upload(yyyymm):
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_agg.json')
    with open(out_path, encoding='utf-8') as f:
        rows = json.load(f)
    print(f'  上傳 {len(rows)} 列到 judge_month_stats ...')
    # 先刪同月舊資料（冪等重跑）
    requests.delete(f'{SUPABASE_URL}/rest/v1/judge_month_stats',
                    params={'yyyymm': f'eq.{yyyymm}'},
                    headers=HEADERS_SB, timeout=60, verify=False)
    for i in range(0, len(rows), 500):
        batch = rows[i:i + 500]
        r = requests.post(f'{SUPABASE_URL}/rest/v1/judge_month_stats',
                          json=batch,
                          headers={**HEADERS_SB, 'Content-Type': 'application/json',
                                   'Prefer': 'return=minimal'},
                          timeout=120, verify=False)
        if r.status_code not in (200, 201, 204):
            raise RuntimeError(f'上傳失敗 {r.status_code}: {r.text[:300]}')
        time.sleep(1)
    print('  上傳完成')


def refresh_stats():
    print('  呼叫 refresh_judge_judgment_stats() ...')
    r = requests.post(f'{SUPABASE_URL}/rest/v1/rpc/refresh_judge_judgment_stats',
                      json={}, headers={**HEADERS_SB, 'Content-Type': 'application/json'},
                      timeout=300, verify=False)
    print(f'  HTTP {r.status_code}')


def cleanup(yyyymm):
    """刪掉解壓目錄（保留 rar 與 agg.json）以省磁碟"""
    import shutil
    d = os.path.join(WORK_DIR, yyyymm)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)


def run_month(yyyymm, skip_uploaded=False):
    if skip_uploaded and month_uploaded(yyyymm):
        print(f'{yyyymm}: 已上傳過，跳過')
        return
    print(f'=== {yyyymm} ===')
    download(yyyymm)
    parse(yyyymm)
    upload(yyyymm)
    cleanup(yyyymm)


def month_range(start, end):
    y, m = int(start[:4]), int(start[4:])
    while f'{y}{m:02d}' <= end:
        yield f'{y}{m:02d}'
        m += 1
        if m > 12:
            y, m = y + 1, 1


if __name__ == '__main__':
    import urllib3
    urllib3.disable_warnings()
    cmd = sys.argv[1]
    if cmd == 'download':
        download(sys.argv[2])
    elif cmd == 'parse':
        parse(sys.argv[2])
    elif cmd == 'upload':
        upload(sys.argv[2])
        refresh_stats()
    elif cmd == 'run':
        run_month(sys.argv[2])
        refresh_stats()
    elif cmd == 'backfill':
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                run_month(ym, skip_uploaded=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}')
        refresh_stats()
    else:
        print(__doc__)
