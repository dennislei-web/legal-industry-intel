"""產業觀察報告＋AI 解讀：本機每日排程 launcher（Windows 排程 industry-watch-daily，pythonw 執行）

為什麼在本機：AI 解讀要 Anthropic API 金鑰，金鑰不放 GitHub；GitHub 排程只產規則報告，
這支在本機跑 `industry_watch_report.py auto`——到期的報告若還沒產就產（含解讀），最近 3 期缺解讀的補上。
金鑰來源：scripts/.env 的 ANTHROPIC_API_KEY，或 scripts/.env 的 ANTHROPIC_KEY_FILE 指到的 .env。
log：scripts/industry_watch_local.log（UTF-8 追加），最後一行固定 `[launcher] rc=…`。
"""
import datetime as dt
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, 'industry_watch_local.log')
PY = sys.executable.replace('pythonw.exe', 'python.exe')


def log(msg):
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(f'[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}\n')


def net_ready(tries=10):
    for i in range(tries):
        try:
            socket.create_connection(('api.anthropic.com', 443), timeout=5).close()
            return True
        except OSError:
            time.sleep(30)
    return False


def main():
    log('=' * 60)
    log(f'產業觀察本機排程開始（PY={PY}）')
    if not net_ready():
        log('[launcher] rc=9 網路未就緒，放棄本次（明天會再跑）')
        return
    env = dict(os.environ, PYTHONIOENCODING='utf-8', PYTHONUTF8='1')
    rc = 1
    for attempt in (1, 2):
        r = subprocess.run([PY, os.path.join(HERE, 'industry_watch_report.py'), 'auto'], cwd=HERE, env=env,
                           capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=3600)
        for line in (r.stdout + r.stderr).splitlines():
            log('    ' + line)
        rc = r.returncode
        if rc == 0:
            break
        log(f'auto 失敗 rc={rc}（第 {attempt} 次）' + ('，120 秒後重試' if attempt == 1 else ''))
        if attempt == 1:
            time.sleep(120)
    log(f'[launcher] rc={rc}')


if __name__ == '__main__':
    main()
