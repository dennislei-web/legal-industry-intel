"""政府標案（法律服務）爬蟲：pcc-api.openfun.app → gov_tenders / gov_tender_firms

資料源是 g0v 政府電子採購網鏡像（Elasticsearch 分詞搜尋，非子字串），
用「法律」+「律師」兩個查詢詞聯集涵蓋法律事務所/律師事務所/個人律師名義投標。

用法:
  python gov_tenders.py search           # 抓 searchbycompanyname 全頁 -> _gov_tenders_search.json
  python gov_tenders.py detail           # 逐案抓決標明細（增量快取）-> _gov_tenders_detail.json
  python gov_tenders.py upload           # 解析明細並上傳 Supabase
  python gov_tenders.py run              # search + detail + upload
  python gov_tenders.py run-shard K N    # GitHub Actions 用：search + 第 K/N 分片 detail + upload
                                         #（API 限流 ~20 req/min 是按 IP，分片跑在不同 runner 可並行）
"""
import json
import os
import re
import sys
import time
import zlib
import threading
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

from utils import get_supabase, log

API_BASE = 'https://pcc-api.openfun.app/api'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'
QUERIES = ['法律', '律師']  # 法律 / 律師
HERE = os.path.dirname(os.path.abspath(__file__))
SEARCH_CACHE = os.path.join(HERE, '_gov_tenders_search.json')
DETAIL_CACHE = os.path.join(HERE, '_gov_tenders_detail.json')


# 全域節流：API 有 rate limit（429），跨線程共用最小請求間隔
_rl_lock = threading.Lock()
_rl_next = [0.0]
MIN_INTERVAL = 0.6  # 秒/請求，約 1.7 req/s


def _throttle():
    with _rl_lock:
        now = time.time()
        wait = _rl_next[0] - now
        _rl_next[0] = max(now, _rl_next[0]) + MIN_INTERVAL
    if wait > 0:
        time.sleep(wait)


def api_get(path, params, retries=5):
    qs = urllib.parse.urlencode(params)
    url = f'{API_BASE}/{path}?{qs}'
    for attempt in range(retries):
        _throttle()
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except Exception as e:
            if isinstance(e, urllib.error.HTTPError) and e.code == 429:
                time.sleep(15 * (attempt + 1))  # 被限流要退久一點
            elif attempt < retries - 1:
                time.sleep(2 * (attempt + 1))
            if attempt == retries - 1:
                log(f'  放棄 {url}: {e}')
                return None


def cmd_search():
    """抓兩個查詢詞的全部搜尋結果頁，按 filename 去重後存快取。"""
    records = {}
    for q in QUERIES:
        first = api_get('searchbycompanyname', {'query': q, 'page': 1})
        if not first:
            raise RuntimeError(f'查詢 {q} 第 1 頁失敗')
        pages = first['total_pages']
        log(f'查詢「{q}」: {first["total_records"]} 筆 / {pages} 頁')
        for rec in first['records']:
            records[rec['filename']] = rec
        for p in range(2, pages + 1):
            d = api_get('searchbycompanyname', {'query': q, 'page': p})
            if not d:
                continue
            for rec in d['records']:
                records[rec['filename']] = rec
            if p % 10 == 0:
                log(f'  {q} 第 {p}/{pages} 頁，累計 {len(records)} 筆')
            time.sleep(0.3)
    with open(SEARCH_CACHE, 'w', encoding='utf-8') as f:
        json.dump(list(records.values()), f, ensure_ascii=False)
    log(f'search 完成：去重後 {len(records)} 筆 -> {SEARCH_CACHE}')


def load_search():
    with open(SEARCH_CACHE, encoding='utf-8') as f:
        return json.load(f)


