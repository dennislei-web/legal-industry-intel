"""
用名冊信箱網域找官網（不經搜尋引擎，不會被 DDG 封）

法務部名冊上律師登記的信箱，若不是 gmail／hinet 這類公用信箱，網域通常就是事務所官網。
對每一間「還沒有驗證通過官網」的法律事務所：
  1. 收集名冊上該所律師的自有信箱網域（依使用人數排序）
  2. 逐一試 https://網域/、https://www.網域/
  3. 用 website_verify.assess_website 驗證：首頁要有所名（信箱網域本身不算數，
     律師可能用前東家或學校的信箱），且該首頁沒被別家占用、不在黑名單
通過 → 寫入 firm_websites（verified=true）。

環境變數：
  DRY_RUN=false   true＝只印不寫
  MIN_LAWYERS=1   只處理律師數 ≥ N 的所
  WORKERS=8
"""
import os
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from recheck_firm_websites import load_roster, log, rest_get_all, rest_patch
from website_verify import FREE_MAIL_RE, assess_website, title_names_firm

DRY_RUN = os.environ.get('DRY_RUN', 'false').lower() == 'true'
MIN_LAWYERS = int(os.environ.get('MIN_LAWYERS', '1') or 1)
WORKERS = int(os.environ.get('WORKERS', '8') or 8)
# 學校／政府／公會的信箱不是事務所官網
SKIP_DOMAIN_SUFFIX = ('.edu.tw', '.gov.tw', '.edu', '.gov', '.org.tw', '.ac.jp', '.edu.cn')


def email_domains(lawyers):
    c = Counter()
    for l in lawyers:
        em = (l.get('email') or '').strip().lower()
        if '@' not in em:
            continue
        dom = em.rsplit('@', 1)[-1].strip().strip('.')
        if not dom or '.' not in dom or FREE_MAIL_RE.search(dom) or dom.endswith(SKIP_DOMAIN_SUFFIX):
            continue
        c[dom] += 1
    return [d for d, _ in c.most_common(3)]


def main():
    blocklist = {r['domain'] for r in rest_get_all('firm_website_blocklist', {'select': 'domain'}, 'domain.asc')}
    roster = load_roster()
    rows = rest_get_all('firm_websites', {'select': 'id,firm_name,website_url,verified,review_status'}, 'id.asc')
    taken = {(r['website_url'] or '').rstrip('/').lower() for r in rows if r.get('verified') and r.get('website_url')}
    manual = {r['firm_name'] for r in rest_get_all('firm_profiles', {'select': 'id,firm_name,website_url',
                                                                    'website_url': 'not.is.null'}, 'id.asc')
              if (r.get('website_url') or '').strip()}

    todo = []
    for r in rows:
        name = r['firm_name']
        if r.get('verified') or name in manual or not ('法律事務所' in name or '律師事務所' in name):
            continue
        lawyers = roster.get(name.replace(' ', ''), [])
        if len(lawyers) < MIN_LAWYERS:
            continue
        doms = email_domains(lawyers)
        if doms:
            todo.append((r, lawyers, doms))
    log(f'無官網且名冊有自有信箱網域：{len(todo)} 間（MIN_LAWYERS={MIN_LAWYERS}，DRY_RUN={DRY_RUN}）')

    def probe(item):
        r, lawyers, doms = item
        for dom in doms:
            for url in (f'https://{dom}/', f'https://www.{dom}/'):
                a = assess_website(url, r['firm_name'], lawyers, blocklist)
                if a['status'] == 0 or a['status'] >= 400 or a['blocked_host'] or not a['final_home']:
                    continue
                # 「信箱網域＝官網網域」在這裡必然成立，不能當佐證
                # （試跑抓到：有果律師事務所的律師用餐飲人資系統公司的信箱）
                strong = (a['signals'] - {'email_domain'}) or title_names_firm(r['firm_name'], a['title'], '')
                if a['firm_ok'] and strong:
                    return r, lawyers, a
                break  # 這個網域連得上但不是本所 → 不必再試 www
        return r, lawyers, None

    now = datetime.now(timezone.utc).isoformat()
    found, dup, by_size = 0, 0, Counter()
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for i, (r, lawyers, a) in enumerate(ex.map(probe, todo), 1):
            if a:
                key = a['final_home'].rstrip('/').lower()
                if key in taken:
                    dup += 1   # 同一首頁已配給別家（合署、分所、改名前後）→ 不重複配
                else:
                    taken.add(key)
                    found += 1
                    n = len(lawyers)
                    by_size['5+' if n >= 5 else '2-4' if n >= 2 else '1'] += 1
                    log(f'  ✓ {r["firm_name"]}（{n} 人）→ {a["final_home"]} [{a["evidence"]}] {a["title"] or ""}'[:160])
                    if not DRY_RUN:
                        rest_patch('firm_websites', {'id': f'eq.{r["id"]}'}, {
                            'website_url': a['final_home'], 'website_title': a['title'],
                            'website_scraped': True, 'scraped_at': now,
                            'verified': True, 'verified_at': now, 'auto_unverified_at': None,
                            'health_status': 'ok', 'health_http_status': a['status'],
                            'health_checked_at': now, 'fail_streak': 0,
                            'roster_match': a['evidence'], 'roster_hit_count': len(a['signals']),
                            'roster_total': len(lawyers), 'roster_hit_url': (a['hit_url'] or '')[:500] or None,
                            'review_status': None, 'review_note': '由名冊信箱網域發現', 'reviewed_at': None,
                        })
            if i % 100 == 0:
                log(f'  [{i}/{len(todo)}] 找到 {found}，{time.time() - t0:.0f}s')
    log(f'完成：{len(todo)} 間中找到 {found} 間（{dict(by_size)}），另 {dup} 間的網域已配給別家')


if __name__ == '__main__':
    if sys.platform == 'win32':
        sys.stdout.reconfigure(encoding='utf-8')
    main()
