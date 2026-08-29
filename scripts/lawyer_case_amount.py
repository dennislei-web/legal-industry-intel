# -*- coding: utf-8 -*-
"""律師×訴訟標的金額 join 管線（mig 171：lawyer_case_amount_stats）

微資料側＝司法院「終結案件資料」月包（公開免會員）民事訴訟＋家事訴訟檔——
每列倒數第二欄本身就是完整 JID（如 SJEV,111,重簡,1381,20250103,2），帶官方
登錄的訴訟標的金額（幣別欄=新台幣、84.5% 民訴案有值）。
裁判書側＝client_concentration.py collect 產的 {ym}_clients.jsonl.gz
（scripts/.judgment_work/，每列 {lawyer, jid, cat, ...}）。

join key＝JID 前 4 段 (法院代碼, 民國年, 字別, 號)；clients 側**不按 cat 過濾**
（微資料民訴檔含高院家事二審，clients 標成家事 cat——202503 試跑：民事 cat
join 率 97.8%，全 cat 99.1%）。**快取按該案 JID 的裁判月查**（非終結月）——
2025-08 起約 1/3 案件裁判月早於終結月（宣示後隔月才報結），只查終結月快取
join 率會掉到 ~60%。聚合＝律師×終結月×金額桶案件數（微資料每案一列天然去重、
金額>0 才入桶）。同一趟另出 lawyer_case_fee_stats（mig 172，收費模型 v2：
律師×月的 200萬+ 件數/Σ超額標的/審級件數，母體同桶表）。
上傳前先 DELETE 該月再 INSERT（兩表皆重跑冪等）。

用法：
  python lawyer_case_amount.py run 202503            # 跑單月
  python lawyer_case_amount.py backfill 202111 202606  # 回填區間（跳過 DB 已有的月）
  python lawyer_case_amount.py refill 202111 202606    # 區間全部重跑（join 邏輯改版用）

前置：該月 clients 快取須已存在（沒有先跑 client_concentration.py collect）。
快取目錄可用環境變數 JUDGMENT_WORK_DIR 覆蓋（預設 scripts/.judgment_work）。
需要 7z 可執行檔（SEVENZ_PATH 可覆蓋）。
"""
import io
import os
import re
import sys
import json
import glob
import gzip
import time
import shutil
import subprocess
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
SEVENZ = os.environ.get('SEVENZ_PATH', '7z')
WORK_DIR = os.path.join(os.path.dirname(__file__), '.lca_work')
JW_DIR = os.environ.get('JUDGMENT_WORK_DIR') or os.path.join(os.path.dirname(__file__), '.judgment_work')
os.makedirs(WORK_DIR, exist_ok=True)

TABLE = 'lawyer_case_amount_stats'
FEE_TABLE = 'lawyer_case_fee_stats'  # mig 172：收費模型 v2 聚合（200萬超額/審級）
SURCHARGE_THRESHOLD = 2_000_000
SURCHARGE_CAP = 100_000_000  # mig 173：單案計費標的上限 1 億（逐案套 cap 後才加總）
APPEAL2_PREFIXES = ('TPH', 'TCH', 'TNH', 'KSH', 'HLH', 'KMH')  # 高等法院系
APPEAL3_PREFIXES = ('TPS',)  # 最高法院（微資料無民訴版式，實務恆 0）
FILE_TYPES = ('民事訴訟', '家事訴訟')
TITLE_RE = re.compile(r'^(\d{3})年(\d{1,2})月司法院及所屬各級法院之終結案件資料')
JID_RE = re.compile(r'^[A-Z]{2,6},\d{2,3},[^,]+,\d+,\d{8},\d+$')

# 桶口徑同 closed_case_stats.py AMOUNT_BUCKETS（金額>0 才入桶，無 0 桶）
BUCKETS = [
    ('1-10萬', 100_000),
    ('10-50萬', 500_000),
    ('50-100萬', 1_000_000),
    ('100-500萬', 5_000_000),
    ('500-1000萬', 10_000_000),
    ('1000萬+', None),
]


def amount_bucket(amt):
    for label, hi in BUCKETS[:-1]:
        if amt <= hi:
            return label
    return '1000萬+'


def key4(jid):
    p = jid.split(',')
    return (p[0], p[1].lstrip('0'), p[2], p[3].lstrip('0'))


