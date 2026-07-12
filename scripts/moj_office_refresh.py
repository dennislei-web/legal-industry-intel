"""
MOJ 律師事務所/執業狀態刷新 — 工作異動偵測

逐位比對 DB 現值 vs MOJ API 最新值，只 PATCH 有變動的律師。
變動會由 DB trigger (moj_lawyers_log_change) 自動寫入 moj_lawyer_changes。

MOJ API 每筆約 3~5 秒，全量 13,000+ 位需 ~15 小時，超過 GitHub Actions 6 小時上限，
因此用 --shard k n 按證號 hash 分片，每天跑一片、一週完成一輪完整刷新。

除名偵測（mig 079）：
  MOJ「確定查無」（HTTP 200 空 data / 404，非網路抖動）＝律師已從名冊移除。
  單輪查無不可直接判除名（防 API 偶發空回應誤標）→ 兩段確認：
    第一輪 gone → 記 dereg_candidate_at（候選，不動 state）
    下一輪（>= 3 天後）仍 gone → deregistered_at=now() + state_desc=「名冊查無（推定除名）」
      （trigger moj_lawyers_log_change 自動記 state_change 進異動追蹤）
    之後任何一輪又查得到（重新登錄）→ 自動清除兩欄、還原 API 現值（自癒）
  連線失敗（timeout/5xx 耗盡）維持原行為：跳過不動。

用法:
  python moj_office_refresh.py               # 全量刷新（~15 小時，僅本機長跑用）
  python moj_office_refresh.py 200           # 只處理前 200 筆（測試用）
  python moj_office_refresh.py --shard 0 7   # 只處理第 0/7 分片（每日排程用）
  python moj_office_refresh.py --check 114臺檢證字第18741號       # 單筆查狀態（唯讀）
  python moj_office_refresh.py --mark-dereg 114臺檢證字第18741號  # 人工標記除名（間隔三次確認）
"""
import os
import sys
import time
import zlib
import requests
from datetime import datetime, timezone, timedelta
from urllib.parse import quote
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

from moj_licno_scan import normalize_office, query_lic_status  # noqa: E402（需要先 load_dotenv）

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

DEREG_STATE = '名冊查無（推定除名）'
DEREG_CONFIRM_MIN_DAYS = 3  # 候選→確認的最小間隔（分片週期 7 天，防同輪重跑秒確認）


