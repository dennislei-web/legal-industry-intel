"""
官網定期複驗（每週）— 健康檢查＋名冊律師姓名比對（mig 275）

對 firm_websites 所有「有網址」的列（已驗證的，以及先前被本腳本自動下架的）：
  1. 抓首頁 → health_status：ok / name_missing / http_error / unreachable / blocked
  2. 連得上的，再比對法務部名冊上該所律師姓名：首頁沒命中就順著站內
     「團隊／律師／關於」類連結最多再抓 MAX_SUBPAGES 頁
     → roster_match：lawyer_name / firm_only / none
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
import html as html_mod
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse

import requests
from dotenv import load_dotenv

from website_verify import (VERIFY_HEADERS, _decode_html, host_blocked,
                            homepage_of, name_in_text, name_keys, page_text)

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

# 與 moj_firm_statistics() 的 firm_key 同一條規則：截到第一個「法律／律師事務所」
FIRM_KEY_RE = re.compile(r'^(.+?(?:法律|律師)事務所).*$')
# 疑似擋爬蟲的狀態碼：不算失敗、不累計 streak
BLOCKED_CODES = {401, 403, 429, 503}
# 站內子頁：連結文字或網址像「團隊／律師介紹／關於」的優先
TEAM_HINT_RE = re.compile(
    r'團隊|律師|成員|關於|簡介|介紹|顧問|主持|about|team|lawyer|attorney|member|people|profile|staff',
    re.I)
LINK_RE = re.compile(r'<a\b[^>]*?href\s*=\s*["\']([^"\'#]+)["\'][^>]*>(.*?)</a>', re.S | re.I)
TAG_RE = re.compile(r'<[^>]+>')
_META_SEP = b'\n===CURLMETA==='


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


# ---------- 抓頁 ----------
def fetch(url, timeout=20):
    """回 (status, html, final_url)。status=0＝DNS／連線／逾時。
    走系統 curl：requests 管不到 DNS 逾時（這台機器 getaddrinfo 卡死過）。
    -k：憑證過期的站仍算活著（瀏覽器會警告，但站還在）。"""
    try:
        cmd = ['curl', '-s', '-L', '-k', '--compressed', '-m', str(timeout), '--max-redirs', '5', url,
               '-w', _META_SEP.decode() + '%{url_effective} %{http_code}']
        for k, v in VERIFY_HEADERS.items():
            cmd += ['-H', f'{k}: {v}']
        r = subprocess.run(cmd, capture_output=True, timeout=timeout + 10)
        raw = r.stdout
        idx = raw.rfind(_META_SEP)
        if idx == -1:
            return 0, None, url
        meta = raw[idx + len(_META_SEP):].decode('utf-8', 'replace').strip()
        final_url, _, code = meta.rpartition(' ')
        status = int(code) if code.isdigit() else 0
        body = raw[:idx]
        html = _decode_html(body) if body else None
        return status, html, (final_url or url)
    except Exception:
        return 0, None, url


def team_links(html, base_url):
    """站內連結中，像團隊／律師介紹頁的，去重後回前 MAX_SUBPAGES 個"""
    host = urlparse(base_url).netloc.lower().removeprefix('www.')
    seen, hinted, others = set(), [], []
    for href, inner in LINK_RE.findall(html):
        href = href.strip()
        if href.lower().startswith(('mailto:', 'tel:', 'javascript:', 'line:')):
            continue
        full = urljoin(base_url, href)
        p = urlparse(full)
        if p.scheme not in ('http', 'https'):
            continue
        if p.netloc.lower().removeprefix('www.') != host:
            continue
        if re.search(r'\.(jpg|jpeg|png|gif|pdf|zip|docx?|xlsx?|mp4)$', p.path, re.I):
            continue
        key = (p.path.rstrip('/'), p.query)
        if key in seen or key == ('', ''):
            continue
        seen.add(key)
        text = html_mod.unescape(TAG_RE.sub('', inner))
        (hinted if TEAM_HINT_RE.search(text) or TEAM_HINT_RE.search(p.path) else others).append(full)
    return hinted[:MAX_SUBPAGES]


def roster_hits(names, text):
    return sum(1 for n in names if n in text)


# ---------- 單所檢查 ----------
def check(row, roster, blocklist):
    """回 dict：health_status / health_http_status / roster_match / roster_hit_count / roster_hit_url"""
    firm = row['firm_name']
    url = row['website_url']
    names = roster.get(firm.replace(' ', ''), [])
    out = {'health_status': None, 'health_http_status': None, 'roster_match': 'none',
           'roster_hit_count': 0, 'roster_total': len(names), 'roster_hit_url': None}

    home = homepage_of(url)
    if not home:
        out['health_status'] = 'unreachable'
        return out
    status, html, final_url = fetch(home)
    out['health_http_status'] = status
    if status == 0:
        out['health_status'] = 'unreachable'
        return out
    if status in BLOCKED_CODES:
        out['health_status'] = 'blocked'
        return out
    if status >= 400 or not html:
        out['health_status'] = 'http_error'
        return out
    final_home = homepage_of(final_url) or home
    if host_blocked(urlparse(final_home).netloc.lower(), blocklist):
        # 轉址到黃頁／平台／外國網域＝網域已易主或被收走
        out['health_status'] = 'name_missing'
        return out

    text = page_text(html)
    firm_ok = name_in_text(name_keys(firm), text)
    out['health_status'] = 'ok' if firm_ok else 'name_missing'

    # 名冊律師姓名比對：首頁 → 團隊類子頁
    hits, hit_url = roster_hits(names, text), final_home
    if names and hits == 0:
        for link in team_links(html, final_url):
            s2, h2, _ = fetch(link, timeout=15)
            if s2 >= 400 or s2 == 0 or not h2:
                continue
            n = roster_hits(names, page_text(h2))
            if n > hits:
                hits, hit_url = n, link
            if hits:
                break
    if hits:
        out.update(roster_match='lawyer_name', roster_hit_count=hits, roster_hit_url=hit_url[:500])
        # 首頁排版讓所名比對落空，但站上找得到本所律師 → 視為本所官網
        out['health_status'] = 'ok'
    elif firm_ok:
        out['roster_match'] = 'firm_only'
    return out


def load_roster():
    """{事務所名（去空白）: [律師姓名...]}，姓名至少 2 字"""
    rows = rest_get_all('moj_lawyers',
                        {'select': 'lic_no,name,office_normalized', 'office_normalized': 'not.is.null'},
                        'lic_no.asc')
    roster = defaultdict(set)
    for r in rows:
        office = (r.get('office_normalized') or '').strip()
        name = (r.get('name') or '').strip()
        if not office or len(name) < 2 or '?' in name:  # 名冊罕用字會匯出成 ?，不能拿來比對
            continue
        m = FIRM_KEY_RE.match(office)
        roster[(m.group(1) if m else office).replace(' ', '')].add(name)
    return {k: sorted(v) for k, v in roster.items()}


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