def list_datasets():
    """回傳 {西元yyyymm: fileSetId}（同 closed_case_stats.py）"""
    out = {}
    page = 1
    while page <= 20:
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
    return out


def parse_month_cases(ext_dir):
    """解壓後月包 → 逐案 [(k4, jid裁判月, amount)]，僅民訴/家訴檔、金額>0
    （版式驗證同 closed_case_stats）。裁判月取 JID 第 5 段前 6 碼——2025-08 起
    約 1/3 案件裁判月早於終結月（宣示後隔月才報結），join 須按裁判月查快取。"""
    cases = []
    skipped = 0
    for ft in FILE_TYPES:
        for path in glob.glob(os.path.join(ext_dir, '**', f'*.{ft}.txt'), recursive=True):
            try:
                lines = io.open(path, encoding='utf-8-sig').read().splitlines()
            except UnicodeDecodeError:
                lines = io.open(path, encoding='cp950', errors='replace').read().splitlines()
            except OSError as e:
                print(f'  ⚠️ 跳過讀取失敗檔（{type(e).__name__}）：{os.path.basename(path)}')
                continue
            for line in lines:
                if not line.startswith('0!'):
                    continue
                c = line.split('!')
                if len(c) < 30:
                    skipped += 1
                    continue
                try:
                    y, m, d = int(c[15]), int(c[16]), int(c[17])
                except ValueError:
                    skipped += 1
                    continue
                if not (90 <= y <= 130 and 1 <= m <= 12 and 1 <= d <= 31):
                    skipped += 1
                    continue
                # 金額欄位置版式不同：地院=欄28/29、高院=欄27/28（差一欄）——
                # 掃整列找「新台幣」欄（exact match）取下一欄，兩版式通吃
                try:
                    amount = float(c[c.index('新台幣') + 1])
                except (ValueError, IndexError):
                    continue
                if amount <= 0:
                    continue
                jid = next((f.strip() for f in reversed(c) if JID_RE.match(f.strip())), None)
                if jid:
                    cases.append((key4(jid), jid.split(',')[4][:6], amount))
    return cases, skipped


_CL_CACHE = {}


def load_clients_lawyers(ym, required=False):
    """clients 快取 → {k4: set(lawyer)}（全 cat）；缺檔時 required 才 raise，
    否則回 None（裁判月落在快取範圍外的案就 join 不到，屬預期）。同月重複載入走記憶體快取。"""
    if ym in _CL_CACHE:
        return _CL_CACHE[ym]
    while len(_CL_CACHE) > 8:  # 連跑多月時控記憶體（裁判月都在終結月附近）
        _CL_CACHE.pop(next(iter(_CL_CACHE)))
    path = os.path.join(JW_DIR, f'{ym}_clients.jsonl.gz')
    if not os.path.exists(path):
        if required:
            raise RuntimeError(f'缺 clients 快取：{path}（先跑 client_concentration.py collect）')
        _CL_CACHE[ym] = None
        return None
    out = defaultdict(set)
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        for line in f:
            r = json.loads(line)
            out[key4(r['jid'])].add(r['lawyer'])
    _CL_CACHE[ym] = out
    return out


