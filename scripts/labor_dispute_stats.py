#!/usr/bin/env python3
"""勞資爭議調解統計 → public/data/labor_stats.json

資料源（勞動部開放資料 OdService，月更、滯後約 3 個月）：
- dataset 40149 勞資爭議件數、人數（全國月資料，民國 100 年 1 月起）
- dataset 40156 勞資爭議件數－按主要爭議類別及地區分（月 × 25 地區 × 16 類別）
- dataset 40158 勞資爭議件數－按行業分（月 × 19 行業）

口徑注意：
- 「勞動部」列＝中央自辦（近乎 0），全國數＝各縣市＋科技產業園區＋科學園區加總
  （已實測 40156 各區加總 = 40149 全國數）
- 只有「受理」件數；處理結果／調解成立率不在開放資料（屬統計年報年資料）

訴訟對照：closed_case_cause_national（民事訴訟檔勞動案由）走 PostgREST，
需 scripts/.env 的 SUPABASE_URL / SUPABASE_SERVICE_KEY；查詢失敗時沿用舊 JSON 的 lit 序列。

用法：python labor_dispute_stats.py
"""
import json
import re
import sys
import urllib.request
import urllib.parse
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'public' / 'data' / 'labor_stats.json'
API = 'https://apiservice.mol.gov.tw/OdService'
UA = {'User-Agent': 'Mozilla/5.0'}

# 40156 欄位 → 顯示桶（調整事項用小計欄，不重複計元件）
CAT_BUCKETS = [
    ('工資', ['工資爭議件數']),
    ('資遣費', ['給付資遣費爭議件數']),
    ('退休金', ['給付退休金爭議件數']),
    ('職災補償', ['職業災害補償爭議件數']),
    ('契約', ['契約爭議件數']),
    ('休假', ['休假爭議件數']),
    ('勞保給付', ['勞工保險給付爭議件數']),
    ('其他', ['工會身分保護爭議件數', '其他權利事項爭議件數', '調整事項件數']),
]
RE_YM = re.compile(r'(\d+)年\s*(\d+)月')

# 勞動部委託法扶「勞工訴訟扶助專案」年度扶助（准予）件數——年報手工線，年更
# 來源：法扶基金會年度報告書（laf.org.tw/publication，每年 4-5 月出前一年）
# 各年報「勞動部委託辦理」節的「近三年勞工訴訟扶助專案扶助件數」表；
# 2025 申請 4,246／准予比例 82.5%。2021 低點=疫情＋無集體訴訟（年報原文）。
AID_SERIES = {2019: 3076, 2020: 3340, 2021: 1923, 2022: 3382,
              2023: 1740, 2024: 1780, 2025: 3503}


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    return urllib.request.urlopen(req, timeout=180).read()


def dataset_json(dataset_id):
    """由 dataset metadata 解析 JSON 資源網址再下載（resource ID 可能變動，不寫死）"""
    meta = json.loads(fetch(f'{API}/rest/dataset/{dataset_id}'))
    res = [r for r in meta['distribution'] if r['resourceFormat'] == 'JSON']
    if not res:
        raise RuntimeError(f'dataset {dataset_id} 無 JSON 資源')
    return json.loads(fetch(res[0]['resourceDownloadUrl']).decode('utf-8-sig'))


def parse_ym(s):
    m = RE_YM.search(s)
    return (int(m.group(1)), int(m.group(2))) if m else None


def load_env():
    env = {}
    p = ROOT / 'scripts' / '.env'
    if p.exists():
        for line in p.read_text(encoding='utf-8-sig').splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip()
    return env


def fetch_lit_series():
    """民事訴訟檔勞動案由年度終結件數（下限口徑），PostgREST 逐頁抓避開 1000 列上限"""
    env = load_env()
    base, key = env.get('SUPABASE_URL'), env.get('SUPABASE_SERVICE_KEY')
    if not base or not key:
        raise RuntimeError('scripts/.env 缺 SUPABASE_URL / SUPABASE_SERVICE_KEY')
    ors = ','.join(f'cause.like.*{k}*' for k in ['工資', '資遣', '退休金', '僱傭', '職業災害', '勞動'])
    params = urllib.parse.urlencode({
        'select': 'yyyymm,cause,case_count',
        'file_type': 'eq.民事訴訟',
        'or': f'({ors})',
    })
    url = f'{base}/rest/v1/closed_case_cause_national?{params}'
    by_year = {}
    offset, page = 0, 1000
    while True:
        # 不帶瀏覽器 UA——Supabase 會拒收「瀏覽器環境」使用 sb_secret key
        req = urllib.request.Request(url, headers={
            'apikey': key, 'Authorization': f'Bearer {key}',
            'Range': f'{offset}-{offset + page - 1}'})
        rows = json.loads(urllib.request.urlopen(req, timeout=120).read())
        for r in rows:
            if '訴訟費用額' in r['cause']:
                continue
            by_year[r['yyyymm'][:4]] = by_year.get(r['yyyymm'][:4], 0) + r['case_count']
        if len(rows) < page:
            break
        offset += page
    # 只出完整年（次年 2 月前視當年未完整——微資料滯後約 1.5 個月）
    today = date.today()
    last_full = today.year - 1 if today.month >= 3 else today.year - 2
    years = sorted(y for y in by_year if 2021 <= int(y) <= last_full)
    return {'years': [int(y) for y in years], 'cases': [by_year[y] for y in years]}


