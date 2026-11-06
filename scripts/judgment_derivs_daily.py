# -*- coding: utf-8 -*-
"""裁判書衍生管線的「每日自判」launcher（Windows 排程 judgment-derivs-monthly，每日 11:00 觸發）

為什麼從「每月最後一天 10:00」改成每日觸發（2026-11-06）：
  雷晚上習慣直接「電源關閉」（System log 1074；快速啟動開著，實際是休眠），WakeToRun 叫不醒；
  開機後 Task Scheduler 的 StartWhenAvailable 不一定補跑月更型 CalendarTrigger——10/20 的兩個 04:00 月更
  開機 8 分鐘後補了，10/31 本管線首跑與 11/5 的 law010 月更卻直接跳到下個月，只能人手 Start-ScheduledTask。
  每日型觸發實證會補（wbie_expert_sync 09:30 → 開機後 10:37）。所以改成每日觸發，「這個月該不該跑」由本檔自判。

判準（任一成立就秒退 0、不寫 log；全部不成立才真的跑 judgment_derivs_monthly.py）：
  目標月 T ＝ DB lawyer_month_stats 的 max(yyyymm)（與 judgment_derivs_monthly.py 同口徑）
  1. 狀態檔記錄的上次成功目標月 == T，而且（上次成功在本月，或今天 < 28 日）→ 本月已完成
     28 日起若上次成功是上個月、T 又沒前進（＝雲端月更這個月沒落地），照舊「月底跑一輪」：
     勞資名單（勞檢裁罰每日在變）、facts（標案金額）等不吃新月份的步驟也要每月刷一次
  2. 本月對同一個 T 已失敗 3 次 → 不再自動重試（第 3 次失敗的 [launcher] 行會寫明），等人看 log
  真的跑：等 DNS 就緒（開機補跑時網路還沒好）→ 取月包快取互斥鎖（law010 判決比對第一步也會
  collect 月包，兩者不可同時跑；鎖檔 .judgment_work/pipeline.lock）→ 子行程跑 judgment_derivs_monthly.py
  → 成功記 last_ok；失敗記 fails 計數，明天再試。

用法：
  pythonw judgment_derivs_daily.py                       # 排程：自判
  python  judgment_derivs_daily.py --check               # 只印判定結果（含目標月），不跑、不寫狀態
  python  judgment_derivs_daily.py --force [參數...]      # 立刻跑，參數原樣傳給 judgment_derivs_monthly.py（例：facts）
  python  judgment_derivs_daily.py --force-next [參數...] # 記旗標，下一次排程觸發強制跑一次（Start-ScheduledTask 驗收用）
  帶參數的（部分）跑不更新 last_ok／fails。
log：judgment_derivs_monthly.log（追加；本檔只在真的跑時寫 `[launcher] …` 行，最後一行固定
     `[launcher] target=… rc=… mins=…`，每日巡檢擷取）
狀態：_judgment_derivs_state.json（gitignore）
"""
import argparse
import datetime as dt
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import judgment_derivs_monthly as monthly  # noqa: E402  共用 rest_get／log／ENV_LII

STATE = os.path.join(HERE, '_judgment_derivs_state.json')
LOCK = os.path.join(HERE, '.judgment_work', 'pipeline.lock')
MONTHLY = os.path.join(HERE, 'judgment_derivs_monthly.py')
PY = sys.executable.replace('pythonw.exe', 'python.exe')
NO_WIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
FALLBACK_DAY = 28        # 月表沒前進時，這天起本月還沒跑過就跑一輪
MAX_FAILS = 3            # 同一目標月、同一個月內最多自動重試次數
LOCK_WAIT_MIN = 60       # 等 law010 釋放月包快取鎖的上限
LOCK_STALE_H = 12        # 鎖檔超過這麼久一律當殘留
RUN_TIMEOUT = 7 * 3600   # 排程 ExecutionTimeLimit 是 8 小時


def now_iso():
    return dt.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def log(msg):
    monthly.log(f'[launcher] {msg}')


def wait_network(host, tries=10, wait=30):
    for _ in range(tries):
        try:
            socket.getaddrinfo(host, 443)
            return True
        except socket.gaierror:
            time.sleep(wait)
    return False


def pid_alive(pid):
    try:
        out = subprocess.run(['tasklist', '/FI', f'PID eq {int(pid)}', '/NH', '/FO', 'CSV'],
                             capture_output=True, text=True, timeout=30, creationflags=NO_WIN).stdout
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return True  # 查不出來就當它還活著，寧可多等
    return f'"{int(pid)}"' in out


def acquire_lock(owner, wait_min):
    """.judgment_work/pipeline.lock：O_EXCL 原子建立；持有者行程已不在或鎖太舊就清掉重取。"""
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    deadline = time.time() + wait_min * 60
    announced = False
    while time.time() < deadline:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            holder = read_json(LOCK) or {}
            try:
                age_h = (time.time() - os.path.getmtime(LOCK)) / 3600
            except OSError:
                age_h = 0
            if not holder.get('pid') or age_h > LOCK_STALE_H or not pid_alive(holder['pid']):
                try:
                    os.remove(LOCK)
                except OSError:
                    pass
                time.sleep(1)
                continue
            if not announced:
                log(f'月包快取鎖被 {holder.get("owner", "?")}（pid {holder["pid"]}）佔用，最多等 {wait_min} 分鐘')
                announced = True
            time.sleep(30)
            continue
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump({'pid': os.getpid(), 'owner': owner, 'started_at': now_iso()}, f)
        return True
    return False