def db_existing_keys():
    """DB 已有的 tender_key 不重抓（月更增量；決標紀錄基本不變動）。"""
    try:
        sb = get_supabase()
        keys, page = set(), 0
        while True:
            rows = (sb.table('gov_tenders').select('tender_key')
                    .range(page * 1000, page * 1000 + 999).execute().data)
            keys.update(r['tender_key'] for r in rows)
            if len(rows) < 1000:
                return keys
            page += 1
    except Exception as e:
        log(f'查 DB 既有案失敗（視為空，全部重抓）: {e}')
        return set()


def save_detail_cache(cache):
    # 先寫暫存檔再 rename，避免中途被砍留下半截 JSON
    tmp = DETAIL_CACHE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(cache, f, ensure_ascii=False)
    os.replace(tmp, DETAIL_CACHE)


def cmd_detail(workers=6, shard=None):
    """對每個 (unit_id, job_number) 抓一次明細，並行 + 快取增量續跑。

    shard=(k, n) 時只處理 crc32(key) % n == k 的案件（Actions 分片用）。
    回傳失敗案數（呼叫端決定要不要重試）。
    """
    cases = {}
    for rec in load_search():
        key = f"{rec['unit_id']}|{rec['job_number']}"
        cases.setdefault(key, rec)
    if shard:
        k, n = shard
        cases = {key: v for key, v in cases.items()
                 if zlib.crc32(key.encode()) % n == k}
    cache = {}
    if os.path.exists(DETAIL_CACHE):
        try:
            with open(DETAIL_CACHE, encoding='utf-8') as f:
                cache = json.load(f)
        except ValueError:
            log('快取檔損毀（前次中斷），重新累積')
    in_db = db_existing_keys()
    todo = [k for k in cases if k not in cache and k not in in_db]
    log(f'detail{f"（分片 {shard[0]}/{shard[1]}）" if shard else ""}: '
        f'共 {len(cases)} 案，DB 已有 {len(in_db & set(cases))}，'
        f'已快取 {len(cache)}，待抓 {len(todo)}')

    def fetch_one(key):
        unit_id, job_number = key.split('|', 1)
        d = api_get('tender', {'unit_id': unit_id, 'job_number': job_number})
        return d['records'] if d else None  # 失敗回 None，不寫入快取以便下次重試

    t0 = time.time()
    failed = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(fetch_one, k): k for k in todo}
        done = 0
        for fut in as_completed(futs):
            recs = fut.result()
            if recs is None:
                failed += 1
            else:
                cache[futs[fut]] = recs
            done += 1
            if done % 200 == 0:
                save_detail_cache(cache)
                rate = done / (time.time() - t0)
                eta = (len(todo) - done) / rate / 60 if rate else 0
                log(f'  進度 {done}/{len(todo)}（{rate:.1f} 案/秒，剩約 {eta:.0f} 分鐘）')
    save_detail_cache(cache)
    log(f'detail 完成（失敗 {failed} 案，重跑 detail 可續補）-> {DETAIL_CACHE}')
    return failed


RE_ROC_DATE = re.compile(r'(\d{2,3})/(\d{1,2})/(\d{1,2})')


def roc_to_iso(s):
    m = RE_ROC_DATE.search(s or '')
    if not m:
        return None
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if not (1 <= mo <= 12 and 1 <= d <= 31):
        return None
    return f'{y + 1911:04d}-{mo:02d}-{d:02d}'


def parse_amount(s):
    if not s:
        return None
    digits = re.sub(r'[^\d]', '', s.split('.')[0])
    return int(digits) if digits else None


def pick_award_record(recs):
    """從一案的多筆紀錄挑最新的決標紀錄（排除無法決標）。"""
    awards = [r for r in recs
              if re.search(r'決標|彙送', r.get('brief', {}).get('type', ''))
              and '無法決標' not in r['brief']['type']]
    return max(awards, key=lambda r: r.get('date', 0)) if awards else None


