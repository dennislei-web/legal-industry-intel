# -*- coding: utf-8 -*-
"""appeal／achievement 月更 .bat 的「每日自判」launcher
（Windows 排程 appeal-stats-monthly 每日 11:45 → `appeal`；achievement-stats-monthly 每日 12:00 → `achievement`）

為什麼從「每月 20 日 04:00／04:40」改成每日觸發（2026-11-06）：
  雷晚上習慣直接「電源關閉」（System log 1074；快速啟動開著，實際是休眠），WakeToRun 叫不醒；開機後 Task Scheduler 的
  StartWhenAvailable 補跑月更型 CalendarTrigger 不穩定（10/20 的這兩支開機 8 分鐘後有補，10/31 derivs、11/5 law010 沒補），
  每日型觸發每次都補。所以改每日觸發，「這個月該不該跑」由本檔自判。兩支 .bat 本身不動（achievement 鏈「任一 python 步驟
  失敗即中止、不部署半套資料」的語意原樣保留），本檔只管判斷、先後順序、互斥與重試。

判準（任一成立就秒退 0、不寫 log；全部不成立才呼叫 .bat）：
  完成標記＝各自 log 裡最後一次「成功」的日期（人手直接跑 .bat 也會被認得）：
    appeal_monthly.log      每段以 `===== <日期> =====` 起頭；段內出現 `月增量完成：` 或 `無新月份可補`（appeal_stats.py auto 正常收尾）才算成功
    achievement_monthly.log `===== done <日期> =====`（鏈走完才寫；`===== aborted` 不算）
  1. 今天 < 20 日 → 未到月更日
  2. 最後一次成功在本月且 ≥ 20 日 → 本月已完成
  3. 本月已失敗 3 次 → 不再自動重試（第 3 次失敗的 [launcher] 行會寫明），等人看 log
  真的跑：
  a. achievement 先等 appeal 今天跑完（appeal 正在跑／有 force_next 旗標／本月該跑但今天還沒試 → 每 30 秒看一次，最多等 60 分鐘），
     照舊 appeal 先、achievement 後；開機補跑時兩個排程同時起跑也能排好順序。`--force` 不等。
  b. 等 DNS 就緒（開機補跑時網路還沒好）
  c. 取月包快取互斥鎖 pipeline.lock（appeal_stats／achievement_stats 都會下載、解壓月包到 .judgment_work，
     與 judgment-derivs-monthly、law010 判決比對不可同時跑；見 pipeline_lock.py）
  d. `cmd /c <原 .bat>`，.bat 的輸出照舊由它自己追加進各自 log；逾時 taskkill 整棵行程樹
  e. rc≠0 → fails 計數 +1，明天排程再試（網路／鎖等不到不計次）

用法：
  pythonw stats_monthly_daily.py appeal|achievement       # 排程：自判
  python  stats_monthly_daily.py <job> --check            # 只印判定（不需網路），不跑、不寫狀態
  python  stats_monthly_daily.py <job> --force            # 立刻跑（achievement 不等 appeal）
  python  stats_monthly_daily.py <job> --force-next       # 記旗標，下一次排程觸發強制跑一次（Start-ScheduledTask 驗收用）
log：各自的 .bat log（appeal_monthly.log／achievement_monthly.log）；本檔的行以 `[yyyy-mm-dd hh:mm:ss] [launcher]` 開頭，
     最後一行固定 `[launcher] job=… rc=… mins=…`，每日巡檢擷取
狀態：_appeal_monthly_state.json／_achievement_monthly_state.json（gitignore scripts/_*.json；只記 fails／last_attempt／
     force_next／running，完成與否看 log）
"""
import argparse
import datetime as dt
import json
import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pipeline_lock import acquire_lock, pid_alive, release_lock  # noqa: E402

JOBS = {
    'appeal': {'bat': 'appeal_monthly.bat', 'log': 'appeal_monthly.log',
               'state': '_appeal_monthly_state.json', 'timeout_h': 2, 'before': None},
    'achievement': {'bat': 'achievement_monthly.bat', 'log': 'achievement_monthly.log',
                    'state': '_achievement_monthly_state.json', 'timeout_h': 3, 'before': 'appeal'},
}
MONTH_DAY = 20          # 原排程「每月 20 日」
MAX_FAILS = 3           # 同一個月內最多自動重試次數
LOCK_WAIT_MIN = 60      # 等 derivs／law010 釋放月包快取鎖的上限
BEFORE_WAIT_MIN = 60    # achievement 等 appeal 跑完的上限（appeal 平常 5～10 分鐘）
BEFORE_POLL_S = 30
NET_HOST_FALLBACK = 'opendata.judicial.gov.tw'
DATE_RE = re.compile(r'(\d{4})/(\d{1,2})/(\d{1,2})')
APPEAL_OK = ('月增量完成：', '無新月份可補')
NO_WIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


