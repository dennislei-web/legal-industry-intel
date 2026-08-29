"""
終結案件資料月包 → 案件層級微資料聚合管線

資料來源：司法院資料開放平臺「YYY年M月司法院及所屬各級法院之終結案件資料與欄位說明」
（公開、免會員 token），每月一個 7z（~1MB），內含每法院×案類一個 `!` 分隔 txt，
每案一筆。晚約 1.5 個月發布（例：2026-06 中發布 115年5月包）。

解析「民事訴訟」「家事訴訟」檔（兩者同版式）：
  欄位：0控制碼 1法院別 2案號年 3字別 4號 5案由 6-8法官名 9-12原審
        13原告有律師 14被告有律師 15-17終結年月日 18-21終結情形1-4
        22-25得上訴/抗告 26-27上訴/結果 28幣別 29標的金額 ...
  （高院系民訴檔幣別/金額在欄 27/28，parse_line 掃「新台幣」欄通吃兩版式；
   最高法院民訴版式整體不同，被日期防呆擋掉、不納入）
版式防呆：15-17 必須是合理民國日期，不符的列跳過並計數（保護版式漂移/其他檔型）。
court_name 用月包資料夾名（地院與 judge_month_stats 格式一致）。

案由細分（migration 064，mapping 見 cause_map.py）：
  民事訴訟/家事訴訟（案由=欄5）＋民事非訟/家事非訟（案由=欄5、日期在欄13-15）
  ＋刑事訴訟罪名層（1.1 列：1法名 2條 3條之N 9裁判結果；每被告取第一個罪名層
  當主要罪名，計數單位=被告人次，科刑=有期徒刑/拘役/罰金/無期/死刑）
  → closed_case_cause_stats（月×法院×檔型×種類）
  → closed_case_cause_national（月×檔型×正規化原始案由）

「刑事訴訟」檔是階層式（0!案件層 → 1!被告層 → 1.1!罪名層），只解析資料夾名含
「地方法院」者（高院/最高/智財被告層辯護欄位置不同，見官方欄位說明文件）：
  案件層：13-15 終結年月日、16 終結情形、21 自訴人是否有律師代理
  被告層：4 辯護及代理（選任律師辯護[-法律扶助]/公設辯護人辯護/義務律師辯護/空）
  聚合：defendant_rep=任一被告「選任律師辯護」開頭的案件數（=有委任律師口徑），
        plaintiff_rep=自訴人有律師件數，defense=被告層辯護分布（被告數計）

產出：closed_case_month_stats（月×法院×檔型：委任率/終結情形分布/標的金額）

用法:
  python closed_case_stats.py run 202605       # 跑指定西元年月
  python closed_case_stats.py auto             # 找最新月包，DB 沒有才跑（workflow 用）
  python closed_case_stats.py backfill         # 回填 API 上所有月包（跳過 DB 已有的）
  python closed_case_stats.py backfill-criminal  # 回填缺「刑事訴訟」列的月份（民事重跑 upsert 冪等）
  python closed_case_stats.py backfill-causes   # 回填 cause 表缺的月份（整月重跑，全部 upsert 冪等）
  python closed_case_stats.py backfill-amount   # 回填標的金額×委任表缺的月份（整月重跑，upsert 冪等）
  python closed_case_stats.py backfill-rep      # 回填案由×委任表缺的月份（整月重跑，upsert 冪等）

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

from cause_map import norm_cause, map_cause, map_criminal, map_judgment

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
NONLIT_TYPES = ('民事非訟', '家事非訟')
TITLE_RE = re.compile(r'^(\d{3})年(\d{1,2})月司法院及所屬各級法院之終結案件資料')

# 訴訟標的金額級距桶（migration 087；單位=元）→「金額×是否委任」交叉。
# (label, 上界含) ；末桶無上界。0 桶=標的金額為 0（實務極少，非財產訴訟多為無金額欄不入表）
AMOUNT_BUCKETS = [
    ('0', 0),
    ('1-10萬', 100_000),
    ('10-50萬', 500_000),
    ('50-100萬', 1_000_000),
    ('100-500萬', 5_000_000),
    ('500-1000萬', 10_000_000),
    ('1000萬+', None),
]
AMOUNT_BUCKET_ORDER = [b[0] for b in AMOUNT_BUCKETS]


def amount_bucket(amt):
    """標的金額（元）落入級距桶 label；amt<=0 → '0'，超過 1000 萬 → '1000萬+'"""
    if amt <= 0:
        return '0'
    for label, hi in AMOUNT_BUCKETS[1:-1]:
        if amt <= hi:
            return label
    return '1000萬+'


def norm_court(name):
    """月包資料夾名正規化：202101~202506 帶「民事/刑事」後綴、偶有空格，
    去掉以與 courts.name / court_case_stats 對齊（migration 045 已清理歷史資料）"""
    return re.sub(r'(民事|刑事)$', '', name.replace(' ', ''))


def read_lines(path):
    """讀月包 txt。本機 Windows 跑時，7z 對少數中文檔名解壓不全會讓 glob 列出的
    路徑 open 不到（FileNotFoundError）——容錯跳過該檔回 None（印 warning 供事後查），
    避免整趟 backfill 中止。零星壞檔對全國聚合影響可忽略。"""
    try:
        return io.open(path, encoding='utf-8-sig').read().splitlines()
    except UnicodeDecodeError:
        return io.open(path, encoding='cp950', errors='replace').read().splitlines()
    except OSError as e:
        print(f'  ⚠️ 跳過讀取失敗檔（{type(e).__name__}）：{os.path.basename(path)}')
        return None


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


def existing_months(file_type=None):
    """DB 已有資料的 yyyymm 集合（可限定檔型）"""
    url = f'{SUPABASE_URL}/rest/v1/closed_case_month_stats?select=yyyymm&limit=50000'
    if file_type:
        url += f'&file_type=eq.{file_type}'
    r = requests.get(url, headers=HEADERS_SB, timeout=60)
    r.raise_for_status()
    return {x['yyyymm'] for x in r.json()}


# ============================================================
# 單月處理
# ============================================================

def parse_line(line):
    """回傳 (p_rep, d_rep, outcome, amount, cause) 或 None（版式不符）"""
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
    # 金額欄位置版式不同：地院=欄28/29、高院=欄27/28（左移一欄）——
    # 掃整列找「新台幣」欄（exact match）取下一欄，兩版式通吃；
    # 最高法院民訴版式整體不同，已被上面的日期防呆擋掉
    try:
        amount = float(c[c.index('新台幣') + 1])
    except (ValueError, IndexError):
        pass
    return p_rep, d_rep, outcome, amount, norm_cause(c[5])


def parse_nonlit_line(line):
    """民事非訟/家事非訟列（日期在欄 13-15）→ 正規化案由，版式不符回 None"""
    c = line.split('!')
    if len(c) < 17 or c[0] != '0':
        return None
    try:
        y, m, d = int(c[13]), int(c[14]), int(c[15])
    except ValueError:
        return None
    if not (90 <= y <= 130 and 1 <= m <= 12 and 1 <= d <= 31):
        return None
    return norm_cause(c[5])


CONVICT_OUTCOMES = ('有期徒刑', '拘役', '罰金', '無期徒刑', '死刑')


def parse_criminal_file(lines, a, add_cause):
    """解析單一地院刑事訴訟檔（階層式），聚合進 a，回傳跳過列數
    add_cause(cause, group, convicted)：每被告第一個罪名層列（主要罪名）叫一次"""
    skipped = 0
    cur = None  # 當前有效案件 {'hired':bool,'self_rep':bool,'outcome':str}
    want_crime = False  # 目前被告尚未取得主要罪名

    def flush():
        nonlocal cur
        if cur is not None:
            a['total'] += 1
            a['d'] += cur['hired']
            a['p'] += cur['self_rep']
            a['outcomes'][cur['outcome']] += 1
            cur = None

    for line in lines:
        if not line or line == '#':
            continue
        c = line.split('!')
        if c[0] == '0':
            flush()
            want_crime = False
            ok = len(c) >= 28
            if ok:
                try:
                    y, m, d = int(c[13]), int(c[14]), int(c[15])
                    ok = 90 <= y <= 130 and 1 <= m <= 12 and 1 <= d <= 31
                except ValueError:
                    ok = False
            if not ok:
                skipped += 1
                continue
            cur = {'hired': False, 'self_rep': c[21] == '1',
                   'outcome': c[16].strip() or '未填'}
        elif c[0] == '1' and cur is not None and len(c) > 4:
            val = c[4].strip() or '無'
            a['defense'][val] += 1
            if val.startswith('選任律師辯護'):
                cur['hired'] = True
            want_crime = True
        elif c[0] == '1.1' and cur is not None and want_crime and len(c) > 9:
            cause, group = map_criminal(c[1], c[2], c[3])
            add_cause(cause, group, c[9].strip() in CONVICT_OUTCOMES)
            want_crime = False
    flush()
    return skipped


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
                               'outcomes': Counter(), 'amt': 0.0, 'amt_n': 0,
                               'defense': Counter()})
    # 案由細分聚合（migration 064）：
    # cagg (court, ft, group) / nagg (ft, cause, group) → [件數, 科刑數(刑事)]
    cagg = defaultdict(lambda: [0, 0])
    nagg = defaultdict(lambda: [0, 0])
    # 標的金額×委任交叉（migration 087）：(court, ft, bucket) → [n, repped_n]
    aragg = defaultdict(lambda: [0, 0])
    # 案由種類×委任情形交叉（migration 099）：(ft, group) → [total, both, p_only, d_only, none]
    # group 用 map_judgment()——跟供給面 lawyer_cause_stats 同一把尺（家事＝非訟細項優先），
    # 與 cagg/nagg 的 map_cause() 民事同規則、家事分桶不同
    repagg = defaultdict(lambda: [0, 0, 0, 0, 0])

    def add_cause(court, ft, cause, group, convicted=False):
        for k, d in ((( court, ft, group), cagg), ((ft, cause, group), nagg)):
            d[k][0] += 1
            d[k][1] += convicted

    skipped = 0
    # 刑事訴訟檔（僅地院版式）
    for path in glob.glob(os.path.join(ext, '**', '*.刑事訴訟.txt'), recursive=True):
        court = norm_court(os.path.basename(os.path.dirname(path)))
        if '地方法院' not in court:
            continue
        lines = read_lines(path)
        if lines is None:
            continue
        skipped += parse_criminal_file(
            lines, agg[(court, '刑事訴訟')],
            lambda cause, group, conv, _c=court: add_cause(_c, '刑事訴訟', cause, group, conv))
    for ft in FILE_TYPES:
        for path in glob.glob(os.path.join(ext, '**', f'*.{ft}.txt'), recursive=True):
            court = norm_court(os.path.basename(os.path.dirname(path)))
            lines = read_lines(path)
            if lines is None:
                continue
            for line in lines:
                if not line or line == '#':
                    continue
                parsed = parse_line(line)
                if parsed is None:
                    if line.startswith('0!'):
                        skipped += 1
                    continue
                p_rep, d_rep, outcome, amount, cause = parsed
                a = agg[(court, ft)]
                a['total'] += 1
                a['p'] += p_rep
                a['d'] += d_rep
                a['both'] += (p_rep and d_rep)
                a['outcomes'][outcome] += 1
                if amount:
                    a['amt'] += amount
                    a['amt_n'] += 1
                if amount is not None:
                    ar = aragg[(court, ft, amount_bucket(amount))]
                    ar[0] += 1
                    ar[1] += (p_rep or d_rep)
                add_cause(court, ft, cause, map_cause(ft, cause))
                rp = repagg[(ft, map_judgment('民事' if ft == '民事訴訟' else '家事', cause))]
                rp[0] += 1
                rp[1 if (p_rep and d_rep) else 2 if p_rep else 3 if d_rep else 4] += 1
    # 非訟檔（民事非訟/家事非訟）只做案由細分，不進 closed_case_month_stats
    for ft in NONLIT_TYPES:
        for path in glob.glob(os.path.join(ext, '**', f'*.{ft}.txt'), recursive=True):
            court = norm_court(os.path.basename(os.path.dirname(path)))
            lines = read_lines(path)
            if lines is None:
                continue
            for line in lines:
                if not line or line == '#':
                    continue
                cause = parse_nonlit_line(line)
                if cause is None:
                    if line.startswith('0!'):
                        skipped += 1
                    continue
                add_cause(court, ft, cause, map_cause(ft, cause))

    # 殘缺月包防呆（202511 曾被官方重傳成僅離島+簡易庭的殘缺版）：正常月包民事訴訟
    # 覆蓋 20+ 法院，低於門檻代表包不完整，中止上傳避免 upsert 蓋掉既有完整資料
    civil_courts = {court for (court, ft) in agg if ft == '民事訴訟'}
    if len(civil_courts) < 15:
        raise RuntimeError(f'{yyyymm} 月包疑似殘缺（民事訴訟僅 {len(civil_courts)} 法院），中止上傳')

    records = [
        {'yyyymm': yyyymm, 'court_name': court, 'file_type': ft,
         'total_cases': a['total'], 'plaintiff_rep': a['p'], 'defendant_rep': a['d'],
         'both_rep': a['both'], 'outcomes': dict(a['outcomes']),
         'amount_sum': a['amt'] or None, 'amount_n': a['amt_n'],
         'defense': dict(a['defense']) or None}
        for (court, ft), a in agg.items()
        if a['total'] > 0
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

    # 案由細分兩表（migration 064）
    c_rows = [{'yyyymm': yyyymm, 'court_name': k[0], 'file_type': k[1], 'cause_group': k[2],
               'case_count': v[0], 'convicted': v[1] if k[1] == '刑事訴訟' else None}
              for k, v in cagg.items()]
    n_rows = [{'yyyymm': yyyymm, 'file_type': k[0], 'cause': k[1], 'cause_group': k[2],
               'case_count': v[0], 'convicted': v[1] if k[0] == '刑事訴訟' else None}
              for k, v in nagg.items()]
    for table, conflict, rows in (
            ('closed_case_cause_stats', 'yyyymm,court_name,file_type,cause_group', c_rows),
            ('closed_case_cause_national', 'yyyymm,file_type,cause', n_rows)):
        url = f'{SUPABASE_URL}/rest/v1/{table}?on_conflict={conflict}'
        headers = {**HEADERS_SB, 'Content-Type': 'application/json',
                   'Prefer': 'resolution=merge-duplicates,return=minimal'}
        for i in range(0, len(rows), 2000):
            resp = requests.post(url, headers=headers, json=rows[i:i + 2000], timeout=120)
            if resp.status_code not in (200, 201, 204):
                raise RuntimeError(f'{table} 上傳失敗 HTTP {resp.status_code}: {resp.text[:300]}')
    print(f'  案由細分上傳 OK（法院層 {len(c_rows)} 列 / 全國案由層 {len(n_rows)} 列）')

    # 標的金額×委任交叉（migration 087）
    ar_rows = [{'yyyymm': yyyymm, 'court_name': k[0], 'file_type': k[1],
                'amount_bucket': k[2], 'n': v[0], 'repped_n': v[1]}
               for k, v in aragg.items()]
    if ar_rows:
        url = f'{SUPABASE_URL}/rest/v1/closed_case_amount_rep?on_conflict=yyyymm,court_name,file_type,amount_bucket'
        headers = {**HEADERS_SB, 'Content-Type': 'application/json',
                   'Prefer': 'resolution=merge-duplicates,return=minimal'}
        for i in range(0, len(ar_rows), 2000):
            resp = requests.post(url, headers=headers, json=ar_rows[i:i + 2000], timeout=120)
            if resp.status_code not in (200, 201, 204):
                raise RuntimeError(f'closed_case_amount_rep 上傳失敗 HTTP {resp.status_code}: {resp.text[:300]}')
    print(f'  標的金額×委任上傳 OK（{len(ar_rows)} 列）')

    # 案由種類×委任情形交叉（migration 099）
    rep_rows = [{'yyyymm': yyyymm, 'file_type': k[0], 'cause_group': k[1],
                 'n_total': v[0], 'n_both': v[1], 'n_p_only': v[2],
                 'n_d_only': v[3], 'n_none': v[4]}
                for k, v in repagg.items()]
    if rep_rows:
        url = f'{SUPABASE_URL}/rest/v1/closed_case_cause_rep_stats?on_conflict=yyyymm,file_type,cause_group'
        headers = {**HEADERS_SB, 'Content-Type': 'application/json',
                   'Prefer': 'resolution=merge-duplicates,return=minimal'}
        resp = requests.post(url, headers=headers, json=rep_rows, timeout=120)
        if resp.status_code not in (200, 201, 204):
            raise RuntimeError(f'closed_case_cause_rep_stats 上傳失敗 HTTP {resp.status_code}: {resp.text[:300]}')
    print(f'  案由×委任上傳 OK（{len(rep_rows)} 列）')
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
    elif cmd == 'backfill-criminal':
        # 回填缺「刑事訴訟」列的月份（重跑整月，民事/家事 upsert 冪等覆蓋）
        have = existing_months('刑事訴訟')
        todo = sorted(set(datasets) - have)
        print(f'待回填刑事 {len(todo)} 個月：{todo[:5]}...{todo[-3:]}' if todo else '無缺月')
        for ym in todo:
            run_month(ym, datasets[ym])
            time.sleep(1)
    elif cmd == 'backfill-causes':
        # 回填案由細分表缺的月份（重跑整月，全部 upsert 冪等）
        r = requests.post(f'{SUPABASE_URL}/rest/v1/rpc/closed_case_cause_months',
                          headers={**HEADERS_SB, 'Content-Type': 'application/json'},
                          json={}, timeout=60)
        r.raise_for_status()
        have = set(r.json() or [])
        # 注意：若官方月包被重傳成殘缺版（202511 曾發生，2026-07-08 已修復），
        # 重跑會把完整資料蓋成殘缺——回填前先抽查該月檔數（正常 ~300 檔/22 地院）
        todo = sorted(set(datasets) - have)
        print(f'待回填案由 {len(todo)} 個月：{todo[:5]}...{todo[-3:]}' if todo else '無缺月')
        for ym in todo:
            run_month(ym, datasets[ym])
            time.sleep(1)
    elif cmd == 'backfill-rep':
        # 回填案由×委任表缺的月份（重跑整月，全部 upsert 冪等）
        r = requests.post(f'{SUPABASE_URL}/rest/v1/rpc/closed_case_rep_months',
                          headers={**HEADERS_SB, 'Content-Type': 'application/json'},
                          json={}, timeout=60)
        r.raise_for_status()
        have = set(r.json() or [])
        todo = sorted(set(datasets) - have)
        print(f'待回填案由×委任 {len(todo)} 個月：{todo[:5]}...{todo[-3:]}' if todo else '無缺月')
        for ym in todo:
            run_month(ym, datasets[ym])
            time.sleep(1)
    elif cmd == 'backfill-amount':
        # 回填標的金額×委任表缺的月份（重跑整月，全部 upsert 冪等）。
        # 「已有」的判準＝該月已有高等法院金額列——高院金額欄位置與地院差一欄，
        # 2026-08 前的舊解析全漏（地院列都在，不能只看整月有無資料）。
        # PostgREST max-rows 上限 1000，須用 Range 分頁讀完（全量 ~2000 列）
        have = set()
        off = 0
        while True:
            r = requests.get(f'{SUPABASE_URL}/rest/v1/closed_case_amount_rep'
                             f'?select=yyyymm&court_name=like.*高等法院*&order=yyyymm',
                             headers={**HEADERS_SB, 'Range': f'{off}-{off + 999}'}, timeout=60)
            r.raise_for_status()
            batch = r.json()
            have |= {x['yyyymm'] for x in batch}
            if len(batch) < 1000:
                break
            off += 1000
        have.add('202307')  # 官方 202307 月包不含高院民訴檔（源頭缺，2026-08 重下載確認），重跑無益
        todo = sorted(set(datasets) - have)
        print(f'待回填金額 {len(todo)} 個月：{todo[:5]}...{todo[-3:]}' if todo else '無缺月')
        for ym in todo:
            run_month(ym, datasets[ym])
            time.sleep(1)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