def main():
    # ---- 40149 全國月資料（件數/人數） ----
    nat = {}
    for r in dataset_json(40149):
        ym = parse_ym(r['項目別'])
        if ym:
            nat[ym] = (int(r['爭議受理案件件數']), int(r['爭議受理案件涉及人數']))
    latest_ym = max(nat)
    last_full_year = latest_ym[0] if latest_ym[1] == 12 else latest_ym[0] - 1
    years = [y for y in range(100, last_full_year + 1)]
    nat_cases = [sum(nat[(y, m)][0] for m in range(1, 13)) for y in years]
    nat_persons = [sum(nat[(y, m)][1] for m in range(1, 13)) for y in years]
    prev = nat.get((latest_ym[0] - 1, latest_ym[1]))
    latest = {
        'ym': f'{latest_ym[0]}-{latest_ym[1]:02d}', 'cases': nat[latest_ym][0],
        'yoy_pct': round((nat[latest_ym][0] / prev[0] - 1) * 100, 1) if prev else None,
    }

    # ---- 40156 類別 × 地區 ----
    cat_year = {b: {} for b, _ in CAT_BUCKETS}   # bucket -> year -> n
    region_year = {}                              # region -> n（僅最新完整年）
    check_year_total = {}
    for r in dataset_json(40156):
        part = r['項目別'].split('/')
        ym = parse_ym(part[0])
        if not ym or len(part) < 2:
            continue
        region = part[1].strip()
        if region == '勞動部':   # 中央自辦近乎 0，不列縣市表；類別加總仍納入
            pass
        y = ym[0]
        for bucket, cols in CAT_BUCKETS:
            v = sum(int(r[c]) for c in cols)
            cat_year[bucket][y] = cat_year[bucket].get(y, 0) + v
        check_year_total[y] = check_year_total.get(y, 0) + int(r['爭議受理案件件數'])
        if y == last_full_year and region != '勞動部':
            region_year[region] = region_year.get(region, 0) + int(r['爭議受理案件件數'])

    # 防呆：40156 加總 vs 40149 全國，差 >1% 視為來源結構變動
    for y, total in zip(years, nat_cases):
        if abs(check_year_total.get(y, 0) - total) > max(10, total * 0.01):
            print(f'[abort] {y} 年 40156 加總 {check_year_total.get(y)} != 40149 全國 {total}')
            sys.exit(2)

    cat_series = {b: [cat_year[b].get(y, 0) for y in years] for b, _ in CAT_BUCKETS}
    ly_total = nat_cases[years.index(last_full_year)]
    cat_latest = [[b, cat_year[b][last_full_year],
                   round(cat_year[b][last_full_year] / ly_total * 100, 1)] for b, _ in CAT_BUCKETS]
    regions = sorted(region_year.items(), key=lambda x: -x[1])
    region_rows = [[k, v, round(v / ly_total * 100, 1)] for k, v in regions]

    # ---- 40158 行業 ----
    ind_year = {}
    for r in dataset_json(40158):
        ym = parse_ym(r['項目別'])
        if not ym or ym[0] != last_full_year:
            continue
        for k, v in r.items():
            if k.endswith('爭議受理案件件數'):
                name = k[:-len('爭議受理案件件數')]
                ind_year[name] = ind_year.get(name, 0) + int(v)
    ind_sorted = sorted(ind_year.items(), key=lambda x: -x[1])
    ind_items = [[k, v, round(v / ly_total * 100, 1)] for k, v in ind_sorted[:10]]
    rest = sum(v for _, v in ind_sorted[10:])
    if rest:
        ind_items.append(['其他行業', rest, round(rest / ly_total * 100, 1)])

    # ---- 訴訟對照（失敗沿用舊值） ----
    try:
        lit = fetch_lit_series()
    except Exception as e:
        print(f'[warn] 訴訟對照查詢失敗，沿用舊 JSON：{e}')
        lit = None
        if OUT.exists():
            lit = json.loads(OUT.read_text(encoding='utf-8')).get('lit')

    out = {
        'updated': date.today().isoformat(),
        'latest': latest,
        'national': {'years': years, 'cases': nat_cases, 'persons': nat_persons},
        'cats': {'years': years, 'series': cat_series,
                 'latest_year': last_full_year, 'latest': cat_latest},
        'regions': {'year': last_full_year, 'rows': region_rows},
        'industry': {'year': last_full_year, 'items': ind_items},
        'lit': lit,
        'aid': {'years': sorted(AID_SERIES), 'cases': [AID_SERIES[y] for y in sorted(AID_SERIES)]},
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(f'ok → {OUT}  最新 {latest["ym"]}（{latest["cases"]} 件）'
          f'，完整年 {years[0]}–{last_full_year}，{len(region_rows)} 區、{len(ind_items)} 行業')


if __name__ == '__main__':
    main()
