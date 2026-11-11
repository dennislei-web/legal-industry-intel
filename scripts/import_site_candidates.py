"""
匯入候選官網清單（人工或代理搜尋來的），逐筆用名冊佐證驗證後寫入 firm_websites

用法：python import_site_candidates.py candidates.tsv [更多 tsv ...]
  tsv：UTF-8、Tab 分隔，欄位＝事務所名、網址（NONE＝沒找到）、依據（可省略）

每筆用 website_verify.assess_website 驗證：
  有名冊佐證（律師姓名／地址電話信箱／標題即本所）→ verified=true
  連得上但沒佐證 → 存網址、verified=false、review_status='pending'（備註帶來源依據）
  連不上／黑名單／已被別家占用／該所已有驗證官網 → 略過

環境變數：DRY_RUN=true 只印不寫
"""
import io
import os
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from recheck_firm_websites import load_roster, log, rest_get_all, rest_patch
from website_verify import assess_website, title_names_firm

DRY_RUN = os.environ.get('DRY_RUN', 'false').lower() == 'true'


def _key(url):
    """同一網站的比對鍵：不分 http/https、www、結尾斜線"""
    u = (url or '').lower().rstrip('/')
    for p in ('https://', 'http://'):
        if u.startswith(p):
            u = u[len(p):]
    return u.removeprefix('www.')


def main(paths):
    cands = {}
    for p in paths:
        with io.open(p, encoding='utf-8-sig') as f:
            for line in f:
                parts = [x.strip() for x in line.rstrip('\n').split('\t')]
                if len(parts) < 2 or not parts[1].lower().startswith('http'):
                    continue
                cands[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else '')
    blocklist = {r['domain'] for r in rest_get_all('firm_website_blocklist', {'select': 'domain'}, 'domain.asc')}
    roster = load_roster()
    rows = rest_get_all('firm_websites', {'select': 'id,firm_name,website_url,verified'}, 'id.asc')
    by_name = {r['firm_name']: r for r in rows}
    holder = {}
    for r in rows:
        if r.get('verified') and r.get('website_url'):
            holder.setdefault(_key(r['website_url']), []).append(r)
    taken = set(holder)
    log(f'候選 {len(cands)} 筆（DRY_RUN={DRY_RUN}）')

    def run(item):
        name, (url, basis) = item
        row = by_name.get(name)
        if not row:
            return name, url, basis, None, None, 'firm_websites 沒有這間'
        if row.get('verified'):
            return name, url, basis, row, None, '已有驗證官網'
        lawyers = roster.get(name.replace(' ', ''), [])
        return name, url, basis, row, (assess_website(url, name, lawyers, blocklist), lawyers), None

    now = datetime.now(timezone.utc).isoformat()
    stat = Counter()
    with ThreadPoolExecutor(8) as ex:
        for name, url, basis, row, res, skip in ex.map(run, cands.items()):
            if skip:
                stat['略過'] += 1
                log(f'  略過 {name}：{skip}')
                continue
            a, lawyers = res
            if a['status'] == 0 or a['status'] >= 400 or not a['final_home']:
                stat['連不上'] += 1
                log(f'  連不上 {name} | {url} | HTTP {a["status"]}')
                continue
            if a['blocked_host']:
                stat['黑名單'] += 1
                log(f'  黑名單 {name} | {url}')
                continue
            home = a['final_home']
            ev = a['evidence']
            ok = ev in ('lawyer_name', 'contact') or (ev == 'title' and a['firm_ok'])
            hkey = _key(home)
            if hkey in taken:
                holders = holder.get(hkey, [])
                # 同一網站目前配給別家。常見情形：網站是這間（多人所）的，卻被配給站上某位律師
                # 另外登錄的「某某律師事務所」。首頁標題就是本所且有名冊佐證 → 改配給本所。
                if ok and a['firm_ok'] and title_names_firm(name, a['title'], '') and holders:
                    for h in holders:
                        log(f'  改配：{home} 原配 {h["firm_name"]} → {name}')
                        if not DRY_RUN:
                            rest_patch('firm_websites', {'id': f'eq.{h["id"]}'}, {
                                'verified': False, 'review_status': 'rejected', 'reviewed_at': now,
                                'review_note': f'網站屬 {name}（首頁標題為該所）；本所為站上律師另登錄的所名'[:300]})
                    holder[hkey] = []
                    stat['改配'] += 1
                else:
                    stat['已被別家占用'] += 1
                    log(f'  已被別家占用 {name} | {home}（現配 {"、".join(h["firm_name"] for h in holders)}）')
                    continue
            body = {'website_url': home, 'website_title': a['title'], 'website_scraped': True, 'scraped_at': now,
                    'verified_at': now, 'health_status': 'ok' if (a['firm_ok'] or ok) else 'name_missing',
                    'health_http_status': a['status'], 'health_checked_at': now, 'fail_streak': 0,
                    'roster_total': len(lawyers), 'roster_hit_count': len(a['signals']),
                    'roster_hit_url': (a['hit_url'] or '')[:500] or None, 'auto_unverified_at': None}
            if ok:
                taken.add(hkey)
                body.update(verified=True, roster_match=ev, review_status=None,
                            review_note=('候選匯入：' + basis)[:300], reviewed_at=None)
                stat['通過'] += 1
            else:
                body.update(verified=False, roster_match='firm_only' if a['firm_ok'] else 'none',
                            review_status='pending', review_note=('候選匯入、無名冊佐證：' + basis)[:300],
                            reviewed_at=now)
                stat['待審'] += 1
            log(f'  {"✓" if ok else "？"} {name}（{len(lawyers)} 人）→ {home} [{ev or "無佐證"}] {a["title"] or ""}'[:170])
            if not DRY_RUN:
                rest_patch('firm_websites', {'id': f'eq.{row["id"]}'}, body)
    log(f'結果：{dict(stat)}')


if __name__ == '__main__':
    if sys.platform == 'win32':
        sys.stdout.reconfigure(encoding='utf-8')
    main(sys.argv[1:])
