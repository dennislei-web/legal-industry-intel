# -*- coding: utf-8 -*-
"""司法人員監察院彈劾紀錄爬蟲：CyBsBox 彈劾案文查詢 → judge_impeachments 表（mig 125）。

來源：https://www.cy.gov.tw/CyBsBox.aspx?n=135&CSN=4（GET 分頁，PageSize=200，全量 ~3 頁）。
案由全文含被彈劾人姓名＋機關＋職稱，直接錨定抽取；姓名長度歧義（2 或 3 字）以
DB 已知司法官名單（judge_judgment_stats / prosecutor_stats）交叉驗證。
冪等：以 (case_no, name) upsert。手動執行：python judge_impeachments.py
"""
import io
import os
import re
import sys
import time

import requests

sys.stdout.reconfigure(encoding='utf-8')
HERE = os.path.dirname(os.path.abspath(__file__))
for line in io.open(os.path.join(HERE, '.env'), encoding='utf-8'):
    if '=' in line and not line.strip().startswith('#'):
        k, v = line.split('=', 1)
        os.environ.setdefault(k.strip(), v.strip())
SB_URL = os.environ['SUPABASE_URL']
SB_KEY = os.environ['SUPABASE_SERVICE_KEY']
HEAD = {'apikey': SB_KEY, 'Authorization': f'Bearer {SB_KEY}'}
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'

# 機關＋職稱＋姓名 錨定（姓名先貪婪取 3 字，再用已知名單決定 2/3 字）
ANCHOR = re.compile(
    r'((?:臺灣|福建|懲戒|司法院|最高)[^，。；]{0,14}?'
    r'(?:法院|檢察署|地檢署|職務法庭))'
    r'(前?(?:候補法官|試署法官|法官|庭長|院長|檢察長|主任檢察官|檢察官))'
    r'([一-鿿]{2,3})')


def fetch_known_names():
    """DB 已知司法官姓名（法官＋檢察官），供截字驗證。"""
    known = set()
    for table, col in (('judge_judgment_stats', 'name'), ('prosecutor_stats', 'name')):
        frm = 0
        while True:
            r = requests.get(
                f'{SB_URL}/rest/v1/{table}?select={col}',
                headers={**HEAD, 'Range': f'{frm}-{frm + 999}'}, timeout=60)
            rows = r.json() if r.status_code in (200, 206) else []
            known.update(x[col] for x in rows)
            if len(rows) < 1000:
                break
            frm += 1000
    return known


def roc_date(s):
    m = re.match(r'(\d{2,3})/(\d{1,2})/(\d{1,2})', s or '')
    if not m:
        return None
    return f'{int(m.group(1)) + 1911:04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}'


def main():
    s = requests.Session()
    s.headers['User-Agent'] = UA
    print('載入 DB 已知司法官名單…')
    known = fetch_known_names()
    print(f'known names: {len(known)}')

    out, outkeys = [], set()
    for p in range(1, 6):  # 536 件 / 200 = 3 頁，留餘裕（末頁後會重複回傳→靠 key 去重並終止）
        r = s.get(f'https://www.cy.gov.tw/CyBsBox.aspx?n=135&CSN=4&page={p}&PageSize=200',
                  timeout=60)
        trs = re.findall(r'<tr>\s*<td class="CCMS_jGridView_td_Class_0.*?</tr>', r.text, re.S)
        if not trs:
            break
        for tr in trs:
            cells = dict(re.findall(r'data-title="([^"]+)"[^>]*>(?:<span>)?(.*?)(?:</span>)?</td>',
                                    tr, re.S))
            strip = lambda h: re.sub(r'\s+', '', re.sub(r'<[^>]+>', '', h or ''))
            date = roc_date(strip(cells.get('審議日期', '')).replace('115/', '115/'))
            case = strip(cells.get('案號', ''))
            cause = strip(cells.get('文件案由/案名', '')).replace('...詳全文', '')
            doc = re.search(r'href="(https://cybsbox\.cy\.gov\.tw/CYBSBoxSSL/edoc/download/\d+)"'
                            r'[^>]*title="[^"]*彈劾案文[^"]*"', tr)
            prog = strip(cells.get('處理進度', ''))
            seen = set()
            for org, title, raw in ANCHOR.findall(cause):
                # 姓名截字＋驗證：必須命中 DB 已知司法官名單（3 字不中試 2 字），
                # 未命中即棄（案由提及「檢察官起訴」等動詞黏字假名靠此排除；
                # 代價是極早期不在裁判書名單者會漏，可接受）
                # 停用字：prosecutor_stats 已知名單含 mig 066 前的殘留假名
                # （「提起公」「給予緩」等動詞黏字），真人名不會含這些字
                if any(c in raw for c in '起訴緩偵審判決署案'):
                    continue
                if raw in ('依通常', '期間') or raw[:2] in ('依通', '期間'):
                    continue  # 已知殘留假名（人工覆核 2026-08）
                if raw in known:
                    name = raw
                elif raw[:2] in known:
                    name = raw[:2]
                else:
                    continue
                if name in seen or (case, name) in outkeys:
                    continue
                seen.add(name)
                outkeys.add((case, name))
                role = '檢察官' if '檢察' in title or '檢察' in org else '法官'
                out.append({'case_no': case, 'decided_date': date, 'name': name,
                            'role': role, 'org': org, 'title': title,
                            'cause': cause[:400], 'doc_url': doc.group(1) if doc else None,
                            'progress': prog or None})
        n_before = len(outkeys)
        print(f'page {p}: 累計 {len(out)} 列')
        if p >= 3 and len(out) == n_before and not trs:
            break
        time.sleep(1)

    print(f'上傳 {len(out)} 列…')
    for j in range(0, len(out), 100):
        r = requests.post(
            f'{SB_URL}/rest/v1/judge_impeachments?on_conflict=case_no,name',
            headers={**HEAD, 'Content-Type': 'application/json',
                     'Prefer': 'resolution=merge-duplicates'},
            json=out[j:j + 100], timeout=60)
        r.raise_for_status()
    print('done')


if __name__ == '__main__':
    main()
