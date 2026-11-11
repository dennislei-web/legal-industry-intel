"""
官網定期複驗（每週）— 健康檢查＋名冊律師姓名比對（mig 275）

對 firm_websites 所有「有網址」的列（已驗證的，以及先前被本腳本自動下架的）：
  1. 抓首頁 → health_status：ok / name_missing / http_error / unreachable / blocked
  2. 連得上的，再找名冊佐證（website_verify.assess_website）：首頁沒命中就順著站內
     「團隊／律師／關於／聯絡」類連結最多再抓 MAX_SUBPAGES 頁
     → roster_match：lawyer_name（站上有名冊律師姓名）/ contact（地址、電話、信箱吻合）
       / title（首頁標題即本所）/ firm_only（只有所名＝審核佇列）/ none
  3. 連續失敗 UNVERIFY_STREAK 次（預設 3）→ verified=false（網址保留）；
     之後恢復正常會自動轉回 verified=true（只限本腳本自己下架的）

與 verify_firm_websites.py 的差別：那支是一次性清洗，不通過就清空網址；
本支是常態巡檢，單次失敗不動資料，避免站方暫時當機就被洗掉。

環境變數：
  LIMIT=0            只跑前 N 筆（測試用；按 health_checked_at 舊者優先）
  DRY_RUN=false      true＝只印結果不寫 DB
  UNVERIFY_STREAK=3  連續失敗幾次才下架
  WORKERS=8          平行數
  MAX_SUBPAGES=5     每所最多追幾個站內子頁找律師姓名
"""
import os
import sys
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv

from website_verify import assess_website, firm_key

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

load_dotenv()
BASE = os.environ['SUPABASE_URL'].strip().rstrip('/') + '/rest/v1'
KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
API_HEADERS = {'apikey': KEY, 'Authorization': f'Bearer {KEY}'}

LIMIT = int(os.environ.get('LIMIT', '0') or 0)
DRY_RUN = os.environ.get('DRY_RUN', 'false').lower() == 'true'
UNVERIFY_STREAK = int(os.environ.get('UNVERIFY_STREAK', '3') or 3)
WORKERS = int(os.environ.get('WORKERS', '8') or 8)
MAX_SUBPAGES = int(os.environ.get('MAX_SUBPAGES', '5') or 5)

# 疑似擋爬蟲的狀態碼：不算失敗、不累計 streak
BLOCKED_CODES = {401, 403, 429, 503}


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


# ---------- PostgREST ----------
def rest_get_all(path, params, order):
    """逐頁取完（PostgREST 單次上限 1000 列，order 必帶唯一鍵）"""
    rows, start = [], 0
    while True:
        h = dict(API_HEADERS)
        h['Range-Unit'] = 'items'
        h['Range'] = f'{start}-{start + 999}'
        p = dict(params)
        p['order'] = order
        r = _retry(lambda: requests.get(f'{BASE}/{path}', params=p, headers=h, timeout=60))
        page = r.json()
        rows.extend(page)
        if len(page) < 1000:
            return rows
        start += 1000


def rest_patch(path, params, body):
    h = dict(API_HEADERS)
    h['Content-Type'] = 'application/json'
    h['Prefer'] = 'return=minimal'
    _retry(lambda: requests.patch(f'{BASE}/{path}', params=params, headers=h, json=body, timeout=30))


def _retry(fn, tries=4):
    """5xx／連線錯誤退避重試（長 refresh 鎖表時 PostgREST 會整站 503）"""
    for i in range(tries):
        try:
            r = fn()
            if r.status_code < 500:
                r.raise_for_status()
                return r
            err = f'HTTP {r.status_code}'
        except requests.RequestException as e:
            if getattr(e, 'response', None) is not None and e.response.status_code < 500:
                raise
            err = type(e).__name__
        if i == tries - 1:
            raise RuntimeError(f'PostgREST 重試 {tries} 次仍失敗（{err}）')
        time.sleep(15 * (i + 1))


# ---------- 單所檢查 ----------
def check(row, roster, blocklist):
    """回 dict：health_status / health_http_status / roster_match / roster_hit_count / roster_total / roster_hit_url
    判定邏輯在 website_verify.assess_website（與搜尋腳本寫入前驗證共用）"""
    firm = row['firm_name']
    lawyers = roster.get(firm.replace(' ', ''), [])
    out = {'health_status': None, 'health_http_status': None, 'roster_match': 'none',
           'roster_hit_count': 0, 'roster_total': len(lawyers), 'roster_hit_url': None}
    a = assess_website(row['website_url'], firm, lawyers, blocklist, max_subpages=MAX_SUBPAGES)
    status = a['status']
    out['health_http_status'] = status
    if status == 0:
        out['health_status'] = 'unreachable'
    elif status in BLOCKED_CODES:
        out['health_status'] = 'blocked'
    elif status >= 400 or not a['final_home']:
        out['health_status'] = 'http_error'
    elif a['blocked_host']:
        # 轉址到黃頁／平台／外國網域＝網域已易主或被收走
        out['health_status'] = 'name_missing'
    else:
        ev = a['evidence']
        # 站上找得到本所律師或聯絡資料 → 即使首頁排版讓所名比對落空，也視為本所官網
        out['health_status'] = 'ok' if (a['firm_ok'] or ev in ('lawyer_name', 'contact')) else 'name_missing'
        if ev:
            out['roster_match'] = ev            # lawyer_name / contact / title
        elif a['firm_ok']:
            out['roster_match'] = 'firm_only'   # 只有所名、沒有任何佐證 → 審核佇列
        out['roster_hit_count'] = len(a['signals'])
        out['roster_hit_url'] = (a['hit_url'] or '')[:500] or None
    return out


