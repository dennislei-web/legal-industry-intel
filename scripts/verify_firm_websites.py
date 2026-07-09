"""
既有官網逐筆重驗（一次性清理 + 之後可重跑）
- 對 firm_websites 所有 website_url 非空的列：
  blocklist/外國 TLD → 直接不通過（不浪費 fetch）
  其餘抓「網域首頁」驗證含事務所主名
- 通過：website_url 正規化為首頁、verified=true
- 不通過：website_url/website_title/description 清空、verified=false
  （website_scraped 維持 true，避免每日爬蟲當成新事務所重爬）
- 直接用 requests 打 PostgREST（本機 .env 是新版 sb_secret key，
  舊版 supabase-py 會報 Invalid API key）
跑完記得 refresh_firm_stats_cache（用 supabase db query 直連，PostgREST 會超時）
"""
import io
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

import requests
from dotenv import load_dotenv

from website_verify import host_blocked, verify_firm_website

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

load_dotenv()
BASE = os.environ['SUPABASE_URL'].rstrip('/') + '/rest/v1'
KEY = os.environ['SUPABASE_SERVICE_KEY']
API_HEADERS = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}
WORKERS = 8


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def rest_get(path, params):
    r = requests.get(f'{BASE}/{path}', params=params, headers=API_HEADERS, timeout=30)
    r.raise_for_status()
    return r.json()


def rest_patch(path, params, body):
    h = dict(API_HEADERS)
    h['Content-Type'] = 'application/json'
    h['Prefer'] = 'return=minimal'
    r = requests.patch(f'{BASE}/{path}', params=params, headers=h, json=body, timeout=30)
    r.raise_for_status()


def fetch_all_with_url():
    rows, start = [], 0
    while True:
        page = rest_get('firm_websites', {
            'select': 'id,firm_name,website_url',
            'website_url': 'not.is.null',
            'offset': start, 'limit': 1000,
        })
        if not page:
            break
        rows.extend(page)
        if len(page) < 1000:
            break
        start += 1000
    return [x for x in rows if (x.get('website_url') or '').strip()]


def main():
    blocklist = {r['domain'] for r in rest_get('firm_website_blocklist', {'select': 'domain'})}
    log(f'blocklist 網域數: {len(blocklist)}')

    rows = fetch_all_with_url()
    log(f'待驗證官網: {len(rows)} 筆')

    def check(row):
        url = row['website_url']
        host = (urlparse(url).netloc or '').lower()
        if host_blocked(host, blocklist):
            return row, False, None, None, 'blocklist/外國TLD'
        ok, home, title = verify_firm_website(url, row['firm_name'], blocklist)
        return row, ok, home, title, ('通過' if ok else '首頁無所名/死站')

    results = []
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for i, res in enumerate(ex.map(check, rows), 1):
            results.append(res)
            if i % 50 == 0:
                ok_n = sum(1 for r in results if r[1])
                log(f'  [{i}/{len(rows)}] 通過 {ok_n}，{time.time()-t0:.0f}s')

    passed = [r for r in results if r[1]]
    failed = [r for r in results if not r[1]]
    log(f'驗證完成: 通過 {len(passed)} / 不通過 {len(failed)}')

    # 寫回 DB
    for idx, (row, ok, home, title, reason) in enumerate(results, 1):
        if ok:
            body = {'website_url': home, 'verified': True, 'verified_at': 'now()'}
            if title:
                body['website_title'] = title
        else:
            body = {'website_url': None, 'website_title': None, 'description': None,
                    'verified': False, 'verified_at': 'now()'}
        rest_patch('firm_websites', {'id': f'eq.{row["id"]}'}, body)
        if idx % 200 == 0:
            log(f'  寫回 {idx}/{len(results)}')

    # 失敗清單存檔備查
    with io.open('verify_failed.log', 'w', encoding='utf-8') as f:
        for row, ok, home, title, reason in failed:
            f.write(f"{row['firm_name']}\t{row['website_url']}\t{reason}\n")
    log('失敗清單: scripts/verify_failed.log')
    log('⚠️ 記得 refresh_firm_stats_cache（supabase db query 直連跑）')


if __name__ == '__main__':
    main()
