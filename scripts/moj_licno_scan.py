"""
MOJ 律師證號遍歷補掃 — 最高效的補掃策略

律師證號是連續遞增的（民國年 + 編號）。
從每年的編號 1 遍歷到當年最大編號，補齊缺漏。

API: /api/cert/lyinfosd/{lic_no} - 不需要 CAPTCHA，可以大量呼叫

用法:
  python moj_licno_scan.py            # 補掃缺漏
  python moj_licno_scan.py 108 109    # 只掃指定年份
"""
import os
import re
import sys
import time
import json
import requests
import urllib3
from collections import defaultdict
from dotenv import load_dotenv

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
MOJ_BASE = 'https://lawyerbc.moj.gov.tw/api'

HEADERS_MOJ = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Referer': 'https://lawyerbc.moj.gov.tw/',
    'Origin': 'https://lawyerbc.moj.gov.tw',
}
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

sess = requests.Session()
sess.verify = False
sess.headers.update(HEADERS_MOJ)


def fetch_existing_lics():
    """從 DB 取所有已有的證號"""
    print('[1/3] 載入現有證號...')
    out = set()
    start = 0
    while True:
        r = requests.get(
            f'{SUPABASE_URL}/rest/v1/moj_lawyers?select=lic_no&offset={start}&limit=1000',
            headers=HEADERS_SB, verify=False, timeout=30,
        )
        data = r.json()
        if not data:
            break
        out.update(d['lic_no'] for d in data if d.get('lic_no'))
        if len(data) < 1000:
            break
        start += 1000
    print(f'  已有 {len(out):,} 筆')
    return out


def analyze_year_ranges(existing_lics):
    """分析每年的編號範圍，只補 min~max 之間缺的編號"""
    year_nums = defaultdict(set)
    for lic in existing_lics:
        m = re.match(r'^(\d+)臺檢證字第(\d+)號', lic)
        if m:
            year = int(m.group(1))
            num = int(m.group(2))
            year_nums[year].add(num)

    # 每年的最小/最大編號
    year_range = {}
    for y, nums in year_nums.items():
        if nums:
            year_range[y] = (min(nums), max(nums))
    return year_nums, year_range


def query_lic(lic_no):
    """查詢單一證號的詳細資料"""
    try:
        r = sess.get(f'{MOJ_BASE}/cert/lyinfosd/{lic_no}', timeout=10)
        if r.status_code == 200:
            resp = r.json()
            data = resp.get('data')
            # data 可能是 list 或 dict
            if isinstance(data, list):
                if data and data[0].get('name'):
                    return data[0]
            elif isinstance(data, dict) and data.get('name'):
                return data
    except Exception:
        pass
    return None


def to_lawyer_record(lic_no, data):
    """轉換為 moj_lawyers 表格式"""
    # guild_name 可能是字串或 list
    guilds = data.get('guild_name')
    if isinstance(guilds, str):
        guilds = [g.strip() for g in guilds.split(',') if g.strip()] or None
    elif isinstance(guilds, list):
        guilds = [g for g in guilds if g] or None

    court = data.get('court')
    if isinstance(court, str):
        court = [court] if court else None
    elif isinstance(court, list):
        court = [c for c in court if c] or None

    return {
        'lic_no': lic_no,
        'name': data.get('name', ''),
        'sex': data.get('sex'),
        'office': data.get('office'),
        'office_normalized': normalize_office(data.get('office')),
        'guild_names': guilds,
        'court': court,
        'birth_year': data.get('birthsday') if isinstance(data.get('birthsday'), int) else None,
        'state': data.get('state'),
        'state_desc': data.get('statedesc'),
        'email': data.get('email') or None,
        'tel': data.get('tel') or None,
        'address': data.get('addr') or None,
        'discipline': data.get('discipline') or None,
        'raw_data': data,
    }


def normalize_office(office):
    if not office:
        return None
    s = office.strip().replace('\u3000', ' ')
    s = re.sub(r'\s+', '', s)
    if s in ('律師未提供', '未提供', '無', '未登記', '-', ''):
        return None
    return s


def upload_batch(records):
    if not records:
        return
    r = requests.post(
        f'{SUPABASE_URL}/rest/v1/moj_lawyers?on_conflict=lic_no',
        json=records,
        headers={**HEADERS_SB, 'Content-Type': 'application/json',
                 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        verify=False, timeout=60,
    )
    if r.status_code not in (200, 201, 204):
        print(f'  ! upload error {r.status_code}: {r.text[:200]}')
        return False
    return True


def scan_year(year, min_num, max_num, existing_set, extra_buffer=30):
    """只掃描 min~max 之間缺的編號，加上 max 後面 buffer 個"""
    found = []
    queried = 0
    new_count = 0
    scan_from = min_num
    scan_to = max_num + extra_buffer

    # 計算這年要查多少（已有的跳過）
    missing_nums = []
    for num in range(scan_from, scan_to + 1):
        lic_no = f'{year}臺檢證字第{num:05d}號'
        if lic_no not in existing_set:
            missing_nums.append(num)

    print(f'年份 {year}: 範圍 {scan_from}~{scan_to}, 缺 {len(missing_nums)} 筆, 開始查詢...', flush=True)

    for i, num in enumerate(missing_nums, 1):
        lic_no = f'{year}臺檢證字第{num:05d}號'
        data = query_lic(lic_no)
        queried += 1

        if data:
            found.append(to_lawyer_record(lic_no, data))
            new_count += 1
            # 每 10 筆立刻上傳
            if len(found) >= 10:
                if upload_batch(found):
                    existing_set.update(f['lic_no'] for f in found)
                found = []

        # 每 50 筆印一次進度
        if i % 50 == 0:
            print(f'  [{year}] {i}/{len(missing_nums)} queried, {new_count} found', flush=True)

        time.sleep(0.05)

    # 剩餘上傳
    if found:
        upload_batch(found)
        existing_set.update(f['lic_no'] for f in found)

    print(f'年份 {year} 完成: 查 {queried}, 新增 {new_count}', flush=True)


def main():
    existing = fetch_existing_lics()

    print('\n[2/3] 分析各年度編號範圍...')
    year_nums, year_range = analyze_year_ranges(existing)
    for y in sorted(year_range.keys()):
        mn, mx = year_range[y]
        print(f'  {y}: {mn}~{mx} ({len(year_nums[y])} 筆)', flush=True)

    # 如果有指定年份
    if len(sys.argv) > 1:
        target_years = [int(y) for y in sys.argv[1:]]
        print(f'  指定年份: {target_years}')
    else:
        # 預設掃 92 到最新年份
        target_years = sorted([y for y in year_range.keys() if y >= 92])
        print(f'  自動掃描年份: {target_years[0]} ~ {target_years[-1]}')

    print('\n[3/3] 開始掃描...')
    start_time = time.time()
    total_before = len(existing)

    for year in target_years:
        if year not in year_range:
            continue
        mn, mx = year_range[year]
        scan_year(year, mn, mx, existing, extra_buffer=30)
        elapsed = (time.time() - start_time) / 60
        added = len(existing) - total_before
        print(f'  累計新增 {added} 筆, 已跑 {elapsed:.1f} 分鐘')

    total_after = len(existing)
    print(f'\n=== 完成 ===')
    print(f'之前: {total_before:,} 筆')
    print(f'之後: {total_after:,} 筆')
    print(f'新增: {total_after - total_before:,} 筆')
    print(f'總耗時: {(time.time() - start_time) / 60:.1f} 分鐘')


if __name__ == '__main__':
    main()
