# -*- coding: utf-8 -*-
"""司法院官方案件統計 月更 launcher（Windows 排程 judicial-official-stats-monthly：每日 10:30 觸發、腳本自判）

為什麼排本機、不排 GitHub Actions（2026-11-05、11-06 實測）：
  .github/workflows/judicial-official-stats.yml 每月 5 日從 GitHub runner 下載 opendata.judicial.gov.tw 的
  18.7 MB 月檔（datasetId 43994）再全量 upsert court_case_stats（約 43 萬列）。
  11-05 排程、11-06 手動重跑連兩天 connect timeout（runner 海外 IP 被擋）；本機打同一個 IP 0.07 秒即通。
  → 搬本機跑，workflow 只留手動備援（本機漏跑時 Run workflow 補一次，全量 upsert 冪等）。

為什麼「每日觸發＋腳本自判」而不是「每月 5 日」：
  雷晚上直接關機，WakeToRun 叫不醒；月更型 CalendarTrigger 漏跑後開機不會補跑，每日型會補
  （10/31 derivs、11/5 law010 月更皆因此漏跑）。所以排程每天 10:30 觸發（StartWhenAvailable：開機晚了會補），
  本腳本自己判斷：
    - 今天 < 5 日                                          → 略過（沿用原 cron 的每月 5 日；來源月初才換檔）
    - data_sources.last_scraped_at（judicial_official_stats）已在本月（台灣時間） → 略過（本月跑過了）
    - 否則跑 `python judicial_official_stats.py run`（download → parse → upsert，約 10 分鐘），
      成功才 PATCH last_scraped_at（同 workflow 最後一步）；失敗不 PATCH，明天會自動再試到成功或月底。

log：scripts/judicial_official_stats_monthly.log（追加；已 gitignore）
最後一行固定是 `[launcher] action=skip reason=…` 或 `[launcher] action=run run_rc=… patch_ok=0|1`，每日巡檢擷取：
  action=skip 是正常；action=run 且（run_rc≠0 或 patch_ok≠1）才是異常（log 找「❌」）。

用法：
  python judicial_official_stats_monthly.py           # 排程用（自判）
  python judicial_official_stats_monthly.py --check   # 只印判斷結果，不跑
  python judicial_official_stats_monthly.py --force   # 手動：不管本月跑過沒都跑（仍會 PATCH）
"""
import datetime as dt
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, 'judicial_official_stats_monthly.log')
PY = sys.executable.replace('pythonw.exe', 'python.exe')
NO_WIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
SCRAPER_NAME = 'judicial_official_stats'
RUN_FROM_DAY = 5          # 每月幾號起才跑（原 GitHub cron：每月 5 日台灣 04:00）
RUN_TIMEOUT = 90 * 60     # 下載 ~18 MB＋解析 600 MB XML＋43 萬列 upsert，正常約 10 分鐘
if hasattr(sys.stdout, 'reconfigure'):  # 排程用 pythonw 跑時沒有 stdout
    sys.stdout.reconfigure(errors='replace')


def log(msg):
    line = f'[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}'
    try:
        print(line, flush=True)
    except (AttributeError, OSError):  # pythonw：sys.stdout 是 None
        pass
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


def env_of(path):
    """讀 .env；沒有檔案時退回環境變數（子程序的 load_dotenv 也是 override=False，兩者一致）"""
    env = {k: os.environ[k] for k in ('SUPABASE_URL', 'SUPABASE_SERVICE_KEY') if k in os.environ}
    if not os.path.exists(path):
        return env
    with open(path, encoding='utf-8-sig') as f:
        for ln in f:
            if '=' in ln and not ln.strip().startswith('#'):
                k, v = ln.strip().split('=', 1)
                env[k.strip()] = v.strip().strip('"')
    return env


def _request(env, method, query, body=None, prefer=None, timeout=60):
    url = env['SUPABASE_URL'].strip().rstrip('/') + '/rest/v1/data_sources' + query
    key = env['SUPABASE_SERVICE_KEY'].strip()
    headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    if prefer:
        headers['Prefer'] = prefer
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode('utf-8', errors='replace')


def get_last_scraped(env):
    """data_sources.last_scraped_at → aware datetime（UTC）或 None；讀不到就拋錯（不知道有沒有跑過，寧可不跑）"""
    _, body = _request(env, 'GET', f'?scraper_name=eq.{SCRAPER_NAME}&select=last_scraped_at')
    rows = json.loads(body)
    if not rows:
        raise RuntimeError(f'data_sources 沒有 scraper_name={SCRAPER_NAME} 這列')
    raw = rows[0].get('last_scraped_at')
    if not raw:
        return None
    return dt.datetime.fromisoformat(raw.replace('Z', '+00:00'))