def fetch_current_rows():
    """分頁撈 DB 現有的 lic_no + office_normalized + state_desc + 除名旗標"""
    out = []
    page = 0
    while True:
        r = requests.get(
            f'{SUPABASE_URL}/rest/v1/moj_lawyers'
            f'?select=lic_no,name,office_normalized,state_desc,dereg_candidate_at,deregistered_at'
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
    flaky = 0
    fail = 0
    dereg_cand = 0   # 本輪新記除名候選
    dereg_conf = 0   # 本輪確認除名
    dereg_hold = 0   # 已確認除名、本輪仍查無（維持現狀）

    for i, row in enumerate(rows, 1):
        lic_no = row['lic_no']
        name = row.get('name') or lic_no
        data, st = query_lic_status(lic_no)
        if data is None and st == 'flaky':
            # 連線問題重試耗盡，無法斷定 → 跳過不動（不能當成異動）
            flaky += 1
        elif data is None:  # st == 'gone'：MOJ 確定查無（200 空 data / 404）
            if row.get('deregistered_at'):
                dereg_hold += 1  # 已標除名，維持現狀
            elif row.get('dereg_candidate_at'):
                # 上一輪已記候選：兩次獨立週期都 gone 才確認除名
                first = datetime.fromisoformat(row['dereg_candidate_at'].replace('Z', '+00:00'))
                if datetime.now(timezone.utc) - first >= timedelta(days=DEREG_CONFIRM_MIN_DAYS):
                    payload = {'deregistered_at': datetime.now(timezone.utc).isoformat(),
                               'state_desc': DEREG_STATE}
                    if patch_lawyer(lic_no, payload):
                        dereg_conf += 1
                        print(f'  除名確認: {name} {lic_no}（候選於 {row["dereg_candidate_at"][:10]}，'
                              f'兩輪皆查無）', flush=True)
                        time.sleep(1)
                    else:
                        fail += 1
                # 未滿最小間隔（同輪重跑等）→ 不動，等下一輪
            else:
                payload = {'dereg_candidate_at': datetime.now(timezone.utc).isoformat()}
                if patch_lawyer(lic_no, payload):
                    dereg_cand += 1
                    print(f'  除名候選: {name} {lic_no}（名冊查無，待下輪 >= '
                          f'{DEREG_CONFIRM_MIN_DAYS} 天後複驗）', flush=True)
                else:
                    fail += 1
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
            if row.get('deregistered_at') or row.get('dereg_candidate_at'):
                # 名冊又查得到（重新登錄/先前誤判）→ 解除除名旗標；
                # state_desc 由上面比對還原成 API 現值，trigger 自動記回異動追蹤
                payload['dereg_candidate_at'] = None
                payload['deregistered_at'] = None
                print(f'  除名解除: {name} {lic_no} 名冊查得到，清除候選/除名旗標', flush=True)

            if payload:
                if patch_lawyer(lic_no, payload):
                    changed += 1
                    if 'office_normalized' in payload or 'state_desc' in payload:
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
            print(f'  [{i}/{len(rows)}] 異動={changed} 連線失敗={flaky} '
                  f'除名候選={dereg_cand} 除名確認={dereg_conf} rate={rate:.1f}/s ETA={eta:.0f}min', flush=True)

        time.sleep(0.05)

    print('\n=== 完成 ===')
    print(f'比對: {len(rows):,} 位')
    print(f'異動: {changed} 筆（含事務所變更 + 執業狀態變更 + 除名解除）')
    print(f'除名候選: {dereg_cand} 筆（首輪查無，待複驗）/ 除名確認: {dereg_conf} 筆'
          f' / 已除名維持: {dereg_hold} 筆')
    print(f'連線失敗: {flaky} 筆（無法斷定，未動）')
    print(f'寫入失敗: {fail} 筆')
    print(f'耗時: {(time.time() - t0) / 60:.1f} 分鐘')


def fetch_one(lic_no):
    r = requests.get(
        f'{SUPABASE_URL}/rest/v1/moj_lawyers'
        f'?select=lic_no,name,office_normalized,state_desc,dereg_candidate_at,deregistered_at'
        f'&lic_no=eq.{quote(lic_no)}',
        headers=HEADERS_SB, verify=False, timeout=60,
    )
    r.raise_for_status()
    rows = r.json()
    return rows[0] if rows else None


def check_one(lic_no):
    """單筆查狀態（唯讀）：印 DB 現值 + MOJ API 即時判定"""
    row = fetch_one(lic_no)
    if not row:
        print(f'DB 查無 lic_no={lic_no}')
        return
    print(f'DB 現值: {row["name"]} / {row.get("office_normalized") or "-"} / '
          f'狀態={row.get("state_desc") or "-"} / 候選={row.get("dereg_candidate_at") or "-"} / '
          f'除名={row.get("deregistered_at") or "-"}')
    data, st = query_lic_status(lic_no)
    if st == 'ok':
        print(f'MOJ API: ok（在冊）→ {normalize_office(data.get("office")) or "-"} / '
              f'狀態={data.get("statedesc") or "-"}')
    elif st == 'gone':
        print('MOJ API: gone（確定查無：200 空 data / 404，已排除網路抖動）')
    else:
        print('MOJ API: flaky（連線失敗重試耗盡，無法斷定）')


def mark_dereg(lic_no, confirms=3, gap_sec=20):
    """人工標記除名：間隔 confirms 次獨立確認全部 gone 才寫入。
    任何一次 ok/flaky 都中止不寫。日常排程的兩輪週期複驗仍照常運作，
    若誤標，下輪查得到會自動解除（自癒）。"""
    row = fetch_one(lic_no)
    if not row:
        print(f'DB 查無 lic_no={lic_no}，結束')
        return
    if row.get('deregistered_at'):
        print(f'{row["name"]} {lic_no} 已標記除名（{row["deregistered_at"]}），不重複')
        return
    print(f'目標: {row["name"]} / {row.get("office_normalized") or "-"} / '
          f'狀態={row.get("state_desc") or "-"}')
    for k in range(confirms):
        data, st = query_lic_status(lic_no)
        print(f'  確認 {k + 1}/{confirms}: {st}', flush=True)
        if st == 'ok':
            print(f'  → MOJ 查得到（{normalize_office(data.get("office")) or "-"}），仍在名冊，中止不標記')
            return
        if st == 'flaky':
            print('  → 連線不穩無法斷定，中止不標記，請稍後再試')
            return
        if k < confirms - 1:
            time.sleep(gap_sec)
    payload = {'deregistered_at': datetime.now(timezone.utc).isoformat(),
               'state_desc': DEREG_STATE,
               'dereg_candidate_at': None}
    if patch_lawyer(lic_no, payload):
        print(f'已標記除名: {row["name"]} {lic_no} 狀態 {row.get("state_desc")} → {DEREG_STATE}'
              f'（trigger 已記入 moj_lawyer_changes）')
        print('提醒：可呼叫 refresh_firm_stats_cache RPC 更新事務所人數快取')
    else:
        print('寫入失敗')


if __name__ == '__main__':
    args = sys.argv[1:]
    if '--check' in args:
        check_one(args[args.index('--check') + 1])
        sys.exit(0)
    if '--mark-dereg' in args:
        mark_dereg(args[args.index('--mark-dereg') + 1])
        sys.exit(0)
    _shard = None
    if '--shard' in args:
        i = args.index('--shard')
        _shard = (int(args[i + 1]), int(args[i + 2]))
        args = args[:i] + args[i + 3:]
    _limit = int(args[0]) if args else None
    main(limit=_limit, shard=_shard)
