"""
MOJ 律師詳細頁每週掃描（2026-10-29 官網改版後取代 moj_office_refresh.py）

對 moj_lawyers 裡已有 page_hash 的律師逐頁 GET /lawyer/{hash}（公開頁、免驗證碼），
比對事務所／公會／執業狀態／懲戒記錄，只 PATCH 有變動者；事務所與執業狀態異動由 DB trigger
moj_lawyers_log_change 自動寫入 moj_lawyer_changes（異動追蹤頁照常吃得到）。
MOJ 事務所／公會資料每週四批次更新 → 每週五本機排程跑（moj_detail_sweep_weekly.py；GitHub runner 連官網不穩，見該檔）。

判定：
  200 → 比對、page_checked_at=now（批次寫）；先前有除名候選／除名旗標者自動解除（頁面查得到＝仍在名冊）
  404（0 byte）→ page_hash_missing_at=now，進人工複查佇列（moj_query_plan.py --incremental 會列出）。
        **不當成除名**：雜湊是否會隨資料更新而重發尚未確認（docs/moj-site-redesign-2026-10.md）
  連線錯誤／逾時／5xx／版面解析失敗 → 跳過不動
  頁面上的證號與 DB 對不起來 → 不寫入、記「雜湊不符」（多半是 ingest 對錯人，要人工看）

防呆（中止＝本輪未刷完、exit 1，已寫入的不回滾）：
  - 404 比例 > 5%（看過 ≥100 頁後）→ 雜湊可能整批失效，停止、不再寫 page_hash_missing_at
  - 連續 20 頁連線失敗 → 判定官網不通

用法:
  python moj_detail_sweep.py                    # 全部有雜湊的律師
  python moj_detail_sweep.py --shard 0 5        # 第 0/5 分片（按證號 crc32）
  python moj_detail_sweep.py --limit 20         # 只跑前 20 位（測試）
  python moj_detail_sweep.py --dry-run          # 只比對、不寫 DB
  python moj_detail_sweep.py --hash 0x…         # 抓單頁印解析結果（email／電話／地址只標有無）
  python moj_detail_sweep.py --file page.html   # 解析本機存檔（離線測 parser）
"""
import os
import sys
import time
import zlib
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')
else:
    sys.stdout.reconfigure(line_buffering=True)

import moj_detail_page as mdp  # noqa: E402
from moj_licno_norm import lic_triple, num_key  # noqa: E402
from moj_licno_scan import guild_to_region, normalize_office  # noqa: E402（沿用舊管線口徑）
from moj_office_refresh import patch_lawyer  # noqa: E402（變動由 trigger 記入 moj_lawyer_changes）

DEREG_STATE = '名冊查無（推定除名）'
MISSING_RATIO_MAX = 0.05
MISSING_RATIO_MIN_SEEN = 100
MAX_CONSECUTIVE_FLAKY = 20
CHECKED_BATCH = 50
SUMMARY_ORDER = ['事務所異動', '執業狀態', '除名解除', '懲戒記錄', '詳細頁 404', '雜湊不符']


def _env():
    url = os.environ['SUPABASE_URL'].strip()
    key = os.environ['SUPABASE_SERVICE_KEY'].strip()
    return url, {'apikey': key, 'Authorization': f'Bearer {key}'}


def fetch_rows():
    url, h = _env()
    cols = ('lic_no,name,office,office_normalized,state_desc,guild_names,main_region,discipline,'
            'email,tel,address,moj_ut_date,dereg_candidate_at,deregistered_at,page_hash,page_hash_missing_at')
    out, offset = [], 0
    while True:
        r = requests.get(f'{url}/rest/v1/moj_lawyers?select={cols}&page_hash=not.is.null'
                         f'&order=lic_no&offset={offset}&limit=1000', headers=h, timeout=60)
        r.raise_for_status()
        rows = r.json()
        out.extend(rows)
        if len(rows) < 1000:
            return out
        offset += 1000


