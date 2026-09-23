# -*- coding: utf-8 -*-
"""裁判書月包「衍生管線」月更 launcher（Windows 排程 judgment-derivs-monthly）

背景（2026-09-24）：下列管線上線時都是一次性手動回填，沒有排程，頁面數字停在回填當月
（霸凌判決停 202605、企業當事人停 202604、金額/收費/大額停 202606、集中度停 7/31）。
雲端 judgment-stats-monthly（每月 17 日）與本機 appeal/achievement（每月 20 日）不涵蓋它們。
這些都依賴本機 .judgment_work 月包快取，所以排本機，不搬 GH Actions。

目標月＝雲端月更已落地的最新月（lawyer_month_stats 的 max(yyyymm)）——官方月包發布
時點不固定，用 DB 當「已發布」的權威訊號，不自己猜日期。

步驟（任一步失敗→記錄後繼續跑不相依的步驟，最後 exit 1；log 看「❌」）：
  legal-industry-intel
    1. client_concentration collect   補當事人快取（金額/大額/集中度/霸凌名單都吃它）
    2. client_concentration aggregate 近 12 個月集中度（upsert＋刪舊列＋驗證）
    3. lawyer_case_amount backfill    律師×標的金額桶＋收費模型（跳過 DB 已有月）
    4. big_amount_cases backfill      1 億+ 逐案（.bac_done 續跑）
    5. corp_party_stats backfill+upload  企業當事人（年列 upsert，重算當年）
  bullying-intel
    6. bullying_mine batch            霸凌關鍵詞全文掃描（已有 _bully 檔跳過）
    7. bullying_analyze（＋stats）→ bullying_upload cases/stats（筆數防呆）
    8. match_company_litigation → build_prospects  勞資爭議名單訴訟比對重建（筆數防呆）

用法：
  python judgment_derivs_monthly.py            # 自動判定目標月
  python judgment_derivs_monthly.py 202607     # 指定目標月
log：scripts/judgment_derivs_monthly.log（追加）
"""
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BULLY = r'C:\projects\bullying-intel\scripts'
LOG = os.path.join(HERE, 'judgment_derivs_monthly.log')
PY = sys.executable.replace('pythonw.exe', 'python.exe')
NO_WIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


def log(msg):
    line = f'[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}'
    print(line, flush=True)
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


ENV_LII = env_of(os.path.join(HERE, '.env'))
ENV_BULLY = env_of(os.path.join(BULLY, '.env'))


