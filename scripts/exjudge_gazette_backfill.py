# -*- coding: utf-8 -*-
"""
前法官/檢察官公報回補線（Phase 1）
候選名單（scripts/.exjudge_backfill_work/candidates.csv：現行律師名冊、民國89前領證、
領證年齡>=38、無 ex_judicial 記錄）逐名查政大「中華民國政府官職資料庫」
(gpost.lib.nccu.edu.tw)，萃取「曾任推事/法官/檢察官」的任免令事實層。

裁判書署名資料 2000 年才全量，此前退場轉律師的法官五訊號比對是系統性零覆蓋；
本線只回補「經歷事實」（機關/任免日/公報期數），案件量統計無源可補。
著作權注意：僅逐名點查萃取公報記載之事實並標注來源，不複製資料庫。

用法:
  python exjudge_gazette_backfill.py crawl      # 逐名抓取（可續跑，快取 JSONL）
  python exjudge_gazette_backfill.py classify   # 判讀司法官事件＋同名消歧 → hits.json
  python exjudge_gazette_backfill.py upload     # hits.json → Supabase（需 .env service key）
"""
import csv
import io
import json
import math
import os
import random
import re
import sys
import time
from urllib.parse import quote

import requests

sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

BASE = 'https://gpost.lib.nccu.edu.tw'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'
WORK = os.path.join(os.path.dirname(__file__), '.exjudge_backfill_work')
CAND = os.path.join(WORK, 'candidates.csv')
CACHE = os.path.join(WORK, 'gpost_cache.jsonl')
HITS = os.path.join(WORK, 'hits.json')

# 司法官職務判定（早年職稱是「推事」；行政法院用「評事」）。
# 檢察側必須含「檢察官/檢察長」職稱本身——檢察署/處的書記官、觀護人、法醫等非審檢職不算
RE_JUDGE = re.compile(r'(法院|司法院).*(推事|法官|評事)|(推事|評事).*(法院)')
RE_PROS = re.compile(r'檢察官|檢察長')
RE_NOT_JUDICIAL = re.compile(r'書記官|觀護人|法醫|檢驗員|執達員|通譯|錄事|庭丁')


def load_candidates():
    with open(CAND, encoding='utf-8-sig') as f:
        return list(csv.DictReader(f))


def load_cache():
    done = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding='utf-8') as f:
            for line in f:
                r = json.loads(line)
                done[r['name']] = r
    return done


def fetch_name(sess, name):
    """query.php 建 session query → display.php 逐頁抓，回傳 (rows, total)"""
    q = 'name:' + name
    sess.get(f'{BASE}/query.php?q={quote(q)}', timeout=30)
    rows, total, page = [], None, 1
    while True:
        url = (f'{BASE}/display.php?&q={quote(q)}&pagenumber=100'
               f'&order=default&orderype=asc&tpl=rough&page={page}')
        r = sess.get(url, timeout=30, headers={'Referer': f'{BASE}/query.php'})
        # 站方對不同 client 回不同編碼（curl 拿到 Big5、requests 拿 UTF-8）；以宣告為準
        enc = 'utf-8' if b'charset=utf-8' in r.content[:2000].lower() or 'utf-8' in (r.headers.get('Content-Type') or '').lower() else 'cp950'
        html = r.content.decode(enc, errors='replace')
        # 原始頁面留檔（parse bug 免重爬；reparse 指令由此重建快取）
        os.makedirs(os.path.join(WORK, 'pages'), exist_ok=True)
        with open(os.path.join(WORK, 'pages', f'{name}_{page}.html'), 'w', encoding='utf-8') as pf:
            pf.write(html)
        if total is None:
            m = re.search(r'共有\s*(\d+)\s*筆', html)
            total = int(m.group(1)) if m else 0
        rows += parse_rows(html)
        if total == 0 or page >= math.ceil(total / 100):
            break
        page += 1
        time.sleep(0.6)
    return rows, total