def release_lock():
    try:
        if (read_json(LOCK) or {}).get('pid') == os.getpid():
            os.remove(LOCK)
    except OSError:
        pass


def latest_month():
    return monthly.rest_get('lawyer_month_stats?select=yyyymm&order=yyyymm.desc&limit=1')[0]['yyyymm']


def decide(state, today, target):
    """回傳 ('run'|'skip', 原因)。"""
    this_month = today.strftime('%Y%m')
    ok = state.get('last_ok') or {}
    if ok.get('target') == target:
        ok_month = (ok.get('at') or '')[:7].replace('-', '')
        if ok_month == this_month or today.day < FALLBACK_DAY:
            return 'skip', f'目標月 {target} 已於 {(ok.get("at") or "?")[:16]} 完成'
        why = (f'目標月仍是 {target}、上次完成在 {ok_month}，今天 {today.day} 日 ≥ {FALLBACK_DAY}：'
               '雲端月更本月沒落地，照舊月底跑一輪')
    else:
        why = f'目標月 {target}（上次完成的目標月：{ok.get("target") or "無紀錄"}）'
    fails = state.get('fails') or {}
    if fails.get('key') == f'{target}@{this_month}' and fails.get('count', 0) >= MAX_FAILS:
        return 'skip', f'目標月 {target} 本月已失敗 {fails["count"]} 次，不再自動重試（看 log 的 ❌）'
    return 'run', why


def run_monthly(extra):
    env = {**os.environ, 'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'}
    t0 = time.time()
    try:
        p = subprocess.run([PY, MONTHLY] + list(extra), cwd=HERE, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                           encoding='utf-8', errors='replace', timeout=RUN_TIMEOUT, creationflags=NO_WIN)
        rc, err = p.returncode, p.stderr or ''
    except subprocess.TimeoutExpired:
        rc, err = 124, f'逾時 {RUN_TIMEOUT // 3600} 小時'
    if rc != 0:
        for ln in [x for x in err.splitlines() if x.strip()][-4:]:
            log(f'    ! {ln[:200]}')
    return rc, (time.time() - t0) / 60


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='只印判定結果，不跑、不寫狀態')
    ap.add_argument('--force', action='store_true', help='立刻強制跑')
    ap.add_argument('--force-next', action='store_true', help='下一次排程觸發強制跑一次')
    a, extra = ap.parse_known_args()   # 其餘參數原樣給 judgment_derivs_monthly.py
    state = read_json(STATE) or {}

    if a.force_next:
        state['force_next'] = {'extra': extra, 'set_at': now_iso()}
        write_json(STATE, state)
        print(f'已記旗標：下一次排程觸發強制跑 judgment_derivs_monthly.py {" ".join(extra)}'.rstrip())
        return 0

    forced, why = a.force, '強制（--force）'
    pending = state.get('force_next')
    if not forced and pending is not None and not a.check:
        forced, extra = True, list(pending.get('extra') or [])
        why = f'強制（--force-next 旗標，{(pending.get("set_at") or "?")[:16]} 設定）'
        state.pop('force_next', None)   # 旗標只用一次：失敗也不會天天強制跑
        write_json(STATE, state)

    host = urllib.parse.urlparse(monthly.ENV_LII['SUPABASE_URL']).hostname
    if not wait_network(host):
        log('❌ 網路 5 分鐘內未就緒，本次放棄（明天排程再試）')
        return 1
    try:
        target = latest_month()
    except Exception as e:
        log(f'❌ 查不到 lawyer_month_stats 最新月：{type(e).__name__}')
        return 1

    action = 'run'
    if not forced:
        action, why = decide(state, dt.date.today(), target)
    if a.check:
        print(f'{action}：{why}（目標月 {target}；狀態檔 {STATE}）')
        if pending is not None:
            print(f'  另有 force_next 旗標等下一次排程：{pending}')
        return 0
    if action == 'skip':
        return 0   # 本月已完成：不留痕

    if not acquire_lock('judgment_derivs_daily', LOCK_WAIT_MIN):
        log(f'❌ 等月包快取鎖 {LOCK_WAIT_MIN} 分鐘仍被佔用，本次放棄（明天排程再試）')
        return 1
    try:
        log(f'開跑：{why}' + (f'；參數 {" ".join(extra)}' if extra else ''))
        rc, mins = run_monthly(extra)
    finally:
        release_lock()

    if extra:   # 部分跑（例如 facts）不代表目標月完成，不動 last_ok／fails
        log(f'target={target} rc={rc} mins={mins:.1f} mode=partial:{"+".join(extra)}')
        return rc
    state = read_json(STATE) or {}   # 重讀：跑的期間可能有人下了 --force-next
    if rc == 0:
        state['last_ok'] = {'target': target, 'at': now_iso()}
        state.pop('fails', None)
        note = ''
    else:
        key = f'{target}@{dt.date.today():%Y%m}'
        fails = state.get('fails') if (state.get('fails') or {}).get('key') == key else {'key': key, 'count': 0}
        fails['count'] += 1
        state['fails'] = fails
        note = (f' fails={fails["count"]}/{MAX_FAILS}' +
                ('，本月不再自動重試，請看上面的 ❌' if fails['count'] >= MAX_FAILS else '，明天排程再試'))
    write_json(STATE, state)
    log(f'target={target} rc={rc} mins={mins:.1f}{note}')
    return rc


if __name__ == '__main__':
    sys.exit(main())
