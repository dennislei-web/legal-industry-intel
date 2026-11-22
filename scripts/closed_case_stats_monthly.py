# -*- coding: utf-8 -*-
"""終結案件微資料統計 月更 launcher（Windows 排程 closed-case-stats-monthly：每日 12:30 觸發、腳本自判）

為什麼排本機、不排 GitHub Actions：
  .github/workflows/closed-case-stats-monthly.yml 原本每月 20 日從 GitHub runner 連 opendata.judicial.gov.tw。
  2026-11-20 排程 connect timeout（runner 海外 IP 被擋，同 judicial_official_stats 11-05／11-06 的狀況），
  11-22 在本機補跑 1 秒即通。→ 2026-11-22 搬本機，workflow 只留手動備援。

為什麼「每日觸發＋腳本自判」：雷晚上關機，月更型觸發漏跑後開機不補跑，每日型會補
（詳見 judicial_official_stats_monthly.py 開頭）。本腳本自己判斷：
    - 今天 < 20 日                                               → 略過（月包約 16 日發布，沿用原 cron 的 20 日）
    - data_sources.last_scraped_at（closed_case_stats）已在本月   → 略過
    - 否則跑 `python closed_case_stats.py auto`（只補最新缺月，約 1 分鐘）
      → rpc refresh_business_line_stats → PATCH last_scraped_at（同 workflow 三步）。
      任一步失敗就不 PATCH，明天自動再試。

log：scripts/closed_case_stats_monthly.log（追加；已 gitignore）
最後一行固定是 `[launcher] action=skip reason=…` 或 `[launcher] action=run run_rc=… refresh_ok=0|1 patch_ok=0|1`。
  action=skip 正常；action=run 要 run_rc=0 refresh_ok=1 patch_ok=1，否則異常（log 找「❌」）。

用法：
  python closed_case_stats_monthly.py           # 排程用（自判）
  python closed_case_stats_monthly.py --check   # 只印判斷結果，不跑
  python closed_case_stats_monthly.py --force   # 不管本月跑過沒都跑
"""
import datetime as dt
import os
import sys
import time
import urllib.error
import urllib.request

import judicial_official_stats_monthly as base  # 共用 log／env_of／decide／run／patch_last_scraped

HERE = os.path.dirname(os.path.abspath(__file__))
base.LOG = os.path.join(HERE, 'closed_case_stats_monthly.log')
base.SCRAPER_NAME = 'closed_case_stats'
base.RUN_FROM_DAY = 20
RUN_TIMEOUT = 30 * 60
log = base.log


def rpc(env, fn, timeout=600):
    """POST rest/v1/rpc/<fn>；5xx／連線錯誤重試 3 次"""
    url = env['SUPABASE_URL'].strip().rstrip('/') + '/rest/v1/rpc/' + fn
    key = env['SUPABASE_SERVICE_KEY'].strip()
    headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    for attempt in range(1, 4):
        try:
            req = urllib.request.Request(url, data=b'{}', method='POST', headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                log(f'✅ rpc {fn} HTTP {r.status}')
                return True
        except urllib.error.HTTPError as e:
            detail = e.read()[:200].decode('utf-8', errors='replace')
            if e.code < 500 and e.code not in (408, 409, 429):
                log(f'❌ rpc {fn} HTTP {e.code}（4xx 不重試）{detail}')
                return False
            log(f'  rpc {fn} HTTP {e.code}（第 {attempt}/3 次）{detail}')
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log(f'  rpc {fn} 連線錯誤（第 {attempt}/3 次）{type(e).__name__}')
        if attempt < 3:
            time.sleep(60)
    log(f'❌ rpc {fn} 重試 3 次仍失敗')
    return False


def main():
    args = sys.argv[1:]
    force, check_only = '--force' in args, '--check' in args
    log('=' * 60)
    log(f'終結案件微資料統計月更 launcher 開始（PY={base.PY}{"，--force" if force else ""}{"，--check" if check_only else ""}）')
    env = base.env_of(os.path.join(HERE, '.env'))
    now_local = dt.datetime.now().astimezone()

    try:
        should_run, reason = base.decide(env, now_local)
    except Exception as e:  # noqa: BLE001 — 讀不到 data_sources 就不知道該不該跑，記紅燈
        log(f'❌ 讀 data_sources 失敗：{type(e).__name__}: {str(e)[:200]}')
        log('[launcher] action=run run_rc=-1 refresh_ok=0 patch_ok=0')
        sys.exit(1)

    if force and not should_run:
        reason = f'--force（原判斷：{reason}）'
        should_run = True
    log(f'判斷：{"跑" if should_run else "略過"}——{reason}')
    if check_only:
        log(f'[launcher] action=check should_run={int(should_run)}')
        return
    if not should_run:
        log(f'[launcher] action=skip reason={reason}')
        return

    run_rc = base.run('終結案件微資料統計 auto', ['closed_case_stats.py', 'auto'], timeout=RUN_TIMEOUT)
    refresh_ok = rpc(env, 'refresh_business_line_stats') if run_rc == 0 else False
    patch_ok = base.patch_last_scraped(env) if run_rc == 0 and refresh_ok else False
    if not patch_ok:
        log('  有步驟失敗，不回寫 last_scraped_at，明天排程會再試')
    log(f'[launcher] action=run run_rc={run_rc} refresh_ok={int(refresh_ok)} patch_ok={int(patch_ok)}')
    sys.exit(0 if patch_ok else 1)


if __name__ == '__main__':
    main()