def sb_patch(filter_qs, payload):
    url, h = _env()
    for attempt in range(3):
        try:
            r = requests.patch(f'{url}/rest/v1/moj_lawyers?{filter_qs}', json=payload,
                               headers={**h, 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                               timeout=30)
            if r.status_code in (200, 204):
                return True
            print(f'  ! PATCH error {r.status_code}: {r.text[:200]}', flush=True)
            return False
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError):
            time.sleep(5 * (attempt + 1))
    print('  ! PATCH timeout，放棄', flush=True)
    return False


def mark_checked(hashes, now_iso):
    """page_checked_at 批次寫（以 page_hash 篩，雜湊是 ASCII、URL 短）"""
    ok = True
    for i in range(0, len(hashes), CHECKED_BATCH):
        part = hashes[i:i + CHECKED_BATCH]
        ok &= sb_patch(f'page_hash=in.({",".join(part)})', {'page_checked_at': now_iso})
    return ok


def same_lic(db_lic, page_lic):
    a, b = lic_triple(db_lic), lic_triple(page_lic)
    if not a or not b:
        return False
    if a == b:
        return True
    ka, kb = num_key(a), num_key(b)
    return ka is not None and ka == kb


def norm_disc(v):
    return mdp.clean_text(v)


def diff_row(row, f):
    """回傳 (payload, events)；payload 空＝無變動"""
    payload, events = {}, []
    lic, name = row['lic_no'], row.get('name') or row['lic_no']

    office_raw = mdp.page_office(f)
    new_norm = normalize_office(office_raw)
    db_norm = row.get('office_normalized')
    if new_norm != db_norm:
        payload['office'] = office_raw
        payload['office_normalized'] = new_norm
        events.append(('事務所異動', f'{name}（{lic}）{db_norm or "未登錄"} → {new_norm or "未登錄"}'))

    new_state = mdp.clean_text(f.get('state_desc'))
    db_state = row.get('state_desc')
    if new_state and new_state != db_state:
        payload['state_desc'] = new_state
        if db_state != DEREG_STATE:  # 除名旗標解除另列，避免一筆記兩次
            events.append(('執業狀態', f'{name}（{lic}）{db_state or "-"} → {new_state}'))

    if row.get('deregistered_at') or row.get('dereg_candidate_at'):
        payload['dereg_candidate_at'] = None
        payload['deregistered_at'] = None
        if row.get('deregistered_at'):
            events.append(('除名解除', f'{name}（{lic}）詳細頁查得到，清除推定除名'))

    guilds = mdp.page_guilds(f)
    if guilds and guilds != (row.get('guild_names') or None):
        payload['guild_names'] = guilds
        payload['main_region'] = guild_to_region(guilds) or row.get('main_region')

    # 懲戒：舊表存的是 HTML 連結、新站是純文字 → 只把「有／無」翻轉算異動，格式換新靜默更新
    new_disc, old_disc = norm_disc(f.get('discipline')), row.get('discipline')
    if (old_disc is None) != (new_disc is None):
        payload['discipline'] = new_disc
        events.append(('懲戒記錄', f'{name}（{lic}）' + ('新增懲戒記錄' if new_disc else '懲戒記錄移除')))
    elif new_disc and new_disc != old_disc:
        payload['discipline'] = new_disc
        if not (old_disc or '').lstrip().startswith('<'):
            events.append(('懲戒記錄', f'{name}（{lic}）懲戒記錄內容變更'))

    # 聯絡欄位：轉所或地址變了才同步（口徑同 moj_office_refresh；頁面空值時保留舊值）
    addr = mdp.clean_text(f.get('address'))
    if addr and ('office_normalized' in payload or addr != row.get('address')):
        payload['address'] = addr
        for k in ('email', 'tel'):
            v = mdp.clean_text(f.get(k))
            if v:
                payload[k] = v
        payload['detail_fetched_at'] = datetime.now(timezone.utc).isoformat()

    ut = mdp.page_date(f, 'ut_date')
    if ut and ut != row.get('moj_ut_date'):
        payload['moj_ut_date'] = ut
    if row.get('page_hash_missing_at'):
        payload['page_hash_missing_at'] = None
    return payload, events