def path_of(job, key):
    return os.path.join(HERE, JOBS[job][key])


def today_date():
    return dt.date.today()


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


def make_logger(job):
    def log(msg):
        line = f'[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] [launcher] {msg}'
        try:
            print(line, flush=True)
        except (AttributeError, OSError, UnicodeEncodeError):  # pythonw 沒 stdout；cp950 主控台編不出來
            pass
        with open(path_of(job, 'log'), 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    return log


def parse_date(line):
    m = DATE_RE.search(line)
    if not m:
        return None
    try:
        return dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def last_success(job, log_path=None):
    """log 裡最後一次成功的日期；沒有回 None。cmd 的 %date% 是 cp950、python 輸出是 UTF-8，混著讀只認 ASCII 日期與 UTF-8 關鍵字。"""
    try:
        with open(log_path or path_of(job, 'log'), 'rb') as f:
            lines = f.read().decode('utf-8', errors='replace').splitlines()
    except OSError:
        return None
    best = None
    if job == 'achievement':
        for ln in lines:
            if '=====' in ln and ' done ' in ln:
                best = parse_date(ln) or best
        return best
    cur, ok = None, False
    for ln in lines:
        if '=====' in ln and '[launcher]' not in ln and parse_date(ln):
            if cur and ok:
                best = cur
            cur, ok = parse_date(ln), False
        elif cur and any(k in ln for k in APPEAL_OK):
            ok = True
    if cur and ok:
        best = cur
    return best


def decide(state, today, last_ok):
    """回傳 ('run'|'skip', 原因)。"""
    this_month = today.strftime('%Y%m')
    if today.day < MONTH_DAY:
        return 'skip', f'今天 {today.day} 日，未到每月 {MONTH_DAY} 日'
    if last_ok and last_ok.strftime('%Y%m') == this_month and last_ok.day >= MONTH_DAY:
        return 'skip', f'本月已於 {last_ok:%Y-%m-%d} 完成（log）'
    fails = state.get('fails') or {}
    if fails.get('month') == this_month and fails.get('count', 0) >= MAX_FAILS:
        return 'skip', f'本月已失敗 {fails["count"]} 次，不再自動重試（看 log 的 traceback／[error]）'
    return 'run', f'本月尚未完成（上次成功 {last_ok or "無紀錄"}）'


def pending_reason(job, today):
    """job 今天還有沒有「待跑」：正在跑／有 force_next 旗標／本月該跑但今天還沒試。沒有回 None。"""
    st = read_json(path_of(job, 'state')) or {}
    run = st.get('running') or {}
    if run.get('pid') and pid_alive(run['pid']):
        return f'{job} 正在跑（pid {run["pid"]}，{(run.get("started_at") or "?")[:16]} 起）'
    if st.get('force_next'):
        return f'{job} 有 force_next 旗標等下一次排程'
    action, _ = decide(st, today, last_success(job))
    if action == 'run' and (st.get('last_attempt') or '')[:10] != today.isoformat():
        return f'{job} 本月該跑、今天還沒試'
    return None


def wait_before(job, today, log):
    """照舊 appeal 先、achievement 後：等 job 今天的那一跑結束；等太久就照舊續跑（原排程只是隔 40 分鐘，也沒等它成功）。"""
    why = pending_reason(job, today)
    if not why:
        return
    log(f'先等 {job}：{why}（每 {BEFORE_POLL_S:g} 秒看一次，最多 {BEFORE_WAIT_MIN:g} 分鐘）')
    deadline = time.time() + BEFORE_WAIT_MIN * 60
    while time.time() < deadline:
        time.sleep(BEFORE_POLL_S)
        why = pending_reason(job, today)
        if not why:
            log(f'{job} 今天已結束，續跑')
            return
    log(f'等 {job} {BEFORE_WAIT_MIN:g} 分鐘仍「{why}」，照舊續跑（兩支取同一把月包鎖，不會同時動快取）')


def net_host():
    """scripts/.env 的 SUPABASE_URL 主機名（只取主機名，不印任何值）；沒有就用司法院開放平臺。"""
    try:
        with open(os.path.join(HERE, '.env'), encoding='utf-8-sig') as f:
            for ln in f:
                if ln.startswith('SUPABASE_URL=') and '://' in ln:
                    host = ln.split('://', 1)[1].strip().split('/', 1)[0]
                    return host or NET_HOST_FALLBACK
    except OSError:
        pass
    return NET_HOST_FALLBACK


def wait_network(host, tries=10, wait=30):
    for _ in range(tries):
        try:
            socket.getaddrinfo(host, 443)
            return True
        except socket.gaierror:
            time.sleep(wait)
    return False


def run_bat(job, log):
    """cmd /c 跑原 .bat（它自己把輸出 >> 進 log）；逾時 taskkill /T 整棵樹，別留下孤兒 python／npx。"""
    hours = JOBS[job]['timeout_h']
    t0 = time.time()
    p = subprocess.Popen(['cmd.exe', '/d', '/c', path_of(job, 'bat')], cwd=HERE,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=NO_WIN)
    try:
        rc = p.wait(timeout=hours * 3600)
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill', '/T', '/F', '/PID', str(p.pid)], capture_output=True, creationflags=NO_WIN)
        log(f'❌ {JOBS[job]["bat"]} 逾時 {hours:g} 小時，已 taskkill 整棵行程樹')
        rc = 124
    return rc, (time.time() - t0) / 60


def finish(job, rc, mins, counted, log):
    """收尾：清 running、記 last_attempt、fails 計數，寫最後一行 [launcher] job=… rc=… mins=…。"""
    state_path = path_of(job, 'state')
    state = read_json(state_path) or {}   # 重讀：跑的期間可能有人下了 --force-next
    state.pop('running', None)
    state['last_attempt'] = now_iso()
    this_month = today_date().strftime('%Y%m')
    if rc == 0:
        state.pop('fails', None)
        note = ''
    elif counted:
        fails = state.get('fails') if (state.get('fails') or {}).get('month') == this_month else {'month': this_month, 'count': 0}
        fails['count'] += 1
        state['fails'] = fails
        note = (f' fails={fails["count"]}/{MAX_FAILS}' +
                ('，本月不再自動重試，請看上面的錯誤' if fails['count'] >= MAX_FAILS else '，明天排程再試'))
    else:
        note = '（不計入失敗次數，明天排程再試）'
    write_json(state_path, state)
    log(f'job={job} rc={rc} mins={mins:.1f}{note}')
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('job', choices=sorted(JOBS), help='appeal＝appeal_monthly.bat；achievement＝achievement_monthly.bat')
    ap.add_argument('--check', action='store_true', help='只印判定結果，不跑、不寫狀態')
    ap.add_argument('--force', action='store_true', help='立刻強制跑（achievement 不等 appeal）')
    ap.add_argument('--force-next', action='store_true', help='下一次排程觸發強制跑一次')
    a = ap.parse_args(argv)
    job = a.job
    state_path = path_of(job, 'state')
    state = read_json(state_path) or {}
    log = make_logger(job)

    if a.force_next:
        state['force_next'] = {'set_at': now_iso()}
        write_json(state_path, state)
        print(f'已記旗標：下一次排程觸發強制跑 {JOBS[job]["bat"]}')
        return 0

    today = today_date()
    last_ok = last_success(job)
    action, dwhy = decide(state, today, last_ok)
    pending = state.get('force_next')
    if a.check:
        print(f'{action}：{dwhy}（上次成功 {last_ok or "無紀錄"}；狀態檔 {state_path}）')
        if pending is not None:
            print(f'  另有 force_next 旗標等下一次排程：{pending}')
        if JOBS[job]['before']:
            print(f'  先決 {JOBS[job]["before"]}：{pending_reason(JOBS[job]["before"], today) or "今天沒有待跑"}')
        return 0

    forced, why = a.force, '強制（--force）'
    if not forced and pending is not None:
        forced, why = True, f'強制（--force-next 旗標，{(pending.get("set_at") or "?")[:16]} 設定）'
    if not forced:
        if action == 'skip':
            return 0   # 未到日／本月已完成：不留痕
        why = dwhy

    # 一次寫入：消耗旗標＋標記 running（achievement 看 appeal 的 running／旗標決定要不要等）
    state.pop('force_next', None)
    state['running'] = {'pid': os.getpid(), 'started_at': now_iso()}
    write_json(state_path, state)

    if JOBS[job]['before'] and not a.force:
        wait_before(JOBS[job]['before'], today, log)
    if not wait_network(net_host()):
        log('❌ 網路 5 分鐘內未就緒，本次放棄')
        return finish(job, 1, 0.0, False, log)
    if not acquire_lock(f'stats_monthly_daily:{job}', LOCK_WAIT_MIN, log=log):
        log(f'❌ 等月包快取鎖 {LOCK_WAIT_MIN} 分鐘仍被佔用，本次放棄')
        return finish(job, 1, 0.0, False, log)
    try:
        log(f'開跑：{why}；cmd /c {JOBS[job]["bat"]}')
        rc, mins = run_bat(job, log)
    finally:
        release_lock()
    return finish(job, rc, mins, True, log)


if __name__ == '__main__':
    sys.exit(main())
