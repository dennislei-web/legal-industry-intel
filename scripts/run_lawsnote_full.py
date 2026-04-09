"""
用 Chrome MCP 自動批量查詢 Lawsnote 法官案件數
需要在 Claude Code session 中執行（使用 Chrome MCP tools）

此腳本改為直接使用 Playwright persistent context 模擬真實 Chrome，
帶入已有的 Lawsnote cookie 避免被偵測。
"""
import sys
import json
import time
import os
import urllib.parse
import re

sys.stdout.reconfigure(encoding='utf-8')

from utils import get_supabase, log

# Lawsnote 搜尋只能用真實瀏覽器
# 用 requests + cookie 嘗試 SSR
import requests
import warnings
warnings.filterwarnings('ignore')


def main():
    sb = get_supabase()

    # 讀取批次
    with open('lawsnote_batches.json', 'r', encoding='utf-8') as f:
        batches = json.load(f)

    # 已完成的（讀取 DB）
    existing = set()
    page = 0
    while True:
        r = sb.table('lawsnote_judges').select('name').range(page*1000, (page+1)*1000-1).execute()
        for j in r.data:
            existing.add(j['name'])
        if len(r.data) < 1000:
            break
        page += 1

    log(f'已有 Lawsnote 資料: {len(existing)} 位')

    # 過濾已完成的批次
    remaining_batches = []
    for batch in batches:
        names = [n for n in batch['names'] if n not in existing]
        if names:
            remaining_batches.append(batch)

    log(f'剩餘批次: {len(remaining_batches)}')

    if not remaining_batches:
        log('全部完成！')
        return

    # 嘗試用 Playwright persistent context（帶 Lawsnote cookie）
    from playwright.sync_api import sync_playwright

    pw = sync_playwright().start()

    # 使用持久化 context 保持登入
    user_data = os.path.join(os.path.dirname(__file__), '.lawsnote_chrome')
    context = pw.chromium.launch_persistent_context(
        user_data,
        headless=False,
        slow_mo=200,
        locale='zh-TW',
        args=['--disable-blink-features=AutomationControlled'],
    )

    # 開 4 個 tab
    pages = [context.pages[0]] if context.pages else [context.new_page()]
    while len(pages) < 4:
        pages.append(context.new_page())

    # 檢查登入
    pages[0].goto('https://lawsnote.com', wait_until='domcontentloaded', timeout=20000)
    pages[0].wait_for_timeout(3000)

    is_logged_in = pages[0].evaluate("() => document.cookie.includes('authHeaders')")
    if not is_logged_in:
        log('⚠ 需要登入 Lawsnote！請在彈出的瀏覽器視窗中登入...')
        for _ in range(60):
            time.sleep(2)
            is_logged_in = pages[0].evaluate("() => document.cookie.includes('authHeaders')")
            if is_logged_in:
                log('✓ 登入成功')
                break
        if not is_logged_in:
            log('✗ 登入超時')
            context.close()
            pw.stop()
            return

    log(f'🚀 開始查詢 {len(remaining_batches)} 批...')

    all_results = {}
    batch_records = []

    for batch_idx, batch in enumerate(remaining_batches):
        names = batch['names']
        urls = batch['urls']

        # 跳過已完成的
        names_to_do = [(n, u) for n, u in zip(names, urls) if n not in existing]
        if not names_to_do:
            continue

        # 平行導航
        for i, (name, url_encoded) in enumerate(names_to_do[:4]):
            if i < len(pages):
                try:
                    pages[i].goto(
                        f'https://lawsnote.com/search/all/{url_encoded}',
                        wait_until='domcontentloaded',
                        timeout=15000
                    )
                except:
                    pass

        # 等待載入
        time.sleep(4)

        # 讀取結果
        for i, (name, _) in enumerate(names_to_do[:4]):
            if i < len(pages):
                try:
                    count_str = pages[i].evaluate(
                        "() => { const m = document.body.innerText.match(/共(\\d[\\d,]*)筆結果/); return m ? m[1].replace(/,/g,'') : '0'; }"
                    )
                    count = int(count_str)
                    all_results[name] = count
                    existing.add(name)

                    # 查 court_name
                    r = sb.table('jy_judges').select('court_name').eq('name', name).limit(1).execute()
                    court = r.data[0]['court_name'] if r.data else ''

                    batch_records.append({
                        'name': name,
                        'court_name': court,
                        'case_count_total': count,
                        'source_url': f'https://lawsnote.com/search/all/法官：{name}',
                        'scraped_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                    })
                except Exception as e:
                    log(f'  {name}: ERR {e}')

        # 每 50 筆寫入一次 DB
        if len(batch_records) >= 50:
            sb.table('lawsnote_judges').upsert(batch_records, on_conflict='name,court_name').execute()
            log(f'  [{batch_idx+1}/{len(remaining_batches)}] DB 寫入 {len(batch_records)} 筆 (total: {len(all_results)})')
            batch_records = []

        # 進度
        if (batch_idx + 1) % 25 == 0:
            log(f'  進度: {batch_idx+1}/{len(remaining_batches)} ({len(all_results)} 位完成)')

        time.sleep(1)

    # 寫入剩餘的
    if batch_records:
        sb.table('lawsnote_judges').upsert(batch_records, on_conflict='name,court_name').execute()
        log(f'  最終寫入 {len(batch_records)} 筆')

    log(f'\n✅ 完成！共查詢 {len(all_results)} 位法官')

    result = sb.table('lawsnote_judges').select('name', count='exact').execute()
    log(f'lawsnote_judges 總數: {result.count}')

    context.close()
    pw.stop()


if __name__ == '__main__':
    main()
