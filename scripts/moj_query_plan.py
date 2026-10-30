"""
MOJ 新站人工查詢清單產生器（2026-10-29 改版後的名冊建表／增量）

官網查詢一律要人工打驗證碼、每次最多 100 筆，但「證號前綴」查詢可行
（`115臺檢證字第193` → 19300～19399）。本腳本讀 moj_lawyers，算出最少的查詢字串，
給同仁在官網逐條查、用書籤助手（public/tools/moj-harvest.js）收成。程式不碰驗證碼。

切法（docs/moj-site-redesign-2026-10.md）：
  lic_no 去掉「N號」得系列（例 `115臺檢證字第`）
  - 系列總數 ≤100 → 整系列一條
  - 否則切三位數前綴：系列＋編號去掉末兩碼（`115臺檢證字第193`，約百號一段）
  格式異常（無「第」或無「號」，約 39 筆）另列，附建議寫法，人工查。

模式：
  （預設）full        一次性建表全清單（約 322 條）
  --incremental        每週增量：最新年度已知最大號所在段＋往後 --ahead 段、最新年度補證／外檢整系列、
                       詳細頁 404（page_hash_missing_at）待複查者的完整證號
  --alumni             只出 zhelu_alumni 校友所在的區段（試跑整條鏈用）
  --remaining          （搭配 full／alumni）只留還有「現職且尚無 page_hash」律師的查詢

輸出：
  CSV（預設 scripts/.moj_harvest_work/plan_<mode>.csv；utf-8-sig 給 Excel 開）
  --publish            另把查詢字串寫進 public/tools/moj-harvest-plan.json 的 sets.<mode>
                       （進度頁讀；只放前綴型查詢與預期筆數，不放完整證號、不放姓名）

用法:
  python moj_query_plan.py
  python moj_query_plan.py --alumni --publish
  python moj_query_plan.py --incremental --ahead 3 --publish
"""
import csv
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

from moj_licno_norm import lic_triple, split_series, suggest_query  # noqa: E402

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

HERE = os.path.dirname(os.path.abspath(__file__))
WORK_DIR = os.path.join(HERE, '.moj_harvest_work')
PLAN_JSON = os.path.join(HERE, '..', 'public', 'tools', 'moj-harvest-plan.json')

SERIES_MAX = 100   # 官網單次上限
PUBLIC_KINDS = {'series', 'prefix', 'block'}  # 只有這幾種會寫進公開 JSON


def sb_get_all(path):
    out, offset = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        r = requests.get(f'{SUPABASE_URL}/rest/v1/{path}{sep}offset={offset}&limit=1000',
                         headers=HEADERS_SB, timeout=60)
        r.raise_for_status()
        rows = r.json()
        out.extend(rows)
        if len(rows) < 1000:
            return out
        offset += 1000


def load_lawyers():
    return sb_get_all('moj_lawyers?select=lic_no,name,office_normalized,page_hash,'
                      'page_hash_missing_at,deregistered_at&order=lic_no')


def full_queries(rows):
    """系列 ≤100 整條、否則三位數前綴。回傳 (查詢清單, 格式異常列)"""
    by_series = defaultdict(list)
    abnormal = []
    for r in rows:
        sp = split_series(r['lic_no'])
        if sp:
            by_series[sp[0]].append(sp[1])
        else:
            abnormal.append(r)
    queries = []
    for series, nums in sorted(by_series.items()):
        if len(nums) <= SERIES_MAX:
            queries.append(('series', series))
        else:
            for p in sorted({n[:-2] if len(n) > 2 else '' for n in nums}):
                queries.append(('prefix', series + p))
    return queries, abnormal