def load_roster():
    """{事務所名（去空白）: [{name,email,tel,address}...]}"""
    rows = rest_get_all('moj_lawyers',
                        {'select': 'lic_no,name,office_normalized,email,tel,address',
                         'office_normalized': 'not.is.null'},
                        'lic_no.asc')
    roster = defaultdict(list)
    for r in rows:
        key = firm_key(r.get('office_normalized'))
        if key:
            roster[key].append(r)
    return dict(roster)


def main():
    blocklist = {r['domain'] for r in rest_get_all('firm_website_blocklist', {'select': 'domain'}, 'domain.asc')}
    roster = load_roster()
    log(f'blocklist {len(blocklist)} 網域；名冊 {len(roster)} 間事務所')

    rows = rest_get_all('firm_websites', {
        'select': 'id,firm_name,website_url,verified,fail_streak,auto_unverified_at,health_checked_at',
        'website_url': 'not.is.null',
        # 已驗證的＋先前被本腳本自動下架的（人工或清洗判 false 的不碰）
        'or': '(verified.is.true,auto_unverified_at.not.is.null)',
    }, 'id.asc')
    rows = [r for r in rows if (r.get('website_url') or '').strip()]
    rows.sort(key=lambda r: r.get('health_checked_at') or '')  # 沒驗過／最久沒驗的先
    if LIMIT:
        rows = rows[:LIMIT]
    log(f'待複驗 {len(rows)} 筆（DRY_RUN={DRY_RUN}，下架門檻連續 {UNVERIFY_STREAK} 次）')

    now = datetime.now(timezone.utc).isoformat()
    stats, match_stats = Counter(), Counter()
    unverified, restored, write_fail = [], [], 0
    t0 = time.time()

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for i, (row, res) in enumerate(zip(rows, ex.map(lambda r: check(r, roster, blocklist), rows)), 1):
            st = res['health_status']
            stats[st] += 1
            match_stats[res['roster_match']] += 1
            streak = row.get('fail_streak') or 0
            if st == 'ok':
                streak = 0
            elif st != 'blocked':
                streak += 1

            body = dict(res, health_checked_at=now, fail_streak=streak)
            if st == 'blocked':
                # 被擋＝這次沒看到內容，保留上次的姓名比對結果
                for k in ('roster_match', 'roster_hit_count', 'roster_total', 'roster_hit_url'):
                    body.pop(k)
            if row.get('verified') and streak >= UNVERIFY_STREAK:
                body.update(verified=False, auto_unverified_at=now)
                unverified.append((row['firm_name'], row['website_url'], st))
            elif not row.get('verified') and row.get('auto_unverified_at') and st == 'ok':
                body.update(verified=True, verified_at=now, auto_unverified_at=None)
                restored.append((row['firm_name'], row['website_url']))

            if not DRY_RUN:
                try:
                    rest_patch('firm_websites', {'id': f'eq.{row["id"]}'}, body)
                except Exception as e:
                    write_fail += 1
                    log(f'  寫回失敗 {row["firm_name"]}：{e}')
            elif st != 'ok' or res['roster_match'] != 'lawyer_name':
                log(f'  {row["firm_name"]} | {row["website_url"]} | {st}({res["health_http_status"]}) | '
                    f'{res["roster_match"]} {res["roster_hit_count"]}/{res["roster_total"]}')
            if i % 100 == 0:
                log(f'  [{i}/{len(rows)}] {dict(stats)}，{time.time() - t0:.0f}s')

    log(f'健康狀態：{dict(stats)}')
    log(f'姓名比對：{dict(match_stats)}')
    log(f'本次自動下架 {len(unverified)} 筆、恢復 {len(restored)} 筆、寫回失敗 {write_fail} 筆')
    for firm, url, st in unverified:
        log(f'  下架 {firm} | {url} | {st}')
    for firm, url in restored:
        log(f'  恢復 {firm} | {url}')

    # 給 workflow 判斷要不要刷新快取
    out = os.environ.get('GITHUB_OUTPUT')
    if out:
        with open(out, 'a', encoding='utf-8') as f:
            f.write(f'changed={len(unverified) + len(restored)}\n')
    # 寫回失敗超過一成＝這次結果不可信，紅燈
    if rows and write_fail > len(rows) * 0.1:
        sys.exit(1)


if __name__ == '__main__':
    main()