def parse_rows(html):
    """display.php 資料表 → [{date,action,reason,org,gazette,pdf}]
    注意：資料列開頭有兩個被 <!-- --> 註解掉的 td，先剝註解否則欄位位移 2 格"""
    body_m = re.search(r'<tbody>(.*?)</tbody>', html, re.S)
    if not body_m:
        return []
    out = []
    for tr in re.findall(r'<tr[^>]*>(.*?)</tr>', body_m.group(1), re.S):
        tr = re.sub(r'<!--.*?-->', '', tr, flags=re.S)
        tds = re.findall(r'<td[^>]*>(.*?)</td>', tr, re.S)
        if len(tds) < 7:
            continue
        cell = [re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', c)).strip() for c in tds]
        pdf = re.search(r'href="(/GovIMG/[^"]+)"', tds[6])
        out.append({
            'category': cell[1], 'date': cell[2], 'action': cell[3],
            'reason': cell[4], 'org': cell[5], 'gazette': cell[6],
            'pdf': (BASE + pdf.group(1)) if pdf else None,
        })
    return out


def cmd_crawl():
    cands = load_candidates()
    done = load_cache()
    todo = [c for c in cands if c['name'] not in done]
    random.shuffle(todo)  # Windows getaddrinfo 卡死防呆：打散請求順序
    print(f'候選 {len(cands)}、已快取 {len(done)}、待抓 {len(todo)}')
    t0 = time.time()
    with open(CACHE, 'a', encoding='utf-8') as out:
        for i, c in enumerate(todo, 1):
            sess = requests.Session()
            sess.headers['User-Agent'] = UA
            try:
                rows, total = fetch_name(sess, c['name'])
            except Exception as e:
                print(f'  [{i}/{len(todo)}] {c["name"]} 失敗: {e}（下輪續跑）')
                time.sleep(3)
                continue
            out.write(json.dumps({'name': c['name'], 'total': total, 'rows': rows},
                                 ensure_ascii=False) + '\n')
            out.flush()
            if i % 20 == 0 or i == len(todo):
                rate = (time.time() - t0) / i
                print(f'  [{i}/{len(todo)}] 平均 {rate:.1f}s/人，預估剩 {rate*(len(todo)-i)/60:.1f} 分')
            time.sleep(1.0)
    print('crawl 完成')


def cmd_reparse():
    """從留檔頁面重建快取（parse 修正後免重爬）"""
    import glob
    pages = {}
    for p in glob.glob(os.path.join(WORK, 'pages', '*.html')):
        base = os.path.basename(p)[:-5]
        name, page = base.rsplit('_', 1)
        pages.setdefault(name, []).append((int(page), p))
    with open(CACHE, 'w', encoding='utf-8') as out:
        for name, pl in pages.items():
            rows, total = [], 0
            for _, p in sorted(pl):
                html = open(p, encoding='utf-8').read()
                m = re.search(r'共有\s*(\d+)\s*筆', html)
                if m:
                    total = int(m.group(1))
                rows += parse_rows(html)
            out.write(json.dumps({'name': name, 'total': total, 'rows': rows},
                                 ensure_ascii=False) + '\n')
    print(f'reparse 完成：{len(pages)} 位')


def roc_year(d):
    # 公報日期兩種格式：080-03-18 與 105.11.21
    m = re.match(r'(\d{2,3})[-.]', d or '')
    return int(m.group(1)) if m else None


def cmd_classify():
    cands = {c['name']: c for c in load_candidates()}
    done = load_cache()
    hits, review = [], []
    for name, rec in done.items():
        jud = []
        for r in rec['rows']:
            org = r['org']
            # 非審檢職（書記官/觀護人/典試委員…）排除，避免「檢察處書記官」誤入
            if RE_NOT_JUDICIAL.search(org) or '考試' in org or '典試' in org:
                continue
            if RE_JUDGE.search(org):
                kind = 'judge'
            elif RE_PROS.search(org):
                kind = 'prosecutor'
            else:
                continue
            jud.append(dict(r, kind=kind))
        if not jud:
            continue
        c = cands[name]
        lic_y = int(c['lic_year']) if c['lic_year'] else None
        birth = int(c['birth_year']) if c['birth_year'] else None
        years = [y for y in (roc_year(r['date']) for r in jud) if y]
        flags = []
        # 防呆1：任命時年齡 24-72（同名不同代誤併主要靠這道）
        if birth and years:
            ages = [y - birth for y in years]
            if min(ages) < 24 or max(ages) > 72:
                flags.append(f'age_out({min(ages)}-{max(ages)})')
        # 防呆2：領證年應在最後一筆司法官任免之後（轉任次序）
        if lic_y and years and max(years) > lic_y:
            flags.append(f'lic_before_exit(last={max(years)},lic={lic_y})')
        item = {'name': name, 'lic_year': lic_y, 'birth_year': birth,
                'office': c.get('office'), 'state_desc': c.get('state_desc'),
                'total_rows': rec['total'], 'judicial_events': jud, 'flags': flags,
                'kinds': sorted({r['kind'] for r in jud})}
        (review if flags else hits).append(item)
    json.dump({'hits': hits, 'review': review}, open(HITS, 'w', encoding='utf-8'),
              ensure_ascii=False, indent=1)
    print(f'自動通過 {len(hits)} 位、待人工覆核 {len(review)} 位 → {HITS}')
    for h in hits:
        ev = h['judicial_events']
        print(f"  ✓ {h['name']} ({'/'.join(h['kinds'])}) {ev[0]['date']}~{ev[-1]['date']} "
              f"{ev[-1]['org'][:30]}")
    for h in review:
        print(f"  ? {h['name']} flags={h['flags']}")


def cmd_upload():
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
    url = os.environ['SUPABASE_URL'].strip()
    key = os.environ['SUPABASE_SERVICE_KEY'].strip()
    hd = {'apikey': key, 'Authorization': f'Bearer {key}',
          'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates'}
    data = json.load(open(HITS, encoding='utf-8'))
    people = [h for h in data['hits'] if not h.get('dropped')] + \
             [h for h in data['review'] if h.get('approved')]
    ev_rows, sum_rows = [], []
    for h in people:
        for e in h['judicial_events']:
            y = roc_year(e['date'])
            ev_rows.append({
                'name': h['name'], 'kind': e['kind'], 'action': e['action'],
                'reason': e['reason'],
                # UNIQUE 鍵含 NULL 不擋重複（見 reference_postgres_unique_null）→ 空值存 ''
                'order_date_roc': e['date'] or '', 'org': e['org'],
                'gazette': e['gazette'], 'pdf_url': e['pdf'],
            })
        for kind in h['kinds']:
            evs = [e for e in h['judicial_events'] if e['kind'] == kind]
            ys = [y for y in (roc_year(e['date']) for e in evs) if y]
            sum_rows.append({
                'name': h['name'], 'kind': kind,
                'first_yyyymm': f'{1911+min(ys)}01' if ys else None,
                'last_yyyymm': f'{1911+max(ys)}12' if ys else None,
                'active_months': None, 'case_count_total': None,
                'main_org': evs[-1]['org'], 'lic_year': h['lic_year'],
                'overlap_years': 0, 'confidence': 'high' if not h.get('flags') else 'medium',
                'source': 'gazette',
            })
    r = requests.post(f'{url}/rest/v1/ex_judicial_gazette_events'
                      '?on_conflict=name,kind,action,order_date_roc,org',
                      headers=hd, json=ev_rows, timeout=60)
    print('events:', r.status_code, r.text[:200])
    hd2 = dict(hd, Prefer='resolution=merge-duplicates')
    r = requests.post(f'{url}/rest/v1/ex_judicial_lawyers?on_conflict=name,kind',
                      headers=hd2, json=sum_rows, timeout=60)
    print('summary:', r.status_code, r.text[:200])
    print(f'上傳 {len(people)} 位 / events {len(ev_rows)} 筆 / summary {len(sum_rows)} 筆')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'crawl'
    {'crawl': cmd_crawl, 'classify': cmd_classify, 'upload': cmd_upload,
     'reparse': cmd_reparse}[cmd]()
