# -*- coding: utf-8 -*-
"""TIPO 代理人件數聚合＋名簿 join＋上傳 Supabase

輸入：scripts/.tipo_agents_work/{dataset}_{yr}.jsonl（tipo_agent_fetch.py 產出）
聚合：
  tipo_agent_stats：kind(tm|pt) × agent_name × year_tw → cases
                    ＋名簿 join（firm/identity/is_lawyer，現任名簿口徑）
  tipo_firm_stats ：kind × firm × year_tw → cases（僅名簿可歸戶者）＋agents_n
kind 對應：tm = TmarkAppl；pt = PatentPub(發明) + PatentRightsM(新型) + PatentRightsD(設計)
年份：資料夾年 = 申請案號前三碼（民國申請年）

用法：
  python tipo_agent_stats.py build           # 只聚合、印摘要（不上傳）
  python tipo_agent_stats.py upload          # 聚合＋整表重建上傳
"""
import os
import re
import sys
import json
import csv
import io
import requests
from collections import defaultdict

sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')
from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))
SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.tipo_agents_work')
KIND_MAP = {'TmarkAppl': 'tm', 'PatentPub': 'pt', 'PatentRightsM': 'pt', 'PatentRightsD': 'pt'}
ROSTER_TM = 'https://tiponet.tipo.gov.tw/datagov/tm/121-106-001.csv'   # 商標代理人登錄名簿
ROSTER_PT = 'https://tiponet.tipo.gov.tw/datagov/pt/069-104-001.csv'   # 專利案件代理人


def load_rosters():
    """名簿 join 表：kind → name → (identity, firm)；同名多筆取件數歸戶不了就標 ambiguous"""
    out = {}
    for kind, url, name_col, firm_col, id_col in [
        ('tm', ROSTER_TM, '姓名', '執業處所名稱', '身分種類'),
        ('pt', ROSTER_PT, '姓名', '事務所名稱', '身份種類'),
    ]:
        r = requests.get(url, timeout=120)
        r.raise_for_status()
        rows = list(csv.DictReader(io.StringIO(r.content.decode('utf-8-sig'))))
        m = defaultdict(list)
        for row in rows:
            m[row[name_col].strip()].append((row[id_col].strip(), (row[firm_col] or '').strip()))
        out[kind] = m
        print(f'名簿 {kind}: {len(rows)} 筆 / {len(m)} 唯一姓名')
    return out


def build():
    agg = defaultdict(int)          # (kind, name, yr) -> cases
    coverage = defaultdict(lambda: [0, 0])  # (kind, yr) -> [有代理案, 總案]
    for fn in sorted(os.listdir(WORK_DIR)):
        m = re.match(r'([A-Za-z]+)_(\d{3})\.jsonl$', fn)
        if not m:
            continue
        ds, yr = m.group(1), int(m.group(2))
        kind = KIND_MAP.get(ds)
        if not kind:
            continue
        with open(os.path.join(WORK_DIR, fn), encoding='utf-8') as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                cov = coverage[(kind, yr)]
                cov[1] += 1
                if row['agents']:
                    cov[0] += 1
                    seen = set()
                    for name, _addr in row['agents']:
                        if name not in seen:   # 同案同名只記一次
                            seen.add(name)
                            agg[(kind, name, yr)] += 1
    print('--- 覆蓋率（有代理案/總案）---')
    for (kind, yr), (a, b) in sorted(coverage.items()):
        print(f'  {kind} {yr}: {a:,}/{b:,} ({a/b*100:.0f}%)' if b else f'  {kind} {yr}: 0')

    rosters = load_rosters()
    agent_rows = []
    firm_agg = defaultdict(lambda: [0, set()])   # (kind, firm, yr) -> [cases, {agents}]
    for (kind, name, yr), n in agg.items():
        entries = rosters[kind].get(name, [])
        identity = entries[0][0] if len(entries) == 1 else (entries[0][0] if entries and all(e[0] == entries[0][0] for e in entries) else None)
        firm = entries[0][1] if len(entries) == 1 else None
        agent_rows.append({
            'kind': kind, 'agent_name': name, 'year_tw': yr, 'cases': n,
            'firm': firm or None, 'identity': identity,
            'is_lawyer': identity == '律師',
        })
        if firm:
            fa = firm_agg[(kind, firm, yr)]
            fa[0] += n
            fa[1].add(name)
    firm_rows = [{'kind': k, 'firm': f, 'year_tw': y, 'cases': v[0], 'agents_n': len(v[1])}
                 for (k, f, y), v in firm_agg.items()]
    print(f'agent rows: {len(agent_rows):,}  firm rows: {len(firm_rows):,}')

    # 摘要：114 商標 TOP10 代理人 / 事務所
    top = sorted([r for r in agent_rows if r['kind'] == 'tm' and r['year_tw'] == 114], key=lambda r: -r['cases'])[:10]
    print('--- 114 商標代理 TOP10 ---')
    for r in top:
        print(f'  {r["agent_name"]}（{r["identity"] or "名簿外"}／{r["firm"] or "-"}）: {r["cases"]:,}')
    return agent_rows, firm_rows


def upload(agent_rows, firm_rows):
    for table, rows in [('tipo_agent_stats', agent_rows), ('tipo_firm_stats', firm_rows)]:
        r = requests.delete(f'{SUPABASE_URL}/rest/v1/{table}?id=gte.0', headers=HB, timeout=300)
        print(f'{table} 清空: {r.status_code}')
        for i in range(0, len(rows), 3000):
            chunk = rows[i:i + 3000]
            r = requests.post(f'{SUPABASE_URL}/rest/v1/{table}', headers={**HB, 'Content-Type': 'application/json', 'Prefer': 'return=minimal'}, json=chunk, timeout=300)
            if r.status_code not in (200, 201):
                print(f'{table} 批次 {i} 失敗: {r.status_code} {r.text[:200]}')
                sys.exit(1)
        print(f'{table} 上傳 {len(rows):,} 列完成')


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'build'
    a, f = build()
    if mode == 'upload':
        upload(a, f)
