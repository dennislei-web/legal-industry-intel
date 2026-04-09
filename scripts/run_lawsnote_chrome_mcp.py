"""
用 Claude in Chrome MCP 批量查詢 Lawsnote 法官案件數
直接用已登入的 Chrome 瀏覽器，4 tab 平行查詢

需要在 Claude Code 環境中執行（有 MCP Chrome tools）
"""
import sys
import json
import time
import urllib.parse
import subprocess

sys.stdout.reconfigure(encoding='utf-8')

from utils import get_supabase, log


def chrome_navigate(tab_id, url):
    """透過 MCP 導航 Chrome tab"""
    # 這個腳本無法直接呼叫 MCP tools
    # 改用 requests 模擬 — 但這不可行
    pass


def main():
    sb = get_supabase()

    # 讀取所有法官
    with open('judge_names.json', 'r', encoding='utf-8') as f:
        all_judges = json.load(f)

    # 已完成的
    existing = set()
    page = 0
    while True:
        r = sb.table('lawsnote_judges').select('name').range(page*1000, (page+1)*1000-1).execute()
        for j in r.data:
            existing.add(j['name'])
        if len(r.data) < 1000:
            break
        page += 1

    remaining = [j for j in all_judges if j['name'] not in existing]
    log(f'已完成: {len(existing)}, 剩餘: {len(remaining)}')

    # 產生批次 URL
    batches = []
    for i in range(0, len(remaining), 4):
        batch = remaining[i:i+4]
        batches.append([{
            'name': j['name'],
            'court': j['court_name'],
            'url': f'https://lawsnote.com/search/all/{urllib.parse.quote("法官：" + j["name"])}'
        } for j in batch])

    log(f'批次: {len(batches)}')

    # 輸出批次到 JSON 供 Chrome 腳本使用
    with open('lawsnote_remaining_batches.json', 'w', encoding='utf-8') as f:
        json.dump(batches, f, ensure_ascii=False)

    log('已輸出 lawsnote_remaining_batches.json')
    log('請在 Lawsnote Chrome tab 中執行 lawsnote_batch_chrome.js 腳本')


if __name__ == '__main__':
    main()
