# -*- coding: utf-8 -*-
"""法官評鑑委員會決議書爬蟲：司法院「決議書查詢及追蹤資訊」→ judge_evaluations 表（mig 127）。

來源：https://www.judicial.gov.tw/tw/lp-1700-1-{page}-20.html（~91 頁、~1,800 筆，
含審查決議「審評字」與評鑑決議「評字」，2012 年迄今全量）。
列表頁每筆含：決議日期、案號、主文摘要、決議書 PDF 連結；法官姓名僅在 PDF 內文，
且「不付評鑑／不成立」案一律遮罩（賴○○），僅「成立」案可能具名 → PDF 只對
成立類下載解析，遮罩名存 name_masked（法院層級訊號仍可用）。
冪等：以 (case_no, doc_url) upsert。

用法：
  python judge_evaluations.py list     # 爬列表 → .eval_work/list.json
  python judge_evaluations.py docs     # 下載成立類 PDF 抽姓名/法院 → 更新 list.json
  python judge_evaluations.py upload   # upsert 到 judge_evaluations
  python judge_evaluations.py all      # 以上全部（月增量手動跑即可，量極低）
"""
import io
import json
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

WORK = os.path.join(HERE, '.eval_work')
os.makedirs(WORK, exist_ok=True)
LIST_JSON = os.path.join(WORK, 'list.json')
BASE = 'https://www.judicial.gov.tw'

# 列表項：<li>…<a href="/tw/cp-1700-…"><span class="num">115-7-13</span>
# <span class="text">115年度 審評字 第167號</span></a>…<div class="text">…主文…
# <a href="…dl-…">…</a>…</div><div class="dep">[ 115-07-23更新 ]</div></li>
RE_ITEM = re.compile(
    r'<a href="(/tw/cp-1700-[^"]+)"[^>]*>\s*<span class="num">([\d\-]+)</span>'
    r'<span class="text">([^<]+)</span></a>(.*?)<div class="dep">', re.S)
RE_DL = re.compile(r'href="(https://www\.judicial\.gov\.tw/tw/dl-[^"]+|/tw/dl-[^"]+)"')

# 主文 → 結果分類（依序比對，先中先贏）
RESULTS = [
    ('不付評鑑', '不付評鑑'),
    ('不成立', '請求不成立'),
    ('免議', '免議'),
    ('不受理', '不受理'),
    ('懲戒法院', '成立：移送懲戒法院'),
    ('職務法庭', '成立：移送懲戒法院'),
    ('監察院', '成立：移送監察院'),
    ('職務監督', '成立：建議職務監督'),
    ('人事審議', '成立：建議職務監督'),
    ('成立', '成立'),
]

# PDF 內受評鑑人行：「受評鑑法官  賴○○  臺灣臺北地方法院法官」。
# 實測 2012-2026 全量：成立案公開版也一律遮罩（姓＋○○），故 masked 分支優先；
# 遮罩字元有 ○(U+25CB)/〇(U+3007)/Ｏ(全形O) 三種混用。
RE_EVALUATEE = re.compile(
    r'受\s*評\s*鑑\s*(?:法\s*官|人)\s*[:：]?\s*'
    r'([一-鿿]\s*[○〇Ｏ]{1,3}|[一-鿿]{2,4}(?=\s))\s*'
    r'((?:前)?[^\n，。；]{0,24}?(?:地方法院|高等法院|行政法院|最高法院|'
    r'少年及家事法院|智慧財產(?:及商業)?法院|懲戒法院|公務員懲戒委員會)'
    r'[^\n，。；]{0,12})?')
# 主文摘要內的遮罩名：「受評鑑法官張○○報由…」（PDF 缺附件時的 fallback）
RE_SUM_NAME = re.compile(r'受評鑑法官([一-鿿][○〇Ｏ]{1,3})')


def roc_date(s):
    m = re.match(r'(\d{2,3})-(\d{1,2})-(\d{1,2})', (s or '').strip())
    if not m:
        return None
    return f'{int(m.group(1)) + 1911:04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}'


def classify(summary):
    for k, v in RESULTS:
        if k in (summary or ''):
            return v
    return '其他'


def crawl_list():
    s = requests.Session()
    s.headers['User-Agent'] = UA
    rows, seen = [], set()
    p = 1
    while p < 200:
        r = s.get(f'{BASE}/tw/lp-1700-1-{p}-20.html', timeout=60)
        r.encoding = 'utf-8'
        items = RE_ITEM.findall(r.text)
        new = 0
        for href, num, title, block in items:
            case_no = re.sub(r'[*.\s]+', '', title)  # 早年項目標題尾綴「*.*」雜訊
            mdl = RE_DL.search(block)
            doc_url = (mdl.group(1) if mdl else '')
            if doc_url.startswith('/'):
                doc_url = BASE + doc_url
            key = (case_no, doc_url)
            if key in seen:
                continue
            seen.add(key)
            new += 1
            # 主文：block 內去 tag 後找「主文：…」段
            text = re.sub(r'<[^>]+>', '\n', block)
            text = re.sub(r'[ \t　\xa0]+', '', text)  # 主文標籤夾 \xa0（不斷行空白）
            msum = re.search(r'主文[:：]?\s*\n?([^\n]{2,200})', text.replace('主 文', '主文'))
            summary = (msum.group(1).strip() if msum else '')
            rows.append({
                'case_no': case_no, 'decided_date': roc_date(num),
                'summary': summary, 'result': classify(summary),
                'doc_url': doc_url, 'source_url': BASE + href,
            })
        print(f'  page {p}: {len(items)} 項（新 {new}）', flush=True)
        if not items or new == 0:
            break
        p += 1
        time.sleep(0.4)
    with open(LIST_JSON, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False, indent=0)
    from collections import Counter
    print(f'共 {len(rows)} 筆 → {LIST_JSON}')
    print('結果分佈:', dict(Counter(r["result"] for r in rows)))