def print_change_summary(events, total, flaky, fail, missing, aborted, shard, cand_cleared=0):
    """格式同 moj_office_refresh.print_change_summary（BEGIN/END 標記供每日巡檢擷取）"""
    shard_txt = f'分片 {shard[0]}/{shard[1]}' if shard else '全量'
    head = (f'{shard_txt}：比對 {total:,} 位' + ('（中途中止，未刷完）' if aborted else '')
            + f'，連線失敗 {flaky} 筆、寫入失敗 {fail} 筆、詳細頁 404 {missing} 筆'
            + (f'、清除除名候選 {cand_cleared} 筆' if cand_cleared else ''))
    lines = [head]
    if not [e for e in events if e[0] != '詳細頁 404']:
        lines.append('本輪無任何異動。')
    for cat in SUMMARY_ORDER:
        items = [d for c, d in events if c == cat]
        if items:
            lines.append(f'【{cat}】{len(items)} 筆')
            lines.extend(f'- {d}' for d in items)
    print('\n=== 異動摘要 BEGIN ===')
    for ln in lines:
        print(ln)
    print('=== 異動摘要 END ===', flush=True)
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        try:
            with open(path, 'a', encoding='utf-8') as fh:
                md = ['## MOJ 律師異動摘要（詳細頁掃描）', '']
                for ln in lines:
                    md.extend([ln] if ln.startswith('- ') else ['', ln, ''])
                fh.write('\n'.join(md) + '\n')
        except OSError as e:
            print(f'  ! 寫入 GITHUB_STEP_SUMMARY 失敗: {type(e).__name__}', flush=True)