def parse_case(key, recs):
    rec = pick_award_record(recs)
    if not rec or not isinstance(rec.get('detail'), dict):
        return None, []
    det = rec['detail']
    unit_id, job_number = key.split('|', 1)

    def g(field):
        return det.get(field)

    tender = {
        'tender_key': key,
        'unit_id': unit_id,
        'unit_name': rec.get('unit_name'),
        'job_number': job_number,
        'title': g('採購資料:標案名稱') or rec['brief'].get('title'),
        'category': g('採購資料:標的分類'),
        'procurement_method': g('採購資料:招標方式'),
        'award_method': g('採購資料:決標方式'),
        'budget_amount': parse_amount(g('採購資料:預算金額')),
        'award_date': roc_to_iso(g('決標資料:決標日期')),
        'total_amount': parse_amount(g('決標資料:總決標金額')),
        'award_type': rec['brief'].get('type'),
        'source_filename': rec.get('filename'),
        'source_date': rec.get('date'),
    }
    tender['award_year'] = int(tender['award_date'][:4]) if tender['award_date'] else None

    # 投標廠商區塊：投標廠商:投標廠商N:{廠商名稱|廠商代碼|是否得標|決標金額}
    firms = []
    n = 1
    while True:
        prefix = f'投標廠商:投標廠商{n}:'
        name = det.get(prefix + '廠商名稱')
        if not name:
            break
        firms.append({
            'tender_key': key,
            'firm_seq': n,
            'firm_uid': (det.get(prefix + '廠商代碼') or '').strip() or None,
            'firm_name': name.strip(),
            'is_winner': (det.get(prefix + '是否得標') or '').strip() == '是',
            'award_amount': parse_amount(det.get(prefix + '決標金額')),
        })
        n += 1

    # 沒有任何得標者（理論上決標紀錄都有，防呆）就跳過整案
    if not any(f['is_winner'] for f in firms):
        return None, []
    return tender, firms


def cmd_upload():
    with open(DETAIL_CACHE, encoding='utf-8') as f:
        cache = json.load(f)
    tenders, firms = [], []
    skipped = 0
    for key, recs in cache.items():
        t, fs = parse_case(key, recs)
        if t:
            tenders.append(t)
            firms.extend(fs)
        else:
            skipped += 1
    log(f'解析完成：{len(tenders)} 案有決標 / {len(firms)} 筆廠商列 / 跳過 {skipped} 案（無法決標或無明細）')

    sb = get_supabase()
    B = 50
    for i in range(0, len(tenders), B):
        sb.table('gov_tenders').upsert(tenders[i:i + B], on_conflict='tender_key').execute()
        time.sleep(0.5)
    log(f'gov_tenders 上傳完成 {len(tenders)} 列')
    # 廠商列先刪後插，避免舊 seq 殘留
    keys = [t['tender_key'] for t in tenders]
    for i in range(0, len(keys), 200):
        sb.table('gov_tender_firms').delete().in_('tender_key', keys[i:i + 200]).execute()
        time.sleep(0.3)
    for i in range(0, len(firms), B):
        sb.table('gov_tender_firms').upsert(firms[i:i + B], on_conflict='tender_key,firm_seq').execute()
        time.sleep(0.5)
    log(f'gov_tender_firms 上傳完成 {len(firms)} 列')


def detail_until_done(shard=None, max_rounds=3):
    for i in range(max_rounds):
        failed = cmd_detail(shard=shard)
        if not failed:
            return
        log(f'還有 {failed} 案失敗，60 秒後第 {i + 2} 輪續補')
        time.sleep(60)
    log('達重試上限，剩餘失敗案留待下次執行')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'run'
    if cmd == 'search':
        cmd_search()
    elif cmd == 'detail':
        if cmd_detail():
            sys.exit(3)  # 讓外層 retry 迴圈知道還有缺口
    elif cmd == 'upload':
        cmd_upload()
    elif cmd == 'run':
        cmd_search()
        detail_until_done()
        cmd_upload()
    elif cmd == 'run-shard':
        k, n = int(sys.argv[2]), int(sys.argv[3])
        cmd_search()
        detail_until_done(shard=(k, n))
        cmd_upload()
    else:
        print(__doc__)
