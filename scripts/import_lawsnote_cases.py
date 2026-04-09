"""
匯入 Lawsnote 法官案件數到 DB
讀取 lawsnote_batch_chrome.js 產出的 JSON 檔案

用法:
  python import_lawsnote_cases.py                    # 自動找最新的 JSON
  python import_lawsnote_cases.py path/to/file.json  # 指定檔案
"""
import sys
import json
import glob
import os

sys.stdout.reconfigure(encoding='utf-8')

from utils import get_supabase, log


def main():
    sb = get_supabase()

    # 找 JSON 檔案
    if len(sys.argv) > 1:
        filepath = sys.argv[1]
    else:
        files = glob.glob('C:/Users/admin/Downloads/lawsnote_judge_cases*.json')
        files += glob.glob('C:/Users/admin/Desktop/lawsnote_judge_cases*.json')
        if not files:
            log('找不到 JSON 檔案，請指定路徑')
            return
        filepath = max(files, key=os.path.getmtime)

    log(f'讀取: {filepath}')

    with open(filepath, 'r', encoding='utf-8') as f:
        data = json.load(f)

    log(f'共 {len(data)} 位法官')

    # 轉換格式並寫入 lawsnote_judges 表
    records = []
    for name, info in data.items():
        if isinstance(info, dict):
            count = info.get('count', 0)
            court = info.get('court', '')
        else:
            count = info
            court = ''

        records.append({
            'name': name,
            'court_name': court,
            'case_count_total': count,
            'source_url': f'https://lawsnote.com/search/all/法官：{name}',
            'scraped_at': '2026-04-09T08:00:00Z',
        })

    # 批次 upsert
    for i in range(0, len(records), 200):
        batch = records[i:i+200]
        sb.table('lawsnote_judges').upsert(batch, on_conflict='name,court_name').execute()

    log(f'寫入完成: {len(records)} 筆')

    # 驗證
    result = sb.table('lawsnote_judges').select('name', count='exact').execute()
    log(f'lawsnote_judges 總數: {result.count}')


if __name__ == '__main__':
    main()
