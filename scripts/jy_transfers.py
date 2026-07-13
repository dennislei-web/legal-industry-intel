"""
司法院人審會決議 → 法官遷調邊（judge_transfers）

資料來源：司法院全球資訊網「歷次人審會決議」lp-1915（新版網站，2019-12 之後）。
每筆決議是一頁新聞稿，遷調名單直接寫在內文（無附件），格式大致為：
  「調派臺灣澎湖地方法院法官兼院長楊國精為臺灣彰化地方法院法官兼院長」
多人條目以頓號/分號連寫，另有「自115年9月1日生效」等生效日描述。

用法:
  python jy_transfers.py list                 # 抓 lp-1915 全部決議連結 → _jy_transfers_index.json
  python jy_transfers.py fetch                # 逐筆抓決議內文 → _jy_transfers_pages/
  python jy_transfers.py parse                # 解析成邊 → _jy_transfers_edges.json（含統計）
  python jy_transfers.py upload               # 邊 → Supabase judge_transfers（冪等：先清 source_url 再插）
"""
import os
import re
import sys
import json
import time
import requests
from bs4 import BeautifulSoup

sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

BASE = 'https://www.judicial.gov.tw'
LIST_URL = BASE + '/tw/lp-1915-1-{page}-60.html'   # 60/頁
WORK = os.path.dirname(os.path.abspath(__file__))
INDEX_F = os.path.join(WORK, '_jy_transfers_index.json')
PAGES_D = os.path.join(WORK, '_jy_transfers_pages')
EDGES_F = os.path.join(WORK, '_jy_transfers_edges.json')
UA = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'}


def fetch_list():
    items = []
    for page in range(1, 10):
        url = LIST_URL.format(page=page)
        r = requests.get(url, headers=UA, timeout=30)
        r.raise_for_status()
        soup = BeautifulSoup(r.text, 'html.parser')
        rows = []
        for a in soup.select('a[href*="cp-"]'):
            title = a.get_text(strip=True)
            if '人事審議委員會' not in title:
                continue
            href = a['href']
            if not href.startswith('http'):
                href = BASE + href
            # 日期通常在同列的 <td> 或前後節點
            tr = a.find_parent('tr')
            date = ''
            if tr:
                m = re.search(r'\b(1[01]\d)-(\d{2})-(\d{2})\b', tr.get_text())
                if m:
                    date = m.group(0)
            rows.append({'title': title, 'url': href, 'roc_date': date})
        print(f'page {page}: {len(rows)} items')
        if not rows:
            break
        items.extend(rows)
        time.sleep(1)
    # 去重（不同頁可能重複）
    seen, uniq = set(), []
    for it in items:
        if it['url'] in seen:
            continue
        seen.add(it['url'])
        uniq.append(it)
    with open(INDEX_F, 'w', encoding='utf-8') as f:
        json.dump(uniq, f, ensure_ascii=False, indent=1)
    print(f'total {len(uniq)} decisions -> {INDEX_F}')


def fetch_pages():
    os.makedirs(PAGES_D, exist_ok=True)
    with open(INDEX_F, encoding='utf-8') as f:
        items = json.load(f)
    for i, it in enumerate(items):
        key = re.search(r'cp-\d+-(\d+)-', it['url'])
        fid = key.group(1) if key else str(i)
        out = os.path.join(PAGES_D, f'{fid}.json')
        if os.path.exists(out):
            continue
        r = None
        for attempt in range(4):
            try:
                r = requests.get(it['url'], headers=UA, timeout=30)
                r.raise_for_status()
                break
            except requests.RequestException as ex:
                wait = 15 * (attempt + 1)
                print(f'  retry {attempt+1}/3 in {wait}s: {ex}')
                time.sleep(wait)
        if r is None or r.status_code >= 300:
            print(f'  SKIP（多次失敗）: {it["url"]}')
            continue
        soup = BeautifulSoup(r.text, 'html.parser')
        main = soup.select_one('.cp') or soup.select_one('main') or soup.body
        text = main.get_text('\n', strip=True)
        with open(out, 'w', encoding='utf-8') as f:
            json.dump({**it, 'text': text}, f, ensure_ascii=False)
        print(f'[{i+1}/{len(items)}] {it["title"]} ({len(text)} chars)')
        time.sleep(1)


# ---------- 解析（文法核心在 jy_transfers_parse.py，含「等N人」checksum 驗證）----------
def parse_pages():
    from jy_transfers_parse import parse_text
    edges, all_warns = [], []
    for fn in sorted(os.listdir(PAGES_D)):
        if not fn.endswith('.json'):
            continue
        with open(os.path.join(PAGES_D, fn), encoding='utf-8') as f:
            page = json.load(f)
        fallback = None
        if page.get('roc_date'):
            y, m, d = page['roc_date'].split('-')
            fallback = f'{int(y)+1911:04d}-{m}-{d}'
        page_edges, warns = parse_text(page['text'], fallback)
        for e in page_edges:
            e['decision_title'] = page['title']
            e['source_url'] = page['url']
        edges.extend(page_edges)
        for w in warns:
            all_warns.append(f'{page["title"]}: {w}')
    with open(EDGES_F, 'w', encoding='utf-8') as f:
        json.dump(edges, f, ensure_ascii=False, indent=1)
    kinds = {}
    for e in edges:
        kinds[e['kind']] = kinds.get(e['kind'], 0) + 1
    print(f'{len(edges)} edges {kinds} -> {EDGES_F}')
    if all_warns:
        print(f'*** {len(all_warns)} warnings（解析器需補樣態，勿直接上傳）***')
        for w in all_warns:
            print(' !', w)


def upload():
    from dotenv import load_dotenv
    load_dotenv(os.path.join(WORK, '.env'), override=False)
    url = os.environ['SUPABASE_URL'].strip()
    key = os.environ['SUPABASE_SERVICE_KEY'].strip()
    hdr = {'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    with open(EDGES_F, encoding='utf-8') as f:
        edges = json.load(f)
    # 冪等：整表重建（量小，全刪全插最單純）
    r = requests.delete(f'{url}/rest/v1/judge_transfers?id=gt.0', headers=hdr, timeout=60)
    r.raise_for_status()
    for i in range(0, len(edges), 500):
        chunk = edges[i:i+500]
        r = requests.post(f'{url}/rest/v1/judge_transfers', headers=hdr,
                          json=chunk, timeout=60)
        if r.status_code >= 300:
            print('ERR', r.status_code, r.text[:500])
            sys.exit(1)
        print(f'uploaded {i+len(chunk)}/{len(edges)}')
    print('done')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    {'list': fetch_list, 'fetch': fetch_pages, 'parse': parse_pages, 'upload': upload}.get(
        cmd, lambda: print(__doc__))()
