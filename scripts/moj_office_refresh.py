"""
MOJ 律師事務所/執業狀態刷新 — 工作異動偵測

逐位比對 DB 現值 vs MOJ API 最新值，只 PATCH 有變動的律師。
變動會由 DB trigger (moj_lawyers_log_change) 自動寫入 moj_lawyer_changes。

MOJ API 每筆約 3~5 秒，全量 13,000+ 位需 ~15 小時，超過 GitHub Actions 6 小時上限，
因此用 --shard k n 按證號 hash 分片，每天跑一片、一週完成一輪完整刷新。

用法:
  python moj_office_refresh.py               # 全量刷新（~15 小時，僅本機長跑用）
  python moj_office_refresh.py 200           # 只處理前 200 筆（測試用）
  python moj_office_refresh.py --shard 0 7   # 只處理第 0/7 分片（每日排程用）
"""
import os
import sys
import time
import zlib
import requests
from urllib.parse import quote
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

from moj_licno_scan import normalize_office, query_lic  # noqa: E402（需要先 load_dotenv）

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}


def fetch_current_rows():
    """分頁撈 DB 現有的 lic_no + office_normalized + state_desc"""
    out = []
    page = 0
    while True:
        r = requests.get(
            f'{SUPABASE_URL}/rest/v1/moj_lawyers'
            f'?select=lic_no,office_normalized,state_desc'
            f'&order=lic_no&offset={page * 1000}&limit=1000',
            headers=HEADERS_SB, verify=False, timeout=60,
        )
        r.raise_for_status()
        rows = r.json()
        if not rows:
            break
        out.extend(rows)
        if len(rows) < 1000:
            break
        page += 1
    return out


def patch_lawyer(lic_no, payload):
    """PATCH 單筆，回傳是否成功"""
    for attempt in range(3):
        try:
            r = requests.patch(
                f'{SUPABASE_URL}/rest/v1/moj_lawyers?lic_no=eq.{quote(lic_no)}',
                json=payload,
                headers={**HEADERS_SB, 'Content-Type': 'application/json',
                         'Prefer': 'return=minimal'},
                verify=False, timeout=30,
            )
            if r.status_code in (200, 204):
                return True
            print(f'  ! PATCH {lic_no} error {r.status_code}: {r.text[:200]}', flush=True)
            return False
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError):
            time.sleep(5 * (attempt + 1))
    print(f'  ! PATCH {lic_no} timeout，放棄', flush=True)
    return False


def main(limit=None, shard=None):
    print('[1/2] 載入 DB 現值...')
    rows = fetch_current_rows()
    print(f'  共 {len(rows):,} 位律師')
    if shard:
        k, n = shard
        rows = [r for r in rows if zlib.crc32(r['lic_no'].encode('utf-8')) % n == k]
        print(f'  分片 {k}/{n}: {len(rows):,} 筆')
    if limit:
        rows = rows[:limit]
        print(f'  限制處理 {limit} 筆')

    print('[2/2] 逐位比對 MOJ API...')
    t0 = time.time()
    changed = 0
    miss = 0
    fail = 0

    for i, row in enumerate(rows, 1):
        lic_no = row['lic_no']
        data = query_lic(lic_no)
        if data is None:
            # API 查無/暫時失敗都跳過，不能當成異動（可能只是網路抖動）
            miss += 1
        else:
            new_norm = normalize_office(data.get('office'))
            new_state_desc = data.get('statedesc') or None
            db_norm = row.get('office_normalized')
            db_state = row.get('state_desc')

            payload = {}
            if new_norm != db_norm:
                payload['office'] = data.get('office')
                payload['office_normalized'] = new_norm
            if new_state_desc != db_state and new_state_desc is not None:
                payload['state'] = str(data.get('state')) if data.get('state') is not None else None
                payload['state_desc'] = new_state_desc

            if payload:
                if patch_lawyer(lic_no, payload):
                    changed += 1
                    print(f'  異動: {data.get("name")} {lic_no} '
                          f'{db_norm or "-"} → {new_norm or "-"}'
                          + (f' / 狀態 {db_state} → {new_state_desc}' if 'state_desc' in payload else ''),
                          flush=True)
                    time.sleep(1)  # 寫入後讓 DB 喘口氣（Micro compute）
                else:
                    fail += 1

        if i % 200 == 0:
            elapsed = time.time() - t0
            rate = i / elapsed
            eta = (len(rows) - i) / rate / 60
            print(f'  [{i}/{len(rows)}] 異動={changed} 查無={miss} rate={rate:.1f}/s ETA={eta:.0f}min', flush=True)

        time.sleep(0.05)

    print('\n=== 完成 ===')
    print(f'比對: {len(rows):,} 位')
    print(f'異動: {changed} 筆（含事務所變更 + 執業狀態變更）')
    print(f'查無: {miss} 筆（API 無回應，未動）')
    print(f'寫入失敗: {fail} 筆')
    print(f'耗時: {(time.time() - t0) / 60:.1f} 分鐘')


if __name__ == '__main__':
    args = sys.argv[1:]
    _shard = None
    if '--shard' in args:
        i = args.index('--shard')
        _shard = (int(args[i + 1]), int(args[i + 2]))
        args = args[:i] + args[i + 3:]
    _limit = int(args[0]) if args else None
    main(limit=_limit, shard=_shard)
