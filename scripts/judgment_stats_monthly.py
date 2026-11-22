# -*- coding: utf-8 -*-
"""裁判書法官統計 月更 launcher（Windows 排程 judgment-stats-monthly：每日 13:00 觸發、腳本自判）

為什麼排本機、不排 GitHub Actions：
  .github/workflows/judgment-stats-monthly.yml 原本每月 17／20／23／27 日從 GitHub runner 連
  opendata.judicial.gov.tw 抓「兩個月前」的裁判書月包。2026-11-17、11-20 連兩次 connect timeout
  （runner 海外 IP 被擋），11-22 在本機補跑正常。→ 2026-11-22 搬本機，workflow 只留手動備援。

為什麼「每日觸發＋腳本自判」：雷晚上關機，月更型觸發漏跑後開機不補跑，每日型會補。

每天的判斷（都以「月表三表齊全＋共署 pair 都已上傳」為完成）：
    1. 三個月前那個月還沒完成 → 先補它（上個月沒補完的自癒；workflow 版做不到這件事）
    2. 否則今天 ≥ 17 日且兩個月前那個月還沒完成 → 跑它
    3. 其餘 → 略過
要跑時照 workflow 的步驟：
    a. 月表沒上傳 → `judgment_stats.py run <ym>`
         rc 75＝平臺還沒上架：不算失敗，明天再試；27 日起仍沒上架才記異常
         rc 76＝月表已落地但 refresh 鏈沒跑完：後面照跑，最後記異常
             （之後每天會因「已上傳」略過，不會自動補 refresh → 手動 `python judgment_stats.py refresh`）
    b. 共署 pair 沒上傳 → `jy_copanel.py run <ym>`
    c. 本次有新資料落地 → jy_transfers list／fetch／parse／upload ＋ rpc refresh_judge_change_transfers
    d. 月表本次落地 → PATCH data_sources.last_scraped_at（judgment_stats）

log：scripts/judgment_stats_monthly.log（追加；已 gitignore）
最後一行固定是 `[launcher] action=skip reason=…`、`[launcher] action=wait ym=… reason=尚未上架`
或 `[launcher] action=run ym=… stats_rc=… copanel_rc=… transfers_ok=… patch_ok=… ok=0|1`
（沒跑的步驟寫 `-`）。action=skip／wait 正常；action=run 要 ok=1，否則異常（log 找「❌」）。

用法：
  python judgment_stats_monthly.py            # 排程用（自判）
  python judgment_stats_monthly.py --check    # 只印判斷結果，不跑
  python judgment_stats_monthly.py 202609     # 手動指定月份（已上傳的部分一樣會跳過）
"""
import datetime as dt
import os
import re
import subprocess
import sys

import closed_case_stats_monthly as ccm  # rpc()
import judicial_official_stats_monthly as base  # 共用 log／env_of／run／patch_last_scraped

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_FROM_DAY = 17        # 原 cron 第一次嘗試：台灣 17 日
LAST_ATTEMPT_DAY = 27    # 原 cron 最後一次嘗試：台灣 27 日；這天起仍沒上架就記異常
STATS_TIMEOUT = 3 * 3600
EXIT_NOT_PUBLISHED, EXIT_REFRESH_FAILED = 75, 76
log = base.log


def setup():
    """本檔被當主程式跑時才改共用模組的設定（避免 import 順序互相蓋掉）"""
    base.LOG = os.path.join(HERE, 'judgment_stats_monthly.log')
    base.SCRAPER_NAME = 'judgment_stats'


def months_before(today, n):
    y, m = today.year, today.month - n
    while m <= 0:
        y, m = y - 1, m + 12
    return f'{y}{m:02d}'


def uploaded(ym):
    """回傳 (月表三表齊全?, 共署 pair 已上傳?)；查詢失敗拋錯（不可當成未上傳而誤觸整月刪後重插）"""
    code = ('import urllib3; urllib3.disable_warnings()\n'
            'import judgment_stats as js, jy_copanel\n'
            f'print("CHK", int(bool(js.month_uploaded("{ym}", full=True))), int(bool(jy_copanel.month_uploaded("{ym}"))))')
    env = {**os.environ, 'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'}
    p = subprocess.run([base.PY, '-c', code], cwd=HERE, env=env, capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=300, creationflags=base.NO_WIN)
    m = re.search(r'^CHK (\d) (\d)\s*$', p.stdout or '', re.M)
    if p.returncode != 0 or not m:
        tail = ' | '.join((p.stderr or '').strip().splitlines()[-2:])[:300]
        raise RuntimeError(f'上傳狀態查詢失敗 rc={p.returncode} {tail}')
    return m.group(1) == '1', m.group(2) == '1'


