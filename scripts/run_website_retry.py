"""官網重掃 supervisor：scrape_firm_websites.py 的看門狗會在無聲卡死時 exit 3，
這裡負責以全新行程（全新連線）重啟；正常結束（exit 0）就收工。
用法：設好 RETRY_MISSING 等環境變數後執行本檔（stdout 導到 log）。"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_RESTARTS = int(os.environ.get('SUPERVISOR_MAX_RESTARTS', '200'))

restarts = 0
while True:
    print(f'[supervisor] 啟動 scrape_firm_websites.py（第 {restarts + 1} 次）', flush=True)
    rc = subprocess.call([sys.executable, '-u', os.path.join(HERE, 'scrape_firm_websites.py')],
                         cwd=HERE)
    print(f'[supervisor] 子行程結束 rc={rc}', flush=True)
    if rc == 0:
        print('[supervisor] 正常收工', flush=True)
        break
    restarts += 1
    if restarts >= MAX_RESTARTS:
        print(f'[supervisor] 重啟達上限 {MAX_RESTARTS} 次，停止', flush=True)
        break
    time.sleep(60)