def rest_get(path):
    url = ENV_LII['SUPABASE_URL'].rstrip('/') + '/rest/v1/' + path
    key = ENV_LII['SUPABASE_SERVICE_KEY']
    req = urllib.request.Request(url, headers={'apikey': key, 'Authorization': f'Bearer {key}'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def rest_count(table):
    url = ENV_LII['SUPABASE_URL'].rstrip('/') + f'/rest/v1/{table}?select=*&limit=1'
    key = ENV_LII['SUPABASE_SERVICE_KEY']
    req = urllib.request.Request(url, headers={'apikey': key, 'Authorization': f'Bearer {key}',
                                               'Prefer': 'count=exact'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers['Content-Range'].split('/')[1])


def shift(ym, n):
    y, m = int(ym[:4]), int(ym[4:]) + n
    while m < 1:
        y, m = y - 1, m + 12
    while m > 12:
        y, m = y + 1, m - 12
    return f'{y}{m:02d}'


def run(desc, args, cwd, env_extra, timeout=3 * 3600):
    log(f'▶ {desc}：{" ".join(args)}')
    env = {**os.environ, **env_extra, 'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'}
    t0 = dt.datetime.now()
    try:
        p = subprocess.run([PY] + args, cwd=cwd, env=env, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=timeout,
                           creationflags=NO_WIN)
    except subprocess.TimeoutExpired:
        log(f'❌ {desc} 逾時 {timeout // 60} 分鐘')
        return False
    tail = [ln for ln in (p.stdout or '').splitlines() if ln.strip() and 'warn' not in ln.lower()][-6:]
    for ln in tail:
        log(f'    {ln[:200]}')
    mins = (dt.datetime.now() - t0).seconds / 60
    if p.returncode != 0:
        err = [ln for ln in (p.stderr or '').splitlines() if ln.strip() and 'warn' not in ln.lower()][-4:]
        for ln in err:
            log(f'    ! {ln[:200]}')
        log(f'❌ {desc} rc={p.returncode}（{mins:.1f} 分）')
        return False
    log(f'✅ {desc}（{mins:.1f} 分）')
    return True


def main():
    log('=' * 60)
    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        target = rest_get('lawyer_month_stats?select=yyyymm&order=yyyymm.desc&limit=1')[0]['yyyymm']
    log(f'裁判書衍生管線月更開始；目標月 {target}')
    fails = []

    def step(desc, args, cwd, env_extra):
        ok = run(desc, args, cwd, env_extra)
        if not ok:
            fails.append(desc)
        return ok

    lii = (HERE, {})
    # 1-2 當事人快取＋集中度
    if step('當事人快取補抓', ['client_concentration.py', 'collect', '202111', target], *lii):
        step('客戶集中度彙總', ['client_concentration.py', 'aggregate', shift(target, -11), target], *lii)
    # 3-4 金額／收費／大額（自帶「API 已發布」判斷，跳過已完成月）
    step('律師×標的金額＋收費', ['lawyer_case_amount.py', 'backfill', '202111', target], *lii)
    step('1 億+ 大額案件', ['big_amount_cases.py', 'backfill', '202111', target], *lii)
    # 5 企業當事人：補最近 6 個月的 _corp.json（已有跳過），再重算涉及年份
    first = shift(target, -5)
    if step('企業當事人解析', ['corp_party_stats.py', 'backfill', first, target], *lii):
        step('企業當事人上傳', ['corp_party_stats.py', 'upload', first[:4] + '01', target], *lii)

    # 6-8 霸凌線（bullying-intel）
    bl = (BULLY, {'SUPABASE_URL': ENV_BULLY.get('SUPABASE_URL', ''),
                  'SUPABASE_SERVICE_KEY': ENV_BULLY.get('SUPABASE_SERVICE_KEY', '')})
    if step('霸凌判決掃描', ['bullying_mine.py', 'batch', '202111', target], *bl) and \
       step('霸凌判決分類', ['bullying_analyze.py'], *bl) and \
       step('霸凌判決聚合', ['bullying_analyze.py', 'stats'], *bl):
        before = rest_count('b2b_wp_judgments')
        after = len(json.load(open(os.path.join(BULLY, '_bully_cases.json'), encoding='utf-8')))
        if after < before * 0.95:
            log(f'❌ 霸凌判決筆數防呆：新 {after} < 現有 {before} 的 95%，不上傳')
            fails.append('霸凌判決筆數防呆')
        else:
            log(f'  霸凌判決 {before} → {after}')
            step('霸凌判決上傳', ['bullying_upload.py', 'cases'], *bl) and \
                step('霸凌統計上傳', ['bullying_upload.py', 'stats'], *bl)
    if step('上市櫃訴訟比對', ['match_company_litigation.py'], *bl):
        before = rest_count('b2b_prospects')
        if step('勞資爭議名單試算', ['build_prospects.py', '--dry'], *bl):
            step('勞資爭議名單重建', ['build_prospects.py'], *bl)
            after = rest_count('b2b_prospects')
            log(f'  b2b_prospects {before:,} → {after:,}')
            if after < before * 0.95:
                log('❌ 名單筆數縮水超過 5%，請人工檢查')
                fails.append('名單筆數縮水')

    if fails:
        log(f'❌ 完成但有失敗：{"、".join(fails)}')
        sys.exit(1)
    log('✅ 裁判書衍生管線全部完成')


if __name__ == '__main__':
    main()