def pick_target(now_local):
    """回傳 (ym 或 None, stats_done, copanel_done, 原因)"""
    prev, cur = months_before(now_local, 3), months_before(now_local, 2)
    s, c = uploaded(prev)
    if not (s and c):
        return prev, s, c, f'上一期 {prev} 還沒完成（月表 {int(s)}／共署 {int(c)}）'
    if now_local.day < RUN_FROM_DAY:
        return None, True, True, f'{prev} 已完成；{cur} 要等每月 {RUN_FROM_DAY} 日起'
    s, c = uploaded(cur)
    if s and c:
        return None, True, True, f'{cur} 已完成'
    return cur, s, c, f'{cur} 還沒完成（月表 {int(s)}／共署 {int(c)}）'


def main():
    setup()
    args = sys.argv[1:]
    check_only = '--check' in args
    manual = next((a for a in args if re.fullmatch(r'\d{6}', a)), None)
    log('=' * 60)
    log(f'裁判書法官統計月更 launcher 開始（PY={base.PY}{"，--check" if check_only else ""}'
        f'{"，指定 " + manual if manual else ""}）')
    env = base.env_of(os.path.join(HERE, '.env'))
    now_local = dt.datetime.now().astimezone()

    try:
        if manual:
            s, c = uploaded(manual)
            ym, reason = (None if s and c else manual), f'手動指定 {manual}（月表 {int(s)}／共署 {int(c)}）'
        else:
            ym, s, c, reason = pick_target(now_local)
    except Exception as e:  # noqa: BLE001
        log(f'❌ {type(e).__name__}: {str(e)[:300]}')
        log('[launcher] action=run ym=? stats_rc=-1 copanel_rc=- transfers_ok=- patch_ok=- ok=0')
        sys.exit(1)

    log(f'判斷：{"跑 " + ym if ym else "略過"}——{reason}')
    if check_only:
        log(f'[launcher] action=check target={ym or "-"}')
        return
    if not ym:
        log(f'[launcher] action=skip reason={reason}')
        return

    stats_rc = copanel_rc = transfers_ok = patch_ok = '-'
    landed = False          # 月表本次落地
    if not s:
        stats_rc = base.run(f'月表 run {ym}', ['judgment_stats.py', 'run', ym], timeout=STATS_TIMEOUT)
        if stats_rc == EXIT_NOT_PUBLISHED:
            final = manual or now_local.day >= LAST_ATTEMPT_DAY or ym != months_before(now_local, 2)
            if final:
                log(f'❌ {ym} 裁判書月包在平臺上還查不到（已過每月 {LAST_ATTEMPT_DAY} 日或為補跑月份）')
                log(f'[launcher] action=run ym={ym} stats_rc=75 copanel_rc=- transfers_ok=- patch_ok=- ok=0')
                sys.exit(1)
            log(f'  {ym} 尚未上架，不算失敗，明天再試')
            log(f'[launcher] action=wait ym={ym} reason=尚未上架')
            return
        landed = stats_rc in (0, EXIT_REFRESH_FAILED)
        if stats_rc == EXIT_REFRESH_FAILED:
            log('❌ 月表已落地但 refresh 鏈沒跑完（看上面「refresh 摘要」）；之後不會自動補，'
                '排除原因後手動跑：python judgment_stats.py refresh')
        if not landed:
            log(f'[launcher] action=run ym={ym} stats_rc={stats_rc} copanel_rc=- transfers_ok=- patch_ok=- ok=0')
            sys.exit(1)

    if not c:
        copanel_rc = base.run(f'共署 pair run {ym}', ['jy_copanel.py', 'run', ym], timeout=2 * 3600)

    if landed or copanel_rc == 0:
        ok = True
        for step in ('list', 'fetch', 'parse', 'upload'):
            if base.run(f'官方遷調邊 {step}', ['jy_transfers.py', step], timeout=3600) != 0:
                ok = False  # parse 有新句型警告會 exit 1 擋 upload（解析器要補樣態）
                break
        transfers_ok = int(ok and ccm.rpc(env, 'refresh_judge_change_transfers'))

    if landed:  # 後面步驟失敗也照寫：之後的重試月表會被跳過，這裡不寫就永遠不會寫
        patch_ok = int(base.patch_last_scraped(env))

    all_ok = (stats_rc in ('-', 0) and copanel_rc in ('-', 0)
              and transfers_ok in ('-', 1) and patch_ok in ('-', 1))
    log(f'[launcher] action=run ym={ym} stats_rc={stats_rc} copanel_rc={copanel_rc} '
        f'transfers_ok={transfers_ok} patch_ok={patch_ok} ok={int(all_ok)}')
    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
