"""
MOJ 律師深度補掃 v3 — 高效率四策略補足覆蓋率

策略 1 targeted: 全聯會/Lawsnote 有但 MOJ 沒有的，用姓名搜 MOJ
策略 2 surnames: 從全聯會找未涵蓋的罕見姓氏
策略 3 triple:  從 DB 反推哪些大姓雙字組合可能被截斷，只展開那些
策略 4 licno:   遍歷最近年份的證號

用法:
  python moj_lawyer_deep_backfill.py all
  python moj_lawyer_deep_backfill.py targeted
  python moj_lawyer_deep_backfill.py surnames
  python moj_lawyer_deep_backfill.py triple
  python moj_lawyer_deep_backfill.py licno
"""
import os
import sys
import time
import re
import requests
import urllib3
from collections import Counter
from dotenv import load_dotenv

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8')

from moj_lawyer_fullscan import (
    search_lawyers, upload_to_supabase,
    COMMON_SURNAMES, COMMON_NAME_CHARS
)

URL = os.environ.get('SUPABASE_URL', '').strip()
KEY = os.environ.get('SUPABASE_SERVICE_KEY', '').strip()
H = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}


def fetch_all(table, select, filters='', limit=1000):
    out = []
    offset = 0
    while True:
        r = requests.get(
            f'{URL}/rest/v1/{table}?select={select}{filters}&offset={offset}&limit={limit}',
            headers=H, verify=False, timeout=30,
        )
        data = r.json() if r.status_code == 200 else []
        if isinstance(data, dict) or not data:
            break
        out.extend(data)
        if len(data) < limit:
            break
        offset += limit
    return out


def batch_upload(results):
    """分批上傳，每 500 筆"""
    if not results:
        return
    records = list(results.values())
    print(f'  上傳 {len(records)} 筆...')
    try:
        upload_to_supabase(records)
    except Exception as e:
        print(f'  ! 上傳失敗: {e}')


def strategy_targeted():
    """策略 1: 全聯會/Lawsnote 有但 MOJ 沒有的律師"""
    print('\n=== 策略 1: 全聯會/Lawsnote 交叉補掃 ===')

    moj_names = set(r['name'] for r in fetch_all('moj_lawyers', 'name'))
    twba_names = set(r['name'] for r in fetch_all('lawyer_members', 'name', '&is_active=eq.true'))
    ln_names = set(r['name'] for r in fetch_all('lawsnote_lawyers', 'name'))

    missing = (twba_names | ln_names) - moj_names
    print(f'  缺失: {len(missing)} 人')

    results = {}
    for i, name in enumerate(sorted(missing), 1):
        d = search_lawyers(name)
        if d:
            for ly in d.get('lawyers', []):
                if ly['name'] == name:
                    results[ly['now_lic_no']] = ly
        if i % 100 == 0:
            print(f'  [{i}/{len(missing)}] 新增 {len(results)}')
            batch_upload(results)
            results.clear()
        time.sleep(0.2)

    batch_upload(results)
    print(f'  完成')
    return len(results)


def strategy_surnames():
    """策略 2: 罕見姓氏"""
    print('\n=== 策略 2: 罕見姓氏補掃 ===')

    covered = set(COMMON_SURNAMES)
    twba = fetch_all('lawyer_members', 'name', '&is_active=eq.true')
    all_surnames = Counter(r['name'][0] for r in twba if r.get('name'))

    missing = {s: c for s, c in all_surnames.items() if s not in covered}
    print(f'  未涵蓋: {len(missing)} 個姓氏')

    results = {}
    for s, _ in sorted(missing.items(), key=lambda x: -x[1]):
        d = search_lawyers(s)
        if d:
            for ly in d.get('lawyers', []):
                results[ly['now_lic_no']] = ly
        time.sleep(0.25)

    batch_upload(results)
    print(f'  完成: {len(results)} 筆')
    return len(results)