def main(limit=None, shard=None, dry_run=False):
    print('[1/2] 載入有 page_hash 的律師...')
    rows = fetch_rows()
    print(f'  共 {len(rows):,} 位')
    if shard:
        k, n = shard
        rows = [r for r in rows if zlib.crc32(r['lic_no'].encode('utf-8')) % n == k]
        print(f'  分片 {k}/{n}: {len(rows):,} 位')
    if limit:
        rows = rows[:limit]
        print(f'  限制處理 {limit} 位')
    if dry_run:
        print('  --dry-run：只比對、不寫 DB')

    print('[2/2] 逐頁比對（≤1 req/s）...')
    sess, throttle = mdp.new_session(), mdp.Throttle(1.0)
    now_iso = datetime.now(timezone.utc).isoformat()
    t0 = time.time()
    events, checked = [], []
    changed = contact_upd = cand_cleared = flaky = fail = missing = mismatch = consec_flaky = retried = 0
    aborted, abort_reason = False, ''

    for i, row in enumerate(rows, 1):
        st, f, note, tries = mdp.fetch_detail_retry(row['page_hash'], sess, throttle)
        retried += 1 if tries else 0
        consec_flaky = consec_flaky + 1 if st == 'flaky' else 0
        if st == 'flaky':
            flaky += 1
            if flaky <= 10:
                print(f'  ? {row["lic_no"]} 無法斷定（{note}）', flush=True)
            if consec_flaky >= MAX_CONSECUTIVE_FLAKY:
                aborted, abort_reason = True, f'連續 {MAX_CONSECUTIVE_FLAKY} 頁連線失敗'
                print(f'  !! {abort_reason}（第 {i}/{len(rows)} 位），判定官網不通，中止', flush=True)
                break
        elif st == 'missing':
            missing += 1
            if missing > max(MISSING_RATIO_MIN_SEEN, i) * MISSING_RATIO_MAX:
                aborted, abort_reason = True, f'詳細頁 404 比例異常 {missing}/{i}'
                print(f'  !! {abort_reason}：雜湊可能整批失效，中止、本頁起不再寫入', flush=True)
                break
            events.append(('詳細頁 404', f'{row["lic_no"]}（進人工複查，非除名）'))
            if not row.get('page_hash_missing_at') and not dry_run:
                if not patch_lawyer(row['lic_no'], {'page_hash_missing_at': now_iso}):
                    fail += 1
        elif not same_lic(row['lic_no'], f.get('lic_no')):
            mismatch += 1
            events.append(('雜湊不符', f'{row["lic_no"]} 的雜湊指向另一張證書，未寫入，請人工確認'))
        else:
            payload, evs = diff_row(row, f)
            # 異動＝事務所／狀態／懲戒，或解除「已確認」除名；只清除「候選」（10/29 事故誤標居多）另計
            significant = bool({'office_normalized', 'state_desc', 'discipline'} & payload.keys()) \
                or bool(row.get('deregistered_at'))
            cand_only = bool(row.get('dereg_candidate_at')) and not significant
            if payload and (dry_run or patch_lawyer(row['lic_no'], payload)):
                events.extend(evs)
                if significant:
                    changed += 1
                    if not dry_run:
                        time.sleep(0.5)  # 寫入後讓 DB 喘口氣（Micro compute）
                elif cand_only:
                    cand_cleared += 1
                else:
                    contact_upd += 1
            elif payload:
                fail += 1
            checked.append(row['page_hash'])

        if len(checked) >= 200 and not dry_run:
            fail += 0 if mark_checked(checked, now_iso) else 1
            checked = []
        if i % 200 == 0:
            rate = i / (time.time() - t0)
            print(f'  [{i}/{len(rows)}] 異動={changed} 404={missing} 不符={mismatch} 連線失敗={flaky} '
                  f'rate={rate:.2f}/s ETA={(len(rows) - i) / rate / 60:.0f}min', flush=True)

    if checked and not dry_run:
        fail += 0 if mark_checked(checked, now_iso) else 1

    print('\n=== 完成 ===')
    print(f'比對: {len(rows):,} 位（實際走訪 {i if rows else 0:,}）')
    print(f'異動: {changed} 筆（事務所／執業狀態／除名解除／懲戒）')
    print(f'清除除名候選: {cand_cleared} 筆（詳細頁查得到＝仍在名冊，非異動）')
    print(f'地址／公會／更新日期同步: {contact_upd} 筆（非異動）')
    print(f'詳細頁 404: {missing} 筆（記 page_hash_missing_at，非除名）')
    print(f'雜湊不符: {mismatch} 筆')
    print(f'連線失敗: {flaky} 筆（重試 {len(mdp.RETRY_DELAYS)} 次仍失敗，無法斷定，未動）；曾重試後成功或失敗: {retried} 筆')
    print(f'寫入失敗: {fail} 筆')
    print(f'耗時: {(time.time() - t0) / 60:.1f} 分鐘')
    print_change_summary(events, len(rows), flaky, fail, missing, aborted, shard, cand_cleared)
    if aborted:
        print(f'結果: 中止（{abort_reason}）')
        sys.exit(1)


def show_one(fields, label):
    print(f'== {label} ==')
    for k, v in mdp.redacted(fields).items():
        print(f'  {k}: {v}')
    print(f'  → office_normalized: {normalize_office(mdp.page_office(fields))}')
    print(f'  → guild_names: {mdp.page_guilds(fields)}')
    print(f'  → birth_year: {mdp.page_birth_year(fields)} / ut_date: {mdp.page_date(fields, "ut_date")}')
    print(f'  → lic triple: {lic_triple(fields.get("lic_no"))}')


if __name__ == '__main__':
    args = sys.argv[1:]
    if '--file' in args:
        with open(args[args.index('--file') + 1], encoding='utf-8', errors='ignore') as fh:
            show_one(mdp.parse_detail(fh.read()), '本機檔案')
        sys.exit(0)
    if '--hash' in args:
        st, f, note = mdp.fetch_detail(args[args.index('--hash') + 1])
        print(f'status={st} {note}')
        if f:
            show_one(f, '線上頁面')
        sys.exit(0 if st == 'ok' else 1)
    _shard = None
    if '--shard' in args:
        j = args.index('--shard')
        _shard = (int(args[j + 1]), int(args[j + 2]))
    _limit = int(args[args.index('--limit') + 1]) if '--limit' in args else None
    main(limit=_limit, shard=_shard, dry_run='--dry-run' in args)
