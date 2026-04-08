"""
MOJ 律師深度補掃 v2 — 四種策略全面補足覆蓋率

策略 1: 全聯會/Lawsnote 交叉補掃（用姓名精確搜尋 MOJ）
策略 2: 更多罕見姓氏（從全聯會找出未涵蓋的姓氏）
策略 3: 大姓三字展開（雙字組合 >100 筆截斷的再展開）
策略 4: 證號範圍遍歷（直接查 /api/cert/lyinfosd/{lic_no}）

用法:
  python moj_lawyer_deep_backfill.py           # 跑全部策略
  python moj_lawyer_deep_backfill.py targeted   # 只跑策略 1
  python moj_lawyer_deep_backfill.py surnames    # 只跑策略 2
  python moj_lawyer_deep_backfill.py triple      # 只跑策略 3
  python moj_lawyer_deep_backfill.py licno       # 只跑策略 4
"""
import os
import sys
import time
import requests
import urllib3
from collections import Counter
from dotenv import load_dotenv

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
sys.stdout.reconfigure(encoding='utf-8') if sys.platform == 'win32' else None

from moj_lawyer_fullscan import (
    search_lawyers, upload_to_supabase,
    COMMON_SURNAMES, COMMON_NAME_CHARS
)

URL = os.environ.get('SUPABASE_URL', '').strip()
KEY = os.environ.get('SUPABASE_SERVICE_KEY', '').strip()
H = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}


def fetch_all(table, select, filters='', limit=1000):
    """分頁取全部資料"""
    out = []
    offset = 0
    while True:
        r = requests.get(
            f'{URL}/rest/v1/{table}?select={select}{filters}&offset={offset}&limit={limit}',
            headers=H, verify=False, timeout=30,
        )
        data = r.json() if r.status_code == 200 else []
        if isinstance(data, dict):
            print(f'  API error: {data}')
            break
        if not data:
            break
        out.extend(data)
        if len(data) < limit:
            break
        offset += limit
    return out


def strategy_targeted():
    """策略 1: 全聯會/Lawsnote 有但 MOJ 沒有的律師，用姓名精確搜尋"""
    print('\n=== 策略 1: 全聯會/Lawsnote 交叉補掃 ===')

    # 取 MOJ 所有姓名
    moj_names = set(r['name'] for r in fetch_all('moj_lawyers', 'name'))
    print(f'  MOJ 已有: {len(moj_names)} 個姓名')

    # 取全聯會姓名
    twba_names = set(r['name'] for r in fetch_all('lawyer_members', 'name', '&is_active=eq.true'))

    # 取 Lawsnote 姓名
    ln_names = set(r['name'] for r in fetch_all('lawsnote_lawyers', 'name'))

    # 差集
    missing = (twba_names | ln_names) - moj_names
    print(f'  全聯會+Lawsnote 有但 MOJ 沒有: {len(missing)} 人')

    results = {}
    fails = 0
    for i, name in enumerate(sorted(missing), 1):
        d = search_lawyers(name)
        if d is None:
            fails += 1
            continue
        lawyers = d.get('lawyers', [])
        for ly in lawyers:
            if ly['name'] == name and ly['now_lic_no'] not in results:
                results[ly['now_lic_no']] = ly
        if i % 50 == 0:
            print(f'  [{i}/{len(missing)}] 新增 {len(results)}, 失敗 {fails}')
        time.sleep(0.25)

    print(f'  完成: 查詢 {len(missing)}, 新增 {len(results)}, 失敗 {fails}')
    return results


def strategy_surnames():
    """策略 2: 從全聯會找出更多未涵蓋的罕見姓氏"""
    print('\n=== 策略 2: 罕見姓氏補掃 ===')

    covered = set(COMMON_SURNAMES)

    # 從全聯會取所有姓氏
    twba = fetch_all('lawyer_members', 'name', '&is_active=eq.true')
    all_surnames = Counter(r['name'][0] for r in twba if r.get('name'))

    # 找未涵蓋的
    missing_surnames = {s: c for s, c in all_surnames.items() if s not in covered}
    sorted_missing = sorted(missing_surnames.items(), key=lambda x: -x[1])
    print(f'  未涵蓋姓氏: {len(sorted_missing)} 個, 估計 {sum(c for _, c in sorted_missing)} 人')

    results = {}
    for s, expected in sorted_missing:
        d = search_lawyers(s)
        if d is None:
            continue
        lawyers = d.get('lawyers', [])
        for ly in lawyers:
            results[ly['now_lic_no']] = ly
        if lawyers:
            print(f'  {s}: {len(lawyers)} 筆')
        time.sleep(0.3)

    print(f'  完成: 新增 {len(results)}')
    return results