def decide(env, now_local):
    """回傳 (要不要跑, 原因)"""
    if now_local.day < RUN_FROM_DAY:
        return False, f'今天 {now_local:%m/%d} 還沒到每月 {RUN_FROM_DAY} 日'
    last = get_last_scraped(env)
    if last is None:
        return True, 'last_scraped_at 為空（從未跑過）'
    last_local = last.astimezone(now_local.tzinfo)
    if (last_local.year, last_local.month) == (now_local.year, now_local.month):
        return False, f'本月已跑（last_scraped_at={last_local:%Y-%m-%d %H:%M} 台灣時間）'
    return True, f'本月未跑（上次 {last_local:%Y-%m-%d %H:%M}）'


def run(desc, args, timeout):
    """子程序完整輸出都追加進 log"""
    log(f'▶ {desc}：{" ".join(args)}')
    env = {**os.environ, 'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'}
    t0 = time.time()
    try:
        p = subprocess.run([PY] + args, cwd=HERE, env=env, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=timeout, creationflags=NO_WIN)
    except subprocess.TimeoutExpired:
        log(f'❌ {desc} 逾時 {timeout // 60} 分鐘')
        return 124
    with open(LOG, 'a', encoding='utf-8') as f:
        for ln in (p.stdout or '').splitlines():
            if ln.strip():
                f.write(f'    {ln}\n')
        for ln in [x for x in (p.stderr or '').splitlines() if x.strip() and 'warn' not in x.lower()][-8:]:
            f.write(f'    ! {ln[:300]}\n')
    mins = (time.time() - t0) / 60
    log(f'{"✅" if p.returncode == 0 else "❌"} {desc} rc={p.returncode}（{mins:.1f} 分）')
    return p.returncode


def patch_last_scraped(env):
    """回寫 data_sources.last_scraped_at（同 workflow 最後一步）：4xx 不重試、5xx／連線錯誤重試 3 次"""
    body = {'last_scraped_at': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
    for attempt in range(1, 4):
        try:
            status, _ = _request(env, 'PATCH', f'?scraper_name=eq.{SCRAPER_NAME}', body=body,
                                 prefer='return=minimal')
            log(f'✅ PATCH data_sources.last_scraped_at HTTP {status}')
            return True
        except urllib.error.HTTPError as e:
            detail = e.read()[:200].decode('utf-8', errors='replace')
            if e.code < 500 and e.code not in (408, 409, 429):
                log(f'❌ PATCH last_scraped_at HTTP {e.code}（4xx 不重試，表／欄位／權限要修）{detail}')
                return False
            log(f'  PATCH last_scraped_at HTTP {e.code}（第 {attempt}/3 次）{detail}')
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log(f'  PATCH last_scraped_at 連線錯誤（第 {attempt}/3 次）{type(e).__name__}')
        if attempt < 3:
            time.sleep(60)
    log('❌ PATCH last_scraped_at 重試 3 次仍失敗（明天會整條重跑）')
    return False


def main():
    args = sys.argv[1:]
    force, check_only = '--force' in args, '--check' in args
    log('=' * 60)
    log(f'司法院官方案件統計月更 launcher 開始（PY={PY}{"，--force" if force else ""}{"，--check" if check_only else ""}）')
    env = env_of(os.path.join(HERE, '.env'))
    now_local = dt.datetime.now().astimezone()

    try:
        should_run, reason = decide(env, now_local)
    except Exception as e:  # noqa: BLE001 — 讀不到 data_sources 就不知道該不該跑，記紅燈
        log(f'❌ 讀 data_sources 失敗：{type(e).__name__}: {str(e)[:200]}')
        log('[launcher] action=run run_rc=-1 patch_ok=0')
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

    run_rc = run('司法院官方案件統計 run', ['judicial_official_stats.py', 'run'], timeout=RUN_TIMEOUT)
    patch_ok = patch_last_scraped(env) if run_rc == 0 else False
    if run_rc != 0:
        log('  run 失敗，不回寫 last_scraped_at，明天排程會再試')
    log(f'[launcher] action=run run_rc={run_rc} patch_ok={int(patch_ok)}')
    sys.exit(0 if run_rc == 0 and patch_ok else 1)


if __name__ == '__main__':
    main()
