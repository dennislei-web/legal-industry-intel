# -*- coding: utf-8 -*-
"""facts.tsv → firm_analysis_facts 全量重灌（DELETE 後分批 POST）。
跑新分析批次後：python facts_extract.py && python upload_facts.py
"""
import io, csv, json, sys, urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
ENV = r"C:\projects\legal-industry-intel\scripts\.env"
SRC = r"C:\projects\legal-industry-intel\scripts\_batch408\v2\facts.tsv"

env = {}
for ln in io.open(ENV, encoding='utf-8-sig'):
    ln = ln.strip()
    if ln and '=' in ln and not ln.startswith('#'):
        k, v = ln.split('=', 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
URL = env['SUPABASE_URL']
KEY = env.get('SUPABASE_SERVICE_KEY') or env.get('SUPABASE_KEY')
H = {'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}

INT_COLS = {'lawyer_count', 'avg_cases', 'founded_year', 'roster_n', 'court_n', 'cases_5y',
            'cases_nominal', 'dedup_months',
            'rev_low_wan', 'rev_high_wan', 'succession_risk', 'ex_judicial_n', 'g_reviews',
            'fb_pixel', 'google_ads', 'gov_tender_amt', 'indep_seats', 'awards_n'}
NUM_COLS = {'g_rating', 'dup_rate'}

rows = []
for r in csv.DictReader(io.open(SRC, encoding='utf-8'), delimiter='\t'):
    o = {}
    for k, v in r.items():
        if k in INT_COLS:
            try:
                o[k] = int(float(v))
            except (ValueError, TypeError):
                o[k] = None
        elif k in NUM_COLS:
            try:
                o[k] = float(v)
            except (ValueError, TypeError):
                o[k] = None
        else:
            o[k] = v or None
    rows.append(o)
print('read', len(rows), 'rows')

# 全清（PK=firm，條件恆真即可）
req = urllib.request.Request(URL + '/rest/v1/firm_analysis_facts?firm=neq.__none__',
                             headers=H, method='DELETE')
urllib.request.urlopen(req)

for i in range(0, len(rows), 200):
    chunk = rows[i:i + 200]
    req = urllib.request.Request(URL + '/rest/v1/firm_analysis_facts',
                                 data=json.dumps(chunk).encode(), headers=H)
    with urllib.request.urlopen(req) as resp:
        pass
    print('POST %d-%d ok' % (i, i + len(chunk) - 1))

req = urllib.request.Request(URL + '/rest/v1/firm_analysis_facts?select=firm',
                             headers={**H, 'Prefer': 'count=exact', 'Range': '0-0'})
with urllib.request.urlopen(req) as resp:
    print('DB 現有筆數:', resp.headers.get('Content-Range'))