def strategy_triple():
    """策略 3: 大姓三字展開（雙字 >100 被截斷的再加第三字）"""
    print('\n=== 策略 3: 大姓三字展開 ===')

    # 先找出哪些雙字組合會 >100 截斷
    big_surnames = list('陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴徐周葉蘇呂江何羅高蕭朱')
    name_chars_short = list(dict.fromkeys('志明文國建宗信德仁義英俊豪偉正中華美秀惠芳麗玲瑜真珍雅淑'))

    results = {}
    truncated_pairs = []

    # 找截斷的雙字組合
    print(f'  檢查 {len(big_surnames)} 大姓 × {len(COMMON_NAME_CHARS)} 字...')
    for s in big_surnames:
        for c in COMMON_NAME_CHARS:
            kw = s + c
            d = search_lawyers(kw)
            if d is None:
                continue
            lawyers = d.get('lawyers', [])
            total = d.get('total', 0)
            if total == 0 and len(lawyers) == 0:
                # >100 截斷，需要三字展開
                truncated_pairs.append(kw)
            else:
                for ly in lawyers:
                    results[ly['now_lic_no']] = ly
            time.sleep(0.15)
        print(f'  {s}: 累計 {len(results)}, 截斷 {len(truncated_pairs)} 組')

    # 對截斷的雙字組合展開三字
    print(f'\n  三字展開: {len(truncated_pairs)} 組 × {len(name_chars_short)} 字')
    for i, pair in enumerate(truncated_pairs, 1):
        pair_total = 0
        for c in name_chars_short:
            kw = pair + c
            d = search_lawyers(kw)
            if d is None:
                continue
            lawyers = d.get('lawyers', [])
            for ly in lawyers:
                results[ly['now_lic_no']] = ly
                pair_total += 1
            time.sleep(0.15)
        if pair_total:
            print(f'  [{i}/{len(truncated_pairs)}] {pair}*: +{pair_total}')

    print(f'  完成: 新增 {len(results)}')
    return results


def strategy_licno():
    """策略 4: 證號範圍遍歷（查詢最近幾年的證號）"""
    print('\n=== 策略 4: 證號範圍遍歷 ===')

    # 取現有最大證號年份
    moj = fetch_all('moj_lawyers', 'lic_no')
    import re
    years = []
    for r in moj:
        m = re.match(r'^\(?(\d+)', r.get('lic_no', ''))
        if m:
            years.append(int(m.group(1)))

    if not years:
        print('  無法解析證號年份')
        return {}

    max_year = max(years)
    year_counts = Counter(years)
    print(f'  證號年份範圍: {min(years)}-{max_year}')
    print(f'  最近 3 年:')
    for y in range(max_year, max_year - 3, -1):
        print(f'    {y}: {year_counts.get(y, 0)} 筆')

    # 遍歷最近 2 年的證號（補新登錄的）
    results = {}
    for year in range(max_year - 1, max_year + 1):
        for num in range(1, 500):
            # 常見證號格式
            for prefix in [f'{year}臺檢證字第{num:05d}號', f'{year}臺檢補證字第{num:04d}號']:
                try:
                    r = requests.get(
                        f'https://lawyerbc.moj.gov.tw/api/cert/lyinfosd/{prefix}',
                        headers={'User-Agent': 'Mozilla/5.0', 'Referer': 'https://lawyerbc.moj.gov.tw/'},
                        verify=False, timeout=10,
                    )
                    if r.status_code == 200:
                        data = r.json().get('data', {})
                        if data and data.get('name'):
                            lic_no = data.get('now_lic_no') or prefix
                            if lic_no not in {r.get('lic_no') for r in moj}:
                                results[lic_no] = {
                                    'now_lic_no': lic_no,
                                    'name': data['name'],
                                    'sex': data.get('sex'),
                                    'office': data.get('office'),
                                    'guild_name': data.get('guild_name', []),
                                    'court': data.get('court', []),
                                }
                except:
                    pass
                time.sleep(0.1)
        print(f'  年份 {year}: 新增 {len(results)}')

    print(f'  完成: 新增 {len(results)}')
    return results


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'all'

    all_results = {}

    if mode in ('all', 'targeted'):
        r = strategy_targeted()
        all_results.update(r)

    if mode in ('all', 'surnames'):
        r = strategy_surnames()
        all_results.update(r)

    if mode in ('all', 'triple'):
        r = strategy_triple()
        all_results.update(r)

    if mode in ('all', 'licno'):
        r = strategy_licno()
        all_results.update(r)

    print(f'\n=== 全部完成 ===')
    print(f'總新增: {len(all_results)} 筆')

    if all_results:
        print('寫入 Supabase...')
        upload_to_supabase(list(all_results.values()))
    else:
        print('無新增資料')


if __name__ == '__main__':
    main()
