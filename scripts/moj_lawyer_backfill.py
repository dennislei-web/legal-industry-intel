"""
MOJ 律師補掃：從 lawyers_combined 找出 moj_lawyers 缺失的姓氏，逐一補掃。

使用方式:
  python moj_lawyer_backfill.py
"""
import os
import requests
import urllib3
from collections import Counter
from dotenv import load_dotenv

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

from moj_lawyer_fullscan import search_lawyers, upload_to_supabase, COMMON_NAME_CHARS

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_SERVICE_KEY']
H = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}


def fetch_all(table, select, limit=1000):
    out = []
    page = 0
    while True:
        r = requests.get(
            f'{URL}/rest/v1/{table}?select={select}&offset={page*limit}&limit={limit}',
            headers=H, verify=False, timeout=30,
        )
        data = r.json()
        if not data:
            break
        out.extend(data)
        if len(data) < limit:
            break
        page += 1
    return out


def find_gap_surnames():
    lc = fetch_all('lawyers_combined', 'name')
    moj = fetch_all('moj_lawyers', 'name')
    lc_sur = Counter(n['name'][0] for n in lc if n.get('name'))
    moj_sur = Counter(n['name'][0] for n in moj if n.get('name'))

    # 完全缺失的
    missing = [s for s in lc_sur if s not in moj_sur]
    # 數量偏低的（MOJ < lawyers_combined 的 50%）
    weak = [s for s in moj_sur
            if moj_sur[s] < max(2, lc_sur.get(s, 0) * 0.5) and lc_sur.get(s, 0) > moj_sur[s]]
    gap = sorted(set(missing) | set(weak), key=lambda x: -lc_sur.get(x, 0))

    print(f'lawyers_combined: {len(lc)} 筆 / {len(lc_sur)} 姓氏')
    print(f'moj_lawyers: {len(moj)} 筆 / {len(moj_sur)} 姓氏')
    print(f'需補掃: {len(gap)} 個姓氏')
    return gap, lc_sur


def backfill(delay=0.3):
    gap, lc_sur = find_gap_surnames()
    results = {}
    truncated = []

    # Pass 1: 單字查詢
    print(f'\n=== Pass 1: 單字 ({len(gap)} 個) ===')
    for i, s in enumerate(gap, 1):
        d = search_lawyers(s)
        if d is None:
            continue
        lawyers = d.get('lawyers', [])
        total = d.get('total', 0)
        if total == 0 and not lawyers:
            truncated.append(s)
            print(f'  [{i}/{len(gap)}] {s}: 0 (可能 >100, 細分)')
        else:
            for ly in lawyers:
                results[ly['now_lic_no']] = ly
            print(f'  [{i}/{len(gap)}] {s}: {total} -> {len(results)}')

    # Pass 2: 雙字細分（僅限被截斷的）
    if truncated:
        print(f'\n=== Pass 2: 雙字 ({len(truncated)} 姓 × {len(COMMON_NAME_CHARS)} 字) ===')
        for si, s in enumerate(truncated, 1):
            subtotal = 0
            for c in COMMON_NAME_CHARS:
                d = search_lawyers(s + c)
                if d is None:
                    continue
                for ly in d.get('lawyers', []):
                    results[ly['now_lic_no']] = ly
                    subtotal += 1
            print(f'  [{si}/{len(truncated)}] {s}*: +{subtotal} -> {len(results)}')

    print(f'\n=== 補掃完成 ===')
    print(f'新增律師: {len(results)} 位')

    if results:
        print('\n=== 寫入 Supabase ===')
        upload_to_supabase(list(results.values()))
    return results


if __name__ == '__main__':
    backfill()
