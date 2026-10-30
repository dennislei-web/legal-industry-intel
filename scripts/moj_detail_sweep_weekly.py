# -*- coding: utf-8 -*-
"""MOJ 律師詳細頁每週掃描 launcher（Windows 排程 moj-detail-sweep-weekly，每週五 09:30）

為什麼排本機、不排 GitHub Actions（2026-10-30 實測）：
  GitHub runner（海外 IP）打 lawyerbc.moj.gov.tw 新站，75 頁有 26 頁重試兩次仍失敗——
  間歇回 200＋805 bytes「Error」頁，或整個 runner 連線被切（一片 15/15 ConnectionError），
  而且常是同一批頁面；同一批 75 頁從本機（台灣 IP）跑兩輪都是 75/75。
  失敗頁只記「無法斷定」不寫入，資料不會錯，但每週約 1/3 律師沒被檢查到 → 改本機跑。
  .github/workflows/moj-detail-sweep.yml 留著只供手動觸發。

步驟（任一步失敗→記錄後繼續，最後 exit 1；log 看「❌」）：
  1. moj_harvest_ingest.py   先吃掉這週同仁收成的新雜湊（新律師核對詳細頁才插入）
  2. moj_detail_sweep.py     全量逐頁比對（≤1 req/s，約 13,600 頁 ≈ 4 小時）
  3. refresh RPC              refresh_firm_stats_cache／refresh_lawyer_stats／refresh_firm_map_cache
                              （同 .github/scripts/refresh-rpcs.sh：5xx／逾時重試 3 次、4xx 不重試）

log：scripts/moj_detail_sweep_weekly.log（追加；含異動摘要的律師姓名 → 已 gitignore，不可 commit）
最後一行固定是 `[launcher] ingest_rc=… sweep_rc=… refresh_ok=N/3`，每日巡檢擷取。

用法：
  python moj_detail_sweep_weekly.py           # 正式跑
  python moj_detail_sweep_weekly.py --limit 20  # 測試：sweep 只跑前 20 位
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
LOG = os.path.join(HERE, 'moj_detail_sweep_weekly.log')
PY = sys.executable.replace('pythonw.exe', 'python.exe')
NO_WIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
REFRESH_RPCS = ('refresh_firm_stats_cache', 'refresh_lawyer_stats', 'refresh_firm_map_cache')
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
    env = {}
    with open(path, encoding='utf-8-sig') as f:
        for ln in f:
            if '=' in ln and not ln.strip().startswith('#'):
                k, v = ln.strip().split('=', 1)
                env[k.strip()] = v.strip().strip('"')
    return env


def run(desc, args, timeout):
    """子程序完整輸出都追加進 log（sweep 的異動摘要 BEGIN/END 要給巡檢擷取）"""
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


def call_rpc(name, env):
    url = env['SUPABASE_URL'].strip().rstrip('/') + f'/rest/v1/rpc/{name}'
    key = env['SUPABASE_SERVICE_KEY'].strip()
    for attempt in range(1, 4):
        req = urllib.request.Request(url, data=b'{}', method='POST', headers={
            'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                log(f'✅ {name} HTTP {r.status}')
                return True
        except urllib.error.HTTPError as e:
            body = e.read()[:200].decode('utf-8', errors='replace')
            if e.code < 500 and e.code not in (408, 409, 429):
                log(f'❌ {name} HTTP {e.code}（4xx 不重試）{body}')
                return False
            log(f'  {name} HTTP {e.code}（第 {attempt}/3 次）{body}')
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log(f'  {name} 連線錯誤（第 {attempt}/3 次）{type(e).__name__}')
        if attempt < 3:
            time.sleep(60)
    log(f'❌ {name} 重試 3 次仍失敗')
    return False


def main():
    args = sys.argv[1:]
    limit = args[args.index('--limit') + 1] if '--limit' in args else None
    log('=' * 60)
    log(f'MOJ 詳細頁每週掃描開始（PY={PY}）')
    env = env_of(os.path.join(HERE, '.env'))

    ingest_rc = run('收成 ingest', ['moj_harvest_ingest.py'], timeout=2 * 3600)
    sweep_args = ['moj_detail_sweep.py'] + (['--limit', limit] if limit else [])
    sweep_rc = run('詳細頁 sweep', sweep_args, timeout=8 * 3600)
    refresh_ok = sum(call_rpc(n, env) for n in REFRESH_RPCS)

    log(f'[launcher] ingest_rc={ingest_rc} sweep_rc={sweep_rc} refresh_ok={refresh_ok}/{len(REFRESH_RPCS)}')
    sys.exit(0 if ingest_rc == 0 and sweep_rc == 0 and refresh_ok == len(REFRESH_RPCS) else 1)


if __name__ == '__main__':
    main()