def annotate(queries, rows):
    """每條查詢對 DB 算：預期筆數（前綴命中，含已除名）、現職數、現職已有雜湊數"""
    out = []
    for kind, q in queries:
        hit = [r for r in rows if r['lic_no'].startswith(q)]
        active = [r for r in hit if not r.get('deregistered_at')]
        out.append({
            'kind': kind, 'query': q,
            'expected_n': len(hit),
            'active_n': len(active),
            'hashed_n': sum(1 for r in active if r.get('page_hash')),
            'note': '', 'suggest': '',
        })
    return out


def incremental_queries(rows, ahead):
    """最新年度：臺檢證取最大號所在百號段＋往後 ahead 段；補證／外檢整系列。
    民國年已跨過 DB 最新年度時（例如 1 月），新年度用同一組段落再出一份（臺檢證編號跨年連續）。"""
    latest = defaultdict(lambda: (0, 0))  # kind → (year, max num)
    for r in rows:
        t = lic_triple(r['lic_no'])
        if not t or t[0] is None:
            continue
        y, k, n = t
        if k in ('臺檢證', '臺檢補證', '外檢證') and (y, n) > latest[k]:
            latest[k] = (y, n)
    roc_now = datetime.now().year - 1911
    out = []
    y, m = latest['臺檢證']
    years = [y] + ([roc_now] if roc_now > y else [])
    for yy in years:
        for b in range(m // 100, m // 100 + ahead + 1):
            out.append(('block', f'{yy}臺檢證字第{b}'))
        for k in ('臺檢補證', '外檢證'):
            if latest[k][0]:
                out.append(('series', f'{yy}{k}字第'))
    return out


def missing_queue(rows):
    """詳細頁 404 待複查（雜湊失效或已移除；不等於除名）：用完整證號人工查"""
    return [r for r in rows if r.get('page_hash_missing_at') and not r.get('deregistered_at')]


def alumni_lic_nos(rows):
    """校友 → moj_lawyers 證號（同名多筆用現職所消歧，消歧不了就全部候選都查）"""
    from moj_alumni_refresh import resolve_lic  # 延遲匯入：只有 --alumni 需要
    alumni = sb_get_all('zhelu_alumni?select=name,current_firm,moj_exclude&order=id')
    by_name = defaultdict(list)
    for r in rows:
        by_name[r['name']].append(r)
    lics, stat = set(), defaultdict(int)
    for a in alumni:
        if a.get('moj_exclude'):
            stat['同名非本人（排除）'] += 1
            continue
        row, reason = resolve_lic(a, by_name)
        if row:
            lics.add(row['lic_no'])
            stat['對上'] += 1
        elif reason.startswith('ambiguous'):
            lics.update(c['lic_no'] for c in by_name[a['name']])
            stat['同名無法消歧（候選全查）'] += 1
        else:
            stat['名冊查無'] += 1
    return lics, len(alumni), dict(stat)


def write_csv(path, items):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cols = ['kind', 'query', 'expected_n', 'active_n', 'hashed_n', 'note', 'suggest']
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for it in items:
            w.writerow({c: it.get(c, '') for c in cols})


def publish(mode, items):
    path = os.path.normpath(PLAN_JSON)
    try:
        with open(path, encoding='utf-8') as f:
            doc = json.load(f)
    except (OSError, ValueError):
        doc = {'sets': {}}
    now = datetime.now(timezone.utc).isoformat(timespec='seconds')
    doc.setdefault('sets', {})[mode] = {
        'generated_at': now,
        'queries': [{'q': it['query'], 'n': it['expected_n']}
                    for it in items if it['kind'] in PUBLIC_KINDS],
    }
    doc['generated_at'] = now
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    # 一條查詢一行（diff 好讀）
    lines = ['{', f' "generated_at": {json.dumps(doc["generated_at"])},', ' "sets": {']
    keys = sorted(doc['sets'])
    for si, k in enumerate(keys):
        s = doc['sets'][k]
        lines.append(f'  {json.dumps(k)}: {{"generated_at": {json.dumps(s["generated_at"])}, "queries": [')
        qs = s['queries']
        for qi, q in enumerate(qs):
            lines.append('   ' + json.dumps(q, ensure_ascii=False, separators=(', ', ': '))
                         + (',' if qi < len(qs) - 1 else ''))
        lines.append('  ]}' + (',' if si < len(keys) - 1 else ''))
    lines += [' }', '}']
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    os.replace(tmp, path)
    return path, len(doc['sets'][mode]['queries'])


def main():
    args = sys.argv[1:]
    mode = 'incremental' if '--incremental' in args else 'alumni' if '--alumni' in args else 'full'
    ahead = int(args[args.index('--ahead') + 1]) if '--ahead' in args else 2
    out_path = args[args.index('--out') + 1] if '--out' in args else os.path.join(WORK_DIR, f'plan_{mode}.csv')

    rows = load_lawyers()
    print(f'moj_lawyers：{len(rows):,} 筆（含已除名 {sum(1 for r in rows if r.get("deregistered_at")):,}）')

    queries, abnormal = full_queries(rows)
    items = []
    if mode == 'full':
        items = annotate(queries, rows)
    elif mode == 'alumni':
        lics, n_alumni, stat = alumni_lic_nos(rows)
        print(f'校友 {n_alumni} 位：' + '、'.join(f'{k} {v}' for k, v in stat.items()) + f' → {len(lics)} 個證號')
        picked = [(k, q) for k, q in queries if any(l.startswith(q) for l in lics)]
        items = annotate(picked, rows)
        abnormal = [r for r in abnormal if r['lic_no'] in lics]
    else:
        items = annotate(incremental_queries(rows, ahead), rows)
        for r in missing_queue(rows):
            items.append({'kind': 'missing', 'query': r['lic_no'], 'expected_n': 1, 'active_n': 1,
                          'hashed_n': 1, 'note': f'詳細頁 404 於 {r["page_hash_missing_at"][:10]}，以完整證號複查',
                          'suggest': ''})
        abnormal = []

    if '--remaining' in args and mode != 'incremental':
        before = len(items)
        items = [it for it in items if it['active_n'] > it['hashed_n']]
        print(f'--remaining：{before} 條中還有 {len(items)} 條有現職未取得雜湊者')

    for r in abnormal:
        items.append({'kind': 'abnormal', 'query': r['lic_no'], 'expected_n': 1,
                      'active_n': 0 if r.get('deregistered_at') else 1, 'hashed_n': 1 if r.get('page_hash') else 0,
                      'note': '證號格式異常（無「第」或無「號」），人工判斷查詢寫法',
                      'suggest': suggest_query(r['lic_no'])})

    write_csv(out_path, items)

    by_kind = defaultdict(int)
    for it in items:
        by_kind[it['kind']] += 1
    pub = [it for it in items if it['kind'] in PUBLIC_KINDS]
    over = [it for it in pub if it['expected_n'] > SERIES_MAX]
    print(f'\n=== 查詢清單（{mode}）===')
    print('、'.join(f'{k} {v} 條' for k, v in sorted(by_kind.items())) + f'，合計 {len(items)} 條')
    if pub:
        print(f'前綴型查詢 {len(pub)} 條：預期筆數最大 {max(it["expected_n"] for it in pub)}、'
              f'合計 {sum(it["expected_n"] for it in pub):,}；現職已有雜湊 '
              f'{sum(it["hashed_n"] for it in pub):,}／{sum(it["active_n"] for it in pub):,}')
    if over:
        print(f'⚠️ {len(over)} 條預期超過 {SERIES_MAX} 筆（官網會回「找不到或超過 100 筆」），要再切細：'
              + '、'.join(it['query'] for it in over[:10]))
    print(f'CSV：{os.path.abspath(out_path)}')
    if '--publish' in args:
        path, n = publish(mode, items)
        print(f'已寫入 {path}（sets.{mode}，{n} 條）')


if __name__ == '__main__':
    main()
