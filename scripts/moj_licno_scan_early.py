"""
MOJ 早年段證號補掃 — 91 年以前的證號格式與主補掃不同，需獨立處理。

主補掃 (moj_licno_scan.py) 產生 `{year}臺檢證字第{num:05d}號`（無括號、補零 5 位），
但早年證號 MOJ API 只認原格式：
  - 69~89 年：`(80)臺檢證字第1679號`（含括號、不補零）
  - 90~91 年：`90臺檢證字第5022號`（無括號、不補零）
  - 55~69 年：`(56)臺證字第1044號`（更早的「臺證字」系列，獨立編號）

兩系列的編號都是跨年連續遞增，故以「全域序號」遍歷，
年份前綴從 DB 既有資料的各年 span 推定；落在年界間隙的序號嘗試相鄰兩年。

用法:
  python moj_licno_scan_early.py                 # 掃兩系列全部缺口
  python moj_licno_scan_early.py --series jian    # 只掃臺檢證字系列
  python moj_licno_scan_early.py --series zheng   # 只掃臺證字系列
  python moj_licno_scan_early.py --test-year 80   # 只掃指定年 span 內的缺口（實測用）
"""
import re
import sys
import time
import argparse
import requests
from collections import defaultdict

from moj_licno_scan import (
    query_lic, to_lawyer_record, upload_batch,
    SUPABASE_URL, HEADERS_SB,
)

if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

# 92 年檢證字從 5645 起跳，早年段掃到 5644 為止
JIAN_SCAN_MAX = 5644

PAREN_JIAN_RE = re.compile(r'^\((\d{1,3})\)[臺台]檢證字第(\d+)號$')
PLAIN_JIAN_RE = re.compile(r'^(9[01])[臺台]檢證字第(\d+)號$')
OLD_ZHENG_RE = re.compile(r'^\((\d{1,3})\)[臺台]證字第(\d+)號$')


def jian_fmt(year, num):
    if year <= 89:
        return f'({year})臺檢證字第{num}號'
    return f'{year}臺檢證字第{num}號'


def zheng_fmt(year, num):
    return f'({year})臺證字第{num}號'


SERIES = {
    'jian': {'label': '臺檢證字', 'res': [PAREN_JIAN_RE, PLAIN_JIAN_RE],
             'fmt': jian_fmt, 'scan_max': JIAN_SCAN_MAX},
    'zheng': {'label': '臺證字', 'res': [OLD_ZHENG_RE],
              'fmt': zheng_fmt, 'scan_max': None},
}


def fetch_all_licnos():
    print('[1/3] 載入現有全部證號...', flush=True)
    out = []
    start = 0
    while True:
        for attempt in range(3):
            try:
                r = requests.get(
                    f'{SUPABASE_URL}/rest/v1/moj_lawyers?select=lic_no&offset={start}&limit=1000',
                    headers=HEADERS_SB, verify=False, timeout=60)
                data = r.json()
                break
            except (requests.exceptions.Timeout, requests.exceptions.ConnectionError):
                print(f'  ! fetch timeout (attempt {attempt+1}/3)', flush=True)
                time.sleep(5 * (attempt + 1))
        else:
            raise RuntimeError('fetch_all_licnos failed')
        out += [d['lic_no'] for d in data if d.get('lic_no')]
        if len(data) < 1000:
            break
        start += 1000
    print(f'  已載入 {len(out):,} 筆', flush=True)
    return out


def build_series_map(licnos, series):
    """回傳 (year_spans, existing_serials)。
    year_spans: {year: (min, max)}；existing_serials: set of int"""
    year_nums = defaultdict(set)
    for lic in licnos:
        for rx in series['res']:
            m = rx.match(lic)
            if m:
                year_nums[int(m.group(1))].add(int(m.group(2)))
                break
    spans = {y: (min(ns), max(ns)) for y, ns in year_nums.items()}
    existing = set()
    for ns in year_nums.values():
        existing |= ns
    return spans, existing


def candidate_years(serial, spans_sorted):
    """序號落在某年 span 內 → 該年；落在年界間隙 → 相鄰兩年；
    低於全域最小 → 第一年；高於全域最大 → 最後一年。"""
    for i, (y, (mn, mx)) in enumerate(spans_sorted):
        if mn <= serial <= mx:
            return [y]
        if serial < mn:
            if i == 0:
                return [y]
            prev_y = spans_sorted[i - 1][0]
            return [prev_y, y]
    return [spans_sorted[-1][0]]


def scan_series(key, licnos, test_year=None):
    series = SERIES[key]
    spans, existing = build_series_map(licnos, series)
    if not spans:
        print(f'系列 {series["label"]}: DB 無既有資料，跳過', flush=True)
        return

    spans_sorted = sorted(spans.items())
    lo = min(mn for mn, _ in spans.values())
    hi = series['scan_max'] or (max(mx for _, mx in spans.values()) + 30)
    if test_year is not None:
        if test_year not in spans:
            print(f'系列 {series["label"]}: 年 {test_year} 無 span，跳過', flush=True)
            return
        lo, hi = spans[test_year]

    missing = [n for n in range(lo, hi + 1) if n not in existing]
    print(f'\n系列 {series["label"]}: 序號 {lo}~{hi}, 既有 {len(existing)}, 缺 {len(missing)} 筆', flush=True)
    for y, (mn, mx) in spans_sorted:
        print(f'  {y}: {mn}~{mx}', flush=True)

    found = []
    new_count = 0
    start_time = time.time()
    for i, n in enumerate(missing, 1):
        data = None
        hit_lic = None
        for y in candidate_years(n, spans_sorted):
            lic = series['fmt'](y, n)
            data = query_lic(lic)
            if data:
                hit_lic = lic
                break
        if data:
            found.append(to_lawyer_record(hit_lic, data))
            new_count += 1
            if len(found) >= 30:
                uploaded = upload_batch(found)
                lost = len(found) - len(uploaded)
                if lost:
                    print(f'  ⚠ 本批 {lost}/{len(found)} 筆 upload 失敗', flush=True)
                found = []
                time.sleep(2)
        if i % 50 == 0:
            rate = (time.time() - start_time) / i
            eta_min = rate * (len(missing) - i) / 60
            print(f'  [{series["label"]}] {i}/{len(missing)} queried, {new_count} found, '
                  f'{rate:.2f}s/筆, 剩約 {eta_min:.0f} 分', flush=True)
        time.sleep(0.05)

    if found:
        uploaded = upload_batch(found)
        lost = len(found) - len(uploaded)
        if lost:
            print(f'  ⚠ 收尾 {lost}/{len(found)} 筆 upload 失敗', flush=True)

    elapsed = (time.time() - start_time) / 60
    print(f'系列 {series["label"]} 完成: 查 {len(missing)}, 新增 {new_count}, 耗時 {elapsed:.1f} 分', flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--series', choices=['jian', 'zheng'], default=None)
    ap.add_argument('--test-year', type=int, default=None)
    args = ap.parse_args()

    licnos = fetch_all_licnos()
    print('[2/3] 分析系列缺口...', flush=True)
    keys = [args.series] if args.series else ['jian', 'zheng']
    print('[3/3] 開始掃描...', flush=True)
    for k in keys:
        scan_series(k, licnos, test_year=args.test_year)
    print('\n=== 全部完成 ===', flush=True)


if __name__ == '__main__':
    main()
