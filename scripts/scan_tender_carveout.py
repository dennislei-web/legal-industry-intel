# -*- coding: utf-8 -*-
"""掃描已完成分析的事務所中，符合「機構標案 carve-out」觸發條件者。
條件：(1) 律師 top_entities 機關委任人佔全所案量 >=15%（下限口徑）
     (2) gov_tender_firms 有得標紀錄
"""
import os, re, json, urllib.request, urllib.parse

URL = os.environ['SUPABASE_URL'].strip()
KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HDR = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}

def q(path, rng=None):
    h = dict(HDR)
    if rng: h['Range'] = rng
    req = urllib.request.Request(URL + path, headers=h)
    return json.load(urllib.request.urlopen(req))

def q_all(path):
    out, start = [], 0
    while True:
        batch = q(path, rng=f'{start}-{start+999}')
        out += batch
        if len(batch) < 1000: return out
        start += 1000

# 機關委任人判定（保守 heuristic；得標紀錄雙重條件把關精度）
GOV_RE = re.compile(
    r'(政府$|公所$|分署$|地政事務所$|戶政事務所$|衛生所$|管理局$|管理處$|'
    r'財政部|國有財產|法務部|勞動部|衛生福利部|經濟部|交通部|內政部|教育部|'
    r'國防部|退輔會|農業部|環境部|數位發展部|海洋委員會|原住民族|客家委員會|'
    r'台灣電力|臺灣電力|台灣自來水|臺灣自來水|中華郵政|台灣糖業|臺灣糖業|'
    r'國立|市立|縣立|部立|農田水利|金融監督|公平交易委員會|中央選舉委員會|'
    r'國家通訊傳播委員會)')
# 社區/大廈管委會不是機關（金管會等政府委員會已在 GOV_RE 白名單內個別列舉）
NOT_GOV_RE = re.compile(r'(大廈|社區|公寓|山莊|花園|廣場|大樓|管理委員會$)')

# 訴訟履約型標案關鍵字（案名判定）
LIT_TENDER_RE = re.compile(r'(訴訟|支付命令|債權|強制執行|催收|收回|拆屋|返還|不動產.{0,6}(回收|處理))')

# 1) 已完成分析的所
profs = q_all('/rest/v1/firm_profiles?select=firm_name&ai_analysis=not.is.null&order=firm_name')
firms = [p['firm_name'] for p in profs]
print(f'已完成分析：{len(firms)} 家', flush=True)

# 2) 得標紀錄（全量抓一次，本地分組）
wins = q_all('/rest/v1/gov_tender_firms?select=firm_name,tender_key,is_winner,award_amount&is_winner=eq.true')
win_by_firm = {}
for w in wins:
    win_by_firm.setdefault(w['firm_name'], []).append(w)
print(f'有得標紀錄的所：{len(win_by_firm)} 家', flush=True)

cand = [f for f in firms if f in win_by_firm]
print(f'交集（已分析＋有得標）：{len(cand)} 家', flush=True)

results = []
for f in cand:
    # 所屬律師（含分所：前綴比對）
    k = urllib.parse.quote(f.replace('法律事務所','') + '*')
    ls = q(f'/rest/v1/moj_lawyers?select=name,office_normalized&office_normalized=like.{k}&limit=100')
    # 過濾：office 必須含完整所名前綴（避免「大成」比到「大成台灣」以外的所）
    names = [x['name'] for x in ls if x['office_normalized'] and x['office_normalized'].startswith(f.replace('法律事務所',''))]
    if not names:
        continue
    ns = ','.join('%22' + urllib.parse.quote(n) + '%22' for n in names)
    cc = q(f'/rest/v1/lawyer_client_concentration?select=name,n_cases,top_entities&name=in.({ns})')
    tot = sum(r['n_cases'] for r in cc)
    gov_n = 0
    gov_names = set()
    for r in cc:
        for ent in (r['top_entities'] or []):
            nm, n = ent[0], ent[1]
            if nm and GOV_RE.search(nm) and not NOT_GOV_RE.search(nm):
                gov_n += n
                gov_names.add(nm)
    if tot == 0:
        continue
    share = gov_n / tot
    if share < 0.05:
        continue
    # 得標案名分類：訴訟履約型 vs 顧問型
    keys = list({w['tender_key'] for w in win_by_firm[f]})
    tmap = {}
    for i in range(0, len(keys), 60):
        ks = ','.join('%22' + urllib.parse.quote(k) + '%22' for k in keys[i:i+60])
        for t in q(f'/rest/v1/gov_tenders?select=tender_key,title&tender_key=in.({ks})', rng='0-999'):
            tmap[t['tender_key']] = t.get('title') or ''
    lit_award = other_award = 0
    lit_n = 0
    for w in win_by_firm[f]:
        amt = w.get('award_amount') or 0
        if LIT_TENDER_RE.search(tmap.get(w['tender_key'], '')):
            lit_award += amt; lit_n += 1
        else:
            other_award += amt
    results.append({'firm': f, 'lawyers': len(names), 'cases_12m': tot,
                    'gov_cases': gov_n, 'gov_share': round(share*100, 1),
                    'n_wins': len(win_by_firm[f]), 'lit_wins': lit_n,
                    'lit_award_wan': round(lit_award/10000, 1),
                    'other_award_wan': round(other_award/10000, 1),
                    'gov_entities': sorted(gov_names)[:5]})

results.sort(key=lambda r: -r['gov_share'])
def fmt(r):
    return (f"{r['firm']} | 律師{r['lawyers']} | 12月案量{r['cases_12m']} | "
            f"機關案{r['gov_cases']}({r['gov_share']}%) | "
            f"訴訟履約標{r['lit_wins']}件/{r['lit_award_wan']}萬(顧問型另{r['other_award_wan']}萬) | {r['gov_entities']}")
print('\n=== 觸發 carve-out（機關佔比>=15% 且 有訴訟履約型得標）===')
for r in results:
    if r['gov_share'] >= 15 and r['lit_wins'] > 0:
        print(fmt(r))
print('\n=== 機關佔比>=15% 但無訴訟履約型得標（不觸發，顧問約為主）===')
for r in results:
    if r['gov_share'] >= 15 and r['lit_wins'] == 0:
        print(fmt(r))
print('\n=== 觀察名單（5-15%）===')
for r in results:
    if 5 <= r['gov_share'] < 15:
        print(fmt(r))

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'carveout_scan.json'), 'w', encoding='utf-8') as fh:
    json.dump(results, fh, ensure_ascii=False, indent=1)
print('\n完整結果已存 carveout_scan.json')
