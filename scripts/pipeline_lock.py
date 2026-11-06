# -*- coding: utf-8 -*-
"""月包快取（scripts/.judgment_work）互斥鎖 pipeline.lock——本機幾支會動月包的排程共用

誰取這把鎖（都會下載／解壓／改寫 .judgment_work 月包快取，不可同時跑）：
  legal-industry-intel：judgment_derivs_daily.py（裁判書衍生管線月更）、stats_monthly_daily.py（appeal／achievement 月更 .bat）
  lawyer-dashboard-clean：sync_judgment_match_daily.py（法律010 判決比對月更）、jmatch_refresh_poller.py（UI「重跑比對」）
  lawyer-dashboard-clean/scripts/pipeline_lock.py 是本檔的同內容副本（只差預設鎖路徑那一行）——改協定要兩邊一起改。

協定：
  鎖檔 = <JUDGMENT_WORK_DIR 或 scripts/.judgment_work>/pipeline.lock，內容 JSON {pid, owner, started_at}
  取鎖 = os.open(O_CREAT|O_EXCL) 原子建立；建不成就讀持有者：pid 已不在（tasklist 查）或鎖檔超過 STALE_H 小時
         → 當殘留刪掉重取；否則每 POLL_S 秒再試，最多等 wait_min 分鐘，等不到回 False（呼叫端自己決定放棄或留隊）
  放鎖 = 只刪 pid 是自己的鎖檔（別人接管過的不碰）

用法：
  from pipeline_lock import acquire_lock, release_lock
  if not acquire_lock('我的名字', wait_min=60, log=log): ...放棄...
  try: ...跑... finally: release_lock()
"""
import datetime as dt
import json
import os
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WORK_DIR = os.environ.get('JUDGMENT_WORK_DIR') or os.path.join(HERE, '.judgment_work')
LOCK = os.path.join(WORK_DIR, 'pipeline.lock')
STALE_H = 12          # 鎖檔超過這麼久一律當殘留（最長的 derivs 全跑也不到 8 小時）
POLL_S = 30           # 等鎖的輪詢間隔
NO_WIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


def _read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_holder(lock=None):
    """鎖檔內容（dict）；沒鎖或讀不出來回 {}。"""
    return _read_json(lock or LOCK) or {}


def pid_alive(pid):
    """Windows 下用 tasklist 查 pid 是否還在（Git Bash 的 ps 看不到 Windows 行程）；查不出來當活著、寧可多等。"""
    try:
        out = subprocess.run(['tasklist', '/FI', f'PID eq {int(pid)}', '/NH', '/FO', 'CSV'],
                             capture_output=True, timeout=30, creationflags=NO_WIN).stdout or b''
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return True
    return f'"{int(pid)}"'.encode('ascii') in out   # bytes 比對：tasklist 的「沒有符合」訊息是 cp950，text 模式在 UTF-8 下會炸


def acquire_lock(owner, wait_min, log=None, lock=None, poll_s=None):
    """取鎖成功回 True；等 wait_min 分鐘仍被活著的持有者佔用回 False。log(msg) 只在開始等的時候叫一次。"""
    lock = lock or LOCK
    poll_s = POLL_S if poll_s is None else poll_s
    os.makedirs(os.path.dirname(lock), exist_ok=True)
    deadline = time.time() + wait_min * 60
    announced = False
    while True:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            holder = read_holder(lock)
            try:
                age_h = (time.time() - os.path.getmtime(lock)) / 3600
            except OSError:
                age_h = 0
            if not holder.get('pid') or age_h > STALE_H or not pid_alive(holder['pid']):
                try:
                    os.remove(lock)     # 殘留鎖：持有者早不在了
                except OSError:
                    pass
                time.sleep(1)
                continue
            if time.time() >= deadline:
                return False
            if not announced and log:
                log(f'月包快取鎖被 {holder.get("owner", "?")}（pid {holder["pid"]}）佔用，最多等 {wait_min:g} 分鐘')
                announced = True
            time.sleep(min(poll_s, max(deadline - time.time(), 0.1)))
            continue
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump({'pid': os.getpid(), 'owner': owner,
                       'started_at': dt.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}, f)
        return True


def release_lock(lock=None):
    """只刪自己持有的鎖；別人的（或已被接管的）不碰。"""
    lock = lock or LOCK
    try:
        if read_holder(lock).get('pid') == os.getpid():
            os.remove(lock)
    except OSError:
        pass