def run_month(ym, fileset_id):
    print(f'=== {ym}（fileSetId {fileset_id}）===')
    load_clients_lawyers(ym, required=True)  # 先驗當月快取存在再花時間下載
    arc = os.path.join(WORK_DIR, f'{ym}.7z')
    ext = os.path.join(WORK_DIR, ym)
    r = requests.get(f'{OPENDATA}/api/FilesetLists/{fileset_id}/file', timeout=600, verify=False)
    r.raise_for_status()
    with open(arc, 'wb') as f:
        f.write(r.content)
    if os.path.isdir(ext):
        shutil.rmtree(ext)
    subprocess.run([SEVENZ, 'x', '-y', arc, f'-o{ext}'], check=True, capture_output=True)

    cases, skipped = parse_month_cases(ext)
    # 殘缺月包防呆（202511 曾被官方重傳成殘缺版）：正常民訴+家訴逐案 >5,000/月
    if len(cases) < 3000:
        raise RuntimeError(f'{ym} 月包疑似殘缺（民訴+家訴有金額案僅 {len(cases)}），中止')

    agg = defaultdict(int)  # (name, bucket) → cases；微資料每案一列，天然去重
    # 收費模型聚合（mig 172/173）：
    # name → [200萬+件數, Σ超額標的, 二審件數, 三審件數, Σ超額標的(cap 1億)]
    fee = defaultdict(lambda: [0, 0, 0, 0, 0])
    joined = 0
    no_cache = 0
    for k4, jym, amount in cases:
        cl = load_clients_lawyers(jym)  # 按該案裁判月查快取（≠ 終結月時關鍵）
        if cl is None:
            no_cache += 1
            continue
        lawyers = cl.get(k4)
        if not lawyers:
            continue
        joined += 1
        b = amount_bucket(amount)
        amt_i = int(round(amount))
        surcharge = max(0, amt_i - SURCHARGE_THRESHOLD)
        surcharge_capped = max(0, min(amt_i, SURCHARGE_CAP) - SURCHARGE_THRESHOLD)
        lvl = 2 if k4[0].startswith(APPEAL2_PREFIXES) else \
              3 if k4[0].startswith(APPEAL3_PREFIXES) else 1
        for name in lawyers:
            agg[(name, b)] += 1
            f = fee[name]
            f[0] += surcharge > 0
            f[1] += surcharge
            f[2] += lvl == 2
            f[3] += lvl == 3
            f[4] += surcharge_capped
    rows = [{'ym': ym, 'name': n, 'bucket': b, 'cases': v} for (n, b), v in agg.items()]
    print(f'  有金額案 {len(cases)}（版式跳過 {skipped}、裁判月無快取 {no_cache}）→ '
          f'join {joined} 案、{len(rows)} 列（律師案次 {sum(agg.values())}）')

    fee_rows = [{'ym': ym, 'name': n, 'cases_200plus': f[0], 'surcharge_base_sum': f[1],
                 'appeal2_cases': f[2], 'appeal3_cases': f[3],
                 'surcharge_capped_sum': f[4]} for n, f in fee.items()]

    # 重跑冪等：先刪該月再插（兩表同一趟）
    headers = {**HEADERS_SB, 'Content-Type': 'application/json', 'Prefer': 'return=minimal'}
    for table, trows in ((TABLE, rows), (FEE_TABLE, fee_rows)):
        r = requests.delete(f'{SUPABASE_URL}/rest/v1/{table}?ym=eq.{ym}', headers=HEADERS_SB, timeout=60)
        if r.status_code not in (200, 204):
            raise RuntimeError(f'{table} DELETE 失敗 HTTP {r.status_code}: {r.text[:200]}')
        for i in range(0, len(trows), 2000):
            resp = requests.post(f'{SUPABASE_URL}/rest/v1/{table}', headers=headers,
                                 json=trows[i:i + 2000], timeout=120)
            if resp.status_code not in (200, 201, 204):
                raise RuntimeError(f'{table} 上傳失敗 HTTP {resp.status_code}: {resp.text[:300]}')
    print(f'  上傳 OK（桶表 {len(rows)} 列／收費聚合 {len(fee_rows)} 列）')
    os.remove(arc)
    shutil.rmtree(ext, ignore_errors=True)


def month_has_data(ym):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/{TABLE}?ym=eq.{ym}&select=ym&limit=1',
                     headers=HEADERS_SB, timeout=30)
    r.raise_for_status()
    return bool(r.json())


def main():
    requests.packages.urllib3.disable_warnings()
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    datasets = list_datasets()
    print(f'API 月包清單：{min(datasets)} ~ {max(datasets)}（{len(datasets)} 個月）')
    if cmd == 'run':
        ym = sys.argv[2]
        if ym not in datasets:
            raise RuntimeError(f'{ym} 不在 API 清單')
        run_month(ym, datasets[ym])
    elif cmd in ('backfill', 'refill'):
        # backfill=跳過 DB 已有的月；refill=區間全部重跑（DELETE+INSERT 冪等，join 邏輯改版用）
        start, end = sys.argv[2], sys.argv[3]
        todo = sorted(ym for ym in datasets
                      if start <= ym <= end and (cmd == 'refill' or not month_has_data(ym)))
        print(f'待{"重跑" if cmd == "refill" else "回填"} {len(todo)} 個月')
        for ym in todo:
            run_month(ym, datasets[ym])
            time.sleep(1)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