def parse_docs():
    """成立類（＋其他/無摘要）下載 PDF 抽受評鑑人；遮罩名存 name_masked。"""
    from pypdf import PdfReader
    rows = json.load(open(LIST_JSON, encoding='utf-8'))
    s = requests.Session()
    s.headers['User-Agent'] = UA
    todo = [r for r in rows if r['doc_url'] and (
        r['result'].startswith('成立') or r['result'] in ('其他',) or not r['summary'])]
    print(f'待下載 PDF：{len(todo)} / {len(rows)}')
    for i, row in enumerate(todo):
        fid = re.search(r'dl-(\d+)-', row['doc_url'])
        cache = os.path.join(WORK, f'doc_{fid.group(1)}.pdf') if fid else None
        try:
            if cache and os.path.exists(cache) and os.path.getsize(cache) > 500:
                blob = open(cache, 'rb').read()
            else:
                rr = s.get(row['doc_url'], timeout=90)
                blob = rr.content
                if cache and blob[:4] == b'%PDF':
                    with open(cache, 'wb') as f:
                        f.write(blob)
                time.sleep(0.5)
            if blob[:4] != b'%PDF':
                row['parse_note'] = f'非PDF({blob[:8]!r})'
                continue
            t = ''.join(pg.extract_text() or '' for pg in PdfReader(io.BytesIO(blob)).pages)
            flat = t[:3000]
            m = RE_EVALUATEE.search(flat)
            if m:
                nm = re.sub(r'\s', '', m.group(1)).replace('〇', '○').replace('Ｏ', '○')
                org = re.sub(r'\s', '', m.group(2) or '')
                # org 去掉「法官」等職稱尾綴保留機關
                row['org'] = re.sub(r'(候補|試署)?(法官|庭長|院長)+（?[^）]*）?$', '', org) or None
                if '○' in nm:
                    row['name_masked'] = nm
                else:
                    row['name'] = nm
            # 主文（列表無摘要時從 PDF 補）
            if not row['summary']:
                ms = re.search(r'決\s*議\s*\n?([^\n]{2,120})', flat)
                if ms:
                    row['summary'] = re.sub(r'\s', '', ms.group(1))
                    row['result'] = classify(row['summary'])
        except Exception as e:  # noqa: BLE001 — 單筆失敗不擋整批
            row['parse_note'] = str(e)[:120]
        if (i + 1) % 20 == 0:
            print(f'  …{i + 1}/{len(todo)}', flush=True)
    # PDF 沒抽到時，從主文摘要撈遮罩名（「受評鑑法官張○○報由…」）
    for r in rows:
        if not r.get('name') and not r.get('name_masked'):
            ms = RE_SUM_NAME.search((r.get('summary') or '').replace('〇', '○').replace('Ｏ', '○'))
            if ms:
                r['name_masked'] = ms.group(1)
    with open(LIST_JSON, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False, indent=0)
    named = sum(1 for r in rows if r.get('name'))
    masked = sum(1 for r in rows if r.get('name_masked'))
    print(f'具名 {named}、遮罩 {masked}')


def upload():
    rows = json.load(open(LIST_JSON, encoding='utf-8'))
    payload = [{
        'case_no': r['case_no'], 'decided_date': r['decided_date'],
        'summary': (r.get('summary') or '')[:400] or None, 'result': r['result'],
        'name': r.get('name'), 'name_masked': r.get('name_masked'),
        'org': r.get('org'), 'doc_url': r['doc_url'] or '',
        'source_url': r['source_url'],
    } for r in rows]
    for i in range(0, len(payload), 500):
        r = requests.post(
            f'{SB_URL}/rest/v1/judge_evaluations?on_conflict=case_no,doc_url',
            headers={**HEAD, 'Prefer': 'resolution=merge-duplicates',
                     'Content-Type': 'application/json'},
            json=payload[i:i + 500], timeout=120)
        if r.status_code not in (200, 201, 204):
            print(f'upload batch {i} 失敗 {r.status_code}: {r.text[:300]}')
            sys.exit(1)
        print(f'  upsert {i}~{i + len(payload[i:i + 500])}')
    print(f'完成：{len(payload)} 筆')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if cmd in ('list', 'all'):
        crawl_list()
    if cmd in ('docs', 'all'):
        parse_docs()
    if cmd in ('upload', 'all'):
        upload()
