"""
Lawsnote 法官案件數爬蟲
用 Playwright 自動搜尋每位法官的裁判書數量

使用方式:
  1. 先手動登入 Lawsnote (lawsnote.com) 在 Chrome
  2. 執行此腳本，它會打開可見的瀏覽器視窗
  3. 第一次執行時需要手動登入 Lawsnote（腳本會等你登入）
  4. 之後會自動逐一搜尋每位法官

  python scrape_lawsnote_judge_cases.py              # 全部
  python scrape_lawsnote_judge_cases.py --limit 10   # 測試 10 位
  python scrape_lawsnote_judge_cases.py --court 臺灣臺北地方法院  # 指定法院
"""
import sys
import re
import argparse
import time
import os

sys.stdout.reconfigure(encoding='utf-8')

from playwright.sync_api import sync_playwright
from utils import get_supabase, log

SCRAPER_NAME = 'lawsnote_judges'
LAWSNOTE_URL = 'https://lawsnote.com'
SEARCH_URL = LAWSNOTE_URL + '/search/all/'
STATE_FILE = os.path.join(os.path.dirname(__file__), 'lawsnote_state.json')


def get_case_count(page, judge_name):
    """搜尋法官並取得裁判書數量"""
    import urllib.parse
    query = f'法官：{judge_name}'
    url = SEARCH_URL + urllib.parse.quote(query)

    try:
        page.goto(url, wait_until='domcontentloaded', timeout=20000)
        page.wait_for_timeout(3000)

        # 讀取結果數
        count_text = page.evaluate('''() => {
            const text = document.body.innerText;
            const match = text.match(/共(\\d[\\d,]*)筆結果/);
            return match ? match[1].replace(/,/g, '') : null;
        }''')

        return int(count_text) if count_text else None

    except Exception as e:
        log(f'    搜尋錯誤: {e}')
        return None


def main():
    parser = argparse.ArgumentParser(description='Lawsnote 法官案件數爬蟲')
    parser.add_argument('--limit', type=int, default=None, help='限制筆數')
    parser.add_argument('--court', type=str, default=None, help='指定法院')
    args = parser.parse_args()

    sb = get_supabase()

    # 取得所有法官（排除已有 Lawsnote 資料的）
    all_judges = []
    page_num = 0
    while True:
        q = sb.table('jy_judges').select('id, name, court_name')
        if args.court:
            q = q.eq('court_name', args.court)
        r = q.range(page_num * 1000, (page_num + 1) * 1000 - 1).execute()
        all_judges.extend(r.data)
        if len(r.data) < 1000:
            break
        page_num += 1

    # 檢查哪些已經有 Lawsnote 資料
    existing = set()
    page_num = 0
    while True:
        r = sb.table('lawsnote_judges').select('name, court_name').range(page_num * 1000, (page_num + 1) * 1000 - 1).execute()
        for j in r.data:
            existing.add(f"{j['name']}_{j['court_name']}")
        if len(r.data) < 1000:
            break
        page_num += 1

    todo = [j for j in all_judges if f"{j['name']}_{j['court_name']}" not in existing]

    if args.limit:
        todo = todo[:args.limit]

    log(f'法官總數: {len(all_judges)}, 已有 Lawsnote: {len(existing)}, 待查: {len(todo)}')

    if not todo:
        log('沒有需要查詢的法官')
        return

    # 啟動瀏覽器
    pw = sync_playwright().start()

    # 使用 persistent context 保存登入狀態
    user_data_dir = os.path.join(os.path.dirname(__file__), '.lawsnote_browser')
    context = pw.chromium.launch_persistent_context(
        user_data_dir,
        headless=False,
        slow_mo=500,
        locale='zh-TW',
    )
    page = context.pages[0] if context.pages else context.new_page()

    # 檢查是否已登入
    page.goto(LAWSNOTE_URL, wait_until='domcontentloaded', timeout=20000)
    page.wait_for_timeout(3000)

    is_logged_in = page.evaluate('''() => {
        return document.cookie.includes('authHeaders');
    }''')

    if not is_logged_in:
        log('⚠ 請在瀏覽器視窗中手動登入 Lawsnote')
        log('  登入完成後按 Enter 繼續...')
        input()

    log(f'開始查詢 {len(todo)} 位法官的案件數...')

    # 逐一查詢
    processed = 0
    batch = []

    for i, judge in enumerate(todo):
        name = judge['name']
        court = judge['court_name']

        count = get_case_count(page, name)

        if count is not None:
            log(f'  [{i+1}/{len(todo)}] {name} ({court}): {count:,} 筆')

            batch.append({
                'name': name,
                'court_name': court,
                'case_count_total': count,
                'source_url': f'{SEARCH_URL}法官：{name}',
                'scraped_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            })
        else:
            log(f'  [{i+1}/{len(todo)}] {name} ({court}): 查無結果')

        processed += 1

        # 每 50 筆寫入一次 DB
        if len(batch) >= 50:
            sb.table('lawsnote_judges').upsert(batch, on_conflict='name,court_name').execute()
            log(f'  → 寫入 {len(batch)} 筆到 DB')
            batch = []

        # 禮貌延遲
        time.sleep(2)

    # 寫入剩餘的
    if batch:
        sb.table('lawsnote_judges').upsert(batch, on_conflict='name,court_name').execute()
        log(f'  → 寫入 {len(batch)} 筆到 DB')

    log(f'\n完成！共查詢 {processed} 位法官')

    context.close()
    pw.stop()


if __name__ == '__main__':
    main()