def strategy_triple():
    """策略 3: 大姓三字展開（智慧版 — 從 DB 反推截斷的組合）"""
    print('\n=== 策略 3: 大姓三字展開（智慧版）===')

    # 從 DB 取所有 MOJ 律師的姓名，統計每個雙字前綴的數量
    all_lawyers = fetch_all('moj_lawyers', 'name')
    prefix_counts = Counter()
    for r in all_lawyers:
        name = r.get('name', '')
        if len(name) >= 2:
            prefix_counts[name[:2]] += 1

    # 大姓：前 30 個姓氏
    big_surnames = set('陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴徐周葉蘇呂江何羅高蕭朱')

    # 找出大姓中，某些雙字前綴恰好有 90-100 筆的（可能被截斷）
    # 以及完全沒有出現的常見組合（可能就是被截斷 >100 而回傳 0）
    suspicious = []
    name_chars_top = list(dict.fromkeys('志明文國建宗信德仁義英俊豪偉正中華美秀惠芳麗玲瑜真珍雅淑嘉宏弘振誠彥展福育成傑銘峰'))

    for s in big_surnames:
        for c in name_chars_top:
            prefix = s + c
            count = prefix_counts.get(prefix, 0)
            # 接近 100 或完全沒有（被截斷回傳 0）都可疑
            if count >= 85 or count == 0:
                suspicious.append((prefix, count))

    print(f'  可疑雙字組合: {len(suspicious)} 個（count>=85 或 count=0）')

    # 只對可疑的做三字展開
    third_chars = list(dict.fromkeys('志明文國建宗信德仁義英俊豪偉正中華美秀惠芳麗玲瑜真珍雅淑'))
    results = {}
    total_new = 0

    for i, (prefix, db_count) in enumerate(suspicious, 1):
        pair_new = 0
        for c3 in third_chars:
            kw = prefix + c3
            d = search_lawyers(kw)
            if d:
                for ly in d.get('lawyers', []):
                    if ly['now_lic_no'] not in results:
                        results[ly['now_lic_no']] = ly
                        pair_new += 1
            time.sleep(0.12)

        if pair_new:
            total_new += pair_new
            print(f'  [{i}/{len(suspicious)}] {prefix} (DB:{db_count}): +{pair_new}')

        # 每 20 組上傳一次
        if i % 20 == 0 and results:
            batch_upload(results)
            results.clear()

    batch_upload(results)
    print(f'  完成: 新增 {total_new}')
    return total_new


def strategy_licno():
    """策略 4: 證號範圍遍歷"""
    print('\n=== 策略 4: 證號範圍遍歷 ===')

    # 取現有所有證號
    existing_lics = set()
    for r in fetch_all('moj_lawyers', 'lic_no'):
        existing_lics.add(r.get('lic_no', ''))

    # 找最新年份
    max_year = 0
    for lic in existing_lics:
        m = re.match(r'^\(?(\d+)', lic)
        if m:
            y = int(m.group(1))
            if y > max_year:
                max_year = y

    print(f'  最新證號年份: {max_year}')
    print(f'  現有證號: {len(existing_lics)} 筆')

    results = {}
    # 遍歷最近 2 年
    for year in range(max_year - 1, max_year + 1):
        year_found = 0
        consecutive_miss = 0
        for num in range(1, 800):
            lic_no = f'{year}臺檢證字第{num:05d}號'
            if lic_no in existing_lics:
                consecutive_miss = 0
                continue

            try:
                r = requests.get(
                    f'https://lawyerbc.moj.gov.tw/api/cert/lyinfosd/{lic_no}',
                    headers={'User-Agent': 'Mozilla/5.0', 'Referer': 'https://lawyerbc.moj.gov.tw/'},
                    verify=False, timeout=10,
                )
                if r.status_code == 200:
                    data = r.json().get('data', {})
                    if data and data.get('name'):
                        results[lic_no] = {
                            'now_lic_no': lic_no,
                            'name': data['name'],
                            'sex': data.get('sex'),
                            'office': data.get('office'),
                            'guild_name': data.get('guild_name', []),
                            'court': data.get('court', []),
                        }
                        year_found += 1
                        consecutive_miss = 0
                    else:
                        consecutive_miss += 1
                else:
                    consecutive_miss += 1
            except:
                consecutive_miss += 1

            # 連續 50 個找不到就跳到下一年
            if consecutive_miss >= 50:
                print(f'  年份 {year}: 到 {num} 號連續 50 miss，跳過')
                break
            time.sleep(0.08)

        print(f'  年份 {year}: 新增 {year_found}')

    batch_upload(results)
    print(f'  完成: {len(results)} 筆')
    return len(results)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'all'
    total = 0

    if mode in ('all', 'targeted'):
        total += strategy_targeted()

    if mode in ('all', 'surnames'):
        total += strategy_surnames()

    if mode in ('all', 'triple'):
        total += strategy_triple()

    if mode in ('all', 'licno'):
        total += strategy_licno()

    print(f'\n=== 全部完成: 約新增 {total} 筆 ===')


if __name__ == '__main__':
    main()
