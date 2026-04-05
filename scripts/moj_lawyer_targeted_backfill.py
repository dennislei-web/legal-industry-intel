"""
MOJ 律師精確補掃：用姓名逐一查 MOJ API，補掃那些在 Lawsnote/全聯會
有資料但 moj_lawyers 沒抓到的律師。

資料源：lawyers_missing_from_moj view（has_twba OR has_lawsnote, NOT has_moj）

策略：
- 優先處理 has_twba AND has_lawsnote（最可能還在執業）
- 再處理 has_twba only
- 最後處理 has_lawsnote only（多為歷史律師，命中率會低）
"""
import os
import time
import requests
import urllib3
from dotenv import load_dotenv

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

from moj_lawyer_fullscan import search_lawyers, upload_to_supabase

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_SERVICE_KEY']
H = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}


def fetch_missing_names():
    """從 lawyers_missing_from_moj view 分頁取出所有缺失律師姓名，依優先順序排序。"""
    names = []
    offset = 0
    while True:
        r = requests.get(
            f'{URL}/rest/v1/lawyers_missing_from_moj'
            f'?select=name,missing_category'
            f'&offset={offset}&limit=1000',
            headers=H, verify=False, timeout=30,
        )
        data = r.json()
        if not data:
            break
        names.extend(data)
        if len(data) < 1000:
            break
        offset += 1000

    # 優先度排序
    priority_map = {'全聯會+Lawsnote': 0, '僅全聯會': 1, '僅Lawsnote': 2}
    names.sort(key=lambda x: priority_map.get(x.get('missing_category'), 99))
    return names


def backfill(delay=0.25):
    names = fetch_missing_names()
    print(f'總缺失律師: {len(names)}')
    from collections import Counter
    cat_count = Counter(n['missing_category'] for n in names)
    for k, v in cat_count.most_common():
        print(f'  {k}: {v}')

    results = {}
    hits_by_category = Counter()
    fails = 0

    print(f'\n=== 開始精確補掃 ===')
    batch_upload_size = 200

    for i, row in enumerate(names, 1):
        name = row['name']
        cat = row['missing_category']

        d = search_lawyers(name)
        if d is None:
            fails += 1
            continue

        lawyers = d.get('lawyers', [])
        for ly in lawyers:
            if ly['name'] == name and ly['now_lic_no'] not in results:
                results[ly['now_lic_no']] = ly
                hits_by_category[cat] += 1

        if i % 50 == 0:
            print(f'  [{i}/{len(names)}] 已查 {i}, 新增 {len(results)} 位 '
                  f'(失敗 {fails}) cats={dict(hits_by_category)}')

        # 分批上傳避免一次性太大
        if len(results) >= batch_upload_size:
            print(f'  ↑ 批次上傳 {len(results)} 筆...')
            upload_to_supabase(list(results.values()))
            results.clear()

        time.sleep(delay)

    # 最後剩餘
    if results:
        print(f'\n=== 最後批次上傳 {len(results)} 筆 ===')
        upload_to_supabase(list(results.values()))

    print(f'\n=== 補掃完成 ===')
    print(f'查詢總數: {len(names)}')
    print(f'失敗: {fails}')
    print(f'命中分類:')
    for k, v in hits_by_category.most_common():
        print(f'  {k}: +{v}')


if __name__ == '__main__':
    backfill()
