"""
事務所官網爬蟲 v3
- 自動從 moj_firm_statistics() sync 所有事務所進 firm_websites
- 支援 BATCH_SIZE=0 代表跑所有未爬過的
- 改善命中率：多重 query 策略 + 評分機制
- 延遲可控 (SCRAPE_DELAY)
- v3（2026-07）：寫入前驗證 — 候選 URL 正規化為網域首頁、首頁必須含所名、
  網域過 DB blocklist（firm_website_blocklist）與外國 TLD、拒收已被
  其他事務所占用的 URL；通過才寫入並標 verified=true。
  背景：v2 直接存搜尋第一名，混進大量黃頁/新聞/公會/他所網頁（見 migration 042/065）
"""
import base64
import os
import re
import subprocess
import time
import requests
from bs4 import BeautifulSoup
from urllib.parse import urlparse, unquote, quote
from utils import get_supabase, log
from website_verify import load_blocklist, host_blocked, homepage_of, verify_firm_website

BATCH_SIZE = int(os.environ.get('BATCH_SIZE', '0'))  # 0 = 全部
SCRAPE_DELAY = float(os.environ.get('SCRAPE_DELAY', '1.8'))  # 秒
RETRY_MISSING = os.environ.get('RETRY_MISSING', 'false').lower() == 'true'  # 重試未找到官網的
SEARCH_ENGINE = os.environ.get('SEARCH_ENGINE', 'ddg').lower()  # ddg | bing
# 注意：bing 對無 cookie 爬蟲常回 200 但塞誘餌垃圾結果（2026-08 實測，CJK 尤甚），
# 寫入靠首頁驗證擋住不會污染，但等於搜不到；長跑請用 ddg＋低請求率。
QUERIES_PER_FIRM = int(os.environ.get('QUERIES_PER_FIRM', '3'))  # 每家最多發幾個 query（1=僅「所名 官網」，降請求率防限流）

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
}

EXCLUDE_DOMAINS = [
    'facebook.com', 'linkedin.com', 'twitter.com', 'x.com', 'instagram.com',
    'youtube.com', 'wikipedia.org', 'ptt.cc', 'dcard.tw', 'threads.net',
    'lawsnote.com', 'law.moj.gov.tw', 'judicial.gov.tw', 'moj.gov.tw',
    'google.com', 'maps.google', 'plus.google', 'goo.gl',
    '104.com.tw', '1111.com.tw', 'yes123.com.tw', 'cakeresume.com', 'jobs.yahoo',
    'findlaw.com.tw', 'legalaid.gov.tw', 'lawchina.com.cn',
    'duckduckgo.com', 'bing.com', 'yahoo.com',
    'twincn.com', 'moneydj.com', 'businesstoday', 'businessweekly',
    'pchome.com.tw', 'shopping.', 'yongqing.com', 'yahoo.com.tw',
    'eprice.com.tw', 'xuite.net', 'blogspot.com', 'pixnet.net',
]

LEGAL_KEYWORDS = ['law', 'legal', 'lawyer', 'attorney', 'firm', 'law-firm', 'lawfirm', '法律', '律師', '事務所']


# 連續失敗的 DDG 請求數（成功回 200 即歸零）。連續大量失敗＝被限流/封鎖，
# 繼續跑只會把整個待爬池空轉標記（2026-08 GH runner 與本機都踩過）。
# 主迴圈據此進入冷卻等待，多次冷卻仍失敗才中止。
DDG_FAIL_STREAK = 0
DDG_FAIL_ABORT = int(os.environ.get('DDG_FAIL_ABORT', '12'))
DDG_COOLDOWN_MIN = int(os.environ.get('DDG_COOLDOWN_MIN', '20'))   # 每次冷卻分鐘數
DDG_MAX_COOLDOWNS = int(os.environ.get('DDG_MAX_COOLDOWNS', '8'))  # 冷卻次數上限


def _ddg_fetch(query):
    """用系統 curl 打 DDG。python requests 的 TLS 指紋會被 DDG 回 202 挑戰頁
    （2026-08 實測），真 curl 的指紋則正常回 200。query 先 percent-encode，
    argv 保持純 ASCII（Windows curl 對非 ASCII argv 會做 ANSI 轉換毀掉 UTF-8）。
    回傳 (http_status, html)。"""
    data = 'q=' + quote(query.encode('utf-8'), safe='')
    r = subprocess.run(
        ['curl', '-s', '-m', '15', '-X', 'POST', 'https://html.duckduckgo.com/html/',
         '--data', data,
         '-H', f"User-Agent: {HEADERS['User-Agent']}",
         '-H', f"Accept-Language: {HEADERS['Accept-Language']}",
         '-w', '\n%{http_code}'],
        capture_output=True, timeout=25)
    out = r.stdout.decode('utf-8', 'replace')
    body, _, code = out.rpartition('\n')
    return (int(code) if code.strip().isdigit() else 0), body


def search_duckduckgo(query, retries=2):
    """用 DuckDuckGo HTML 版搜尋"""
    global DDG_FAIL_STREAK
    for attempt in range(retries):
        try:
            status, html = _ddg_fetch(query)
            if status != 200:
                if attempt == retries - 1:
                    log(f'  DDG 非 200: HTTP {status}')
                time.sleep(1)
                continue
            DDG_FAIL_STREAK = 0
            soup = BeautifulSoup(html, 'html.parser')
            results = []
            for r in soup.select('.result'):
                link = r.find('a', class_='result__a', href=True)
                if not link:
                    continue
                href = link['href']
                if 'uddg=' in href:
                    href = unquote(href.split('uddg=')[-1].split('&')[0])
                title = link.get_text(strip=True)
                desc_el = r.find('a', class_='result__snippet')
                desc = desc_el.get_text(strip=True) if desc_el else ''
                if href.startswith('http'):
                    results.append({'url': href, 'title': title, 'description': desc})
            return results
        except Exception as e:
            if attempt == retries - 1:
                log(f'  DDG 失敗: {e}')
            time.sleep(1)
    DDG_FAIL_STREAK += 1
    return []


def _bing_fetch(query):
    """用系統 curl 打 Bing 搜尋，回傳 (http_status, html)。argv 保持純 ASCII。"""
    url = ('https://www.bing.com/search?q=' + quote(query.encode('utf-8'), safe='')
           + '&setlang=zh-TW&count=10')
    r = subprocess.run(
        ['curl', '-s', '-m', '15', url,
         '-H', f"User-Agent: {HEADERS['User-Agent']}",
         '-H', f"Accept-Language: {HEADERS['Accept-Language']}",
         '-w', '\n%{http_code}'],
        capture_output=True, timeout=25)
    out = r.stdout.decode('utf-8', 'replace')
    body, _, code = out.rpartition('\n')
    return (int(code) if code.strip().isdigit() else 0), body


def _bing_real_url(href):
    """Bing 結果連結是 bing.com/ck/a 轉址，真實 URL 以 base64url 藏在 u=a1<b64>"""
    if 'bing.com/ck/' not in href:
        return href
    m = re.search(r'[?&]u=a1([A-Za-z0-9_-]+)', href)
    if not m:
        return None
    s = m.group(1)
    s += '=' * (-len(s) % 4)
    try:
        return base64.urlsafe_b64decode(s).decode('utf-8', 'replace')
    except Exception:
        return None


def search_bing(query, retries=2):
    """用 Bing 搜尋（DDG 被限流時的替代引擎）。共用 DDG_FAIL_STREAK 計數。"""
    global DDG_FAIL_STREAK
    for attempt in range(retries):
        try:
            status, html = _bing_fetch(query)
            soup = BeautifulSoup(html, 'html.parser') if status == 200 else None
            items = soup.select('li.b_algo') if soup else []
            # Bing 被反爬時常回 200 但無結果區塊，視同失敗
            if status != 200 or (not items and 'b_algo' not in html):
                if attempt == retries - 1:
                    log(f'  Bing 失敗: HTTP {status}, algo 區塊 {len(items)}')
                time.sleep(1)
                continue
            DDG_FAIL_STREAK = 0
            results = []
            for li in items:
                h2a = li.select_one('h2 a')
                if not h2a:
                    continue
                href = _bing_real_url(h2a.get('href', ''))
                if not href or not href.startswith('http'):
                    continue
                title = h2a.get_text(strip=True)
                p = li.select_one('.b_caption p') or li.select_one('p')
                desc = p.get_text(strip=True) if p else ''
                results.append({'url': href, 'title': title, 'description': desc})
            return results
        except Exception as e:
            if attempt == retries - 1:
                log(f'  Bing 失敗: {e}')
            time.sleep(1)
    DDG_FAIL_STREAK += 1
    return []


def search_web(query):
    """依 SEARCH_ENGINE 分派搜尋引擎"""
    return search_bing(query) if SEARCH_ENGINE == 'bing' else search_duckduckgo(query)


def _probe_fetch():
    """探測目前引擎是否可用"""
    return _bing_fetch('law firm') if SEARCH_ENGINE == 'bing' else _ddg_fetch('law firm')


def score_candidate(url, title, description, firm_name, blocklist=None):
    """評分一個搜尋結果是否像官網 (0-100)"""
    domain = urlparse(url).netloc.lower()
    # 排除黑名單（內建清單 + DB firm_website_blocklist + 外國 TLD）
    for excl in EXCLUDE_DOMAINS:
        if excl in domain:
            return -1
    if blocklist is not None and host_blocked(domain, blocklist):
        return -1
    # 基礎分數
    score = 0
    full_text = (title + ' ' + description + ' ' + domain).lower()

    # 子網域深度（越短越好，代表是主站）
    parts = domain.split('.')
    if len(parts) <= 3:
        score += 15
    # .tw / .com.tw 網域加分
    if domain.endswith('.tw') or '.com.tw' in domain:
        score += 20
    # 網域含法律相關關鍵字
    domain_no_tld = domain.split('.')[0]
    for kw in ['law', 'legal', 'lawyer', 'attorney', 'firm']:
        if kw in domain_no_tld:
            score += 15
            break
    # Title 含事務所名稱（模糊比對：去除「法律事務所」後主名）
    clean_firm = re.sub(r'(國際|聯合|商務)?(法律|律師)事務所.*', '', firm_name).strip()
    if clean_firm and len(clean_firm) >= 2:
        if clean_firm in title:
            score += 30
        elif clean_firm in description:
            score += 15
        # 嘗試用主名字的 pinyin/英文對應（保底）
        if clean_firm.lower() in domain_no_tld:
            score += 20
    # 描述或標題含「事務所」「律師」「法律」
    if any(k in title for k in ['事務所', '律師', '法律', 'Law Firm', 'Attorneys']):
        score += 10
    if any(k in description for k in ['事務所', '律師', '法律']):
        score += 5
    return score


def find_firm_website(firm_name, blocklist, taken_urls):
    """搜尋事務所官網：多輪 query 評分排序後，逐一「首頁含所名」驗證，
    通過才回傳（URL 一律正規化為網域首頁；已被他所占用的首頁跳過）"""
    clean = firm_name.strip()
    queries = [
        f'{clean} 官網',
        f'"{clean}"',
        clean,
    ][:QUERIES_PER_FIRM]
    all_candidates = []
    seen_urls = set()
    for q in queries:
        for r in search_web(q):
            if r['url'] in seen_urls:
                continue
            seen_urls.add(r['url'])
            s = score_candidate(r['url'], r['title'], r['description'], firm_name, blocklist)
            if s > 0:
                all_candidates.append((s, r))
        if all_candidates and max(c[0] for c in all_candidates) >= 50:
            break  # 已有高信心候選
        time.sleep(0.5)
    if not all_candidates:
        return None
    all_candidates.sort(key=lambda x: -x[0])

    # 寫入前驗證：取前 3 名候選，逐一抓網域首頁確認含所名
    tried_homes = set()
    for score, cand in all_candidates[:3]:
        if score < 25:
            break  # 低分不驗，避免誤判
        home = homepage_of(cand['url'])
        if not home or home in tried_homes:
            continue
        tried_homes.add(home)
        ok, final_home, title = verify_firm_website(cand['url'], firm_name, blocklist)
        if not ok:
            continue
        if final_home in taken_urls:
            continue  # 同一首頁已配給別家 = 錯配/共用落地頁
        return {
            'website_url': final_home,
            'website_title': (title or cand['title'] or '')[:200],
            'description': (cand['description'] or '')[:500],
            'score': score,
        }
    return None


def sync_moj_firms_to_table(sb):
    """從 moj_firm_stats_cache 取所有事務所，缺的 INSERT 到 firm_websites"""
    log('=== Sync MOJ 事務所到 firm_websites ===')
    # 用 cache 表取代 RPC（避免超時）
    moj_firms = []
    start = 0
    while True:
        r = sb.table('moj_firm_stats_cache').select('firm_name').range(start, start + 999).execute()
        if not r.data or len(r.data) == 0:
            break
        moj_firms.extend(r.data)
        if len(r.data) < 1000:
            break
        start += 1000
    log(f'MOJ 事務所總數: {len(moj_firms)}')

    # 取現有 firm_websites（分頁取全部）
    existing = []
    es = 0
    while True:
        r = sb.table('firm_websites').select('firm_name').range(es, es + 999).execute()
        if not r.data or len(r.data) == 0:
            break
        existing.extend(r.data)
        if len(r.data) < 1000:
            break
        es += 1000
    existing_set = {e['firm_name'] for e in existing}
    log(f'現有 firm_websites: {len(existing_set)}')

    # 找缺的
    to_insert = []
    for f in moj_firms:
        name = f.get('firm_name')
        if not name or name in existing_set:
            continue
        to_insert.append({
            'firm_name': name,
            'website_scraped': False,
        })

    log(f'待新增: {len(to_insert)}')
    if to_insert:
        BATCH = 500
        for i in range(0, len(to_insert), BATCH):
            sb.table('firm_websites').insert(to_insert[i:i + BATCH]).execute()
            log(f'  已新增 {min(i + BATCH, len(to_insert))}/{len(to_insert)}')
    return len(to_insert)


def fetch_taken_urls(sb):
    """已配置給任一事務所的官網（避免同一首頁配多家）"""
    taken = set()
    start = 0
    while True:
        r = (sb.table('firm_websites').select('website_url')
               .not_.is_('website_url', 'null').range(start, start + 999).execute())
        if not r.data:
            break
        taken.update(x['website_url'] for x in r.data if x.get('website_url'))
        if len(r.data) < 1000:
            break
        start += 1000
    return taken


def main():
    sb = get_supabase()

    # Step 1: sync MOJ 事務所到 firm_websites
    sync_moj_firms_to_table(sb)

    blocklist = load_blocklist(sb)
    taken_urls = fetch_taken_urls(sb)
    log(f'blocklist 網域: {len(blocklist)}，已占用官網: {len(taken_urls)}')

    # Step 2: 取得待爬的事務所
    log(f'\n=== 爬取官網 ===')
    # PostgREST 伺服器端 max-rows=1000，.limit(10000) 會被靜默截斷，必須 .range() 分頁
    firms = []
    start = 0
    while True:
        query = sb.table('firm_websites').select('id, firm_name')
        if RETRY_MISSING:
            # 爬已掃過但沒找到官網的
            query = query.is_('website_url', 'null')
        else:
            # 只爬從未掃過的
            query = query.eq('website_scraped', False)
        r = query.order('id').range(start, start + 999).execute()
        batch = r.data or []
        firms.extend(batch)
        if len(batch) < 1000 or (BATCH_SIZE > 0 and len(firms) >= BATCH_SIZE):
            break
        start += 1000
    if BATCH_SIZE > 0:
        firms = firms[:BATCH_SIZE]
    total = len(firms)
    log(f'本批次待爬: {total} 間 (BATCH_SIZE={BATCH_SIZE}, RETRY_MISSING={RETRY_MISSING})')

    if total == 0:
        log('無待爬事務所')
        return

    found = 0
    errors = 0
    t0 = time.time()

    global DDG_FAIL_STREAK
    cooldowns = 0

    # 開跑前先確認 DDG 未在封鎖狀態（被擋時開跑只會空轉標記整個池）
    while True:
        try:
            probe_status, _ = _probe_fetch()
        except Exception:
            probe_status = 0
        if probe_status == 200:
            break
        cooldowns += 1
        if cooldowns > DDG_MAX_COOLDOWNS:
            log(f'✗ {SEARCH_ENGINE} 持續封鎖（HTTP {probe_status}），冷卻 {DDG_MAX_COOLDOWNS} 次仍未解，放棄本輪')
            return
        log(f'{SEARCH_ENGINE} 未解封（HTTP {probe_status}），冷卻 {DDG_COOLDOWN_MIN} 分鐘後重試'
            f'（{cooldowns}/{DDG_MAX_COOLDOWNS}）')
        time.sleep(DDG_COOLDOWN_MIN * 60)
    log(f'{SEARCH_ENGINE} 探測 OK，開始爬取')
    cooldowns = 0

    for idx, firm in enumerate(firms, 1):
        if DDG_FAIL_STREAK >= DDG_FAIL_ABORT:
            cooldowns += 1
            if cooldowns > DDG_MAX_COOLDOWNS:
                log(f'\n✗ DDG 連續失敗且冷卻 {DDG_MAX_COOLDOWNS} 次無效，中止本輪'
                    f'（已處理 {idx - 1}/{total}，命中 {found}）')
                break
            log(f'{SEARCH_ENGINE} 連續 {DDG_FAIL_STREAK} 次失敗（疑似被限流），冷卻 {DDG_COOLDOWN_MIN} 分鐘'
                f'（{cooldowns}/{DDG_MAX_COOLDOWNS}，進度 {idx - 1}/{total}）')
            time.sleep(DDG_COOLDOWN_MIN * 60)
            DDG_FAIL_STREAK = 0
        name = firm['firm_name']
        try:
            streak_before = DDG_FAIL_STREAK
            result = find_firm_website(name, blocklist, taken_urls)
            if result is None and DDG_FAIL_STREAK > streak_before:
                # 搜尋是「失敗」不是「查無」→ 不標 scraped，留給之後的輪次重試
                time.sleep(SCRAPE_DELAY)
                continue
            update = {'website_scraped': True, 'scraped_at': 'now()'}
            if result:
                update['website_url'] = result['website_url']
                update['website_title'] = result['website_title']
                update['description'] = result['description']
                update['verified'] = True
                update['verified_at'] = 'now()'
                taken_urls.add(result['website_url'])
                found += 1
                if idx % 20 == 0 or idx == 1:
                    log(f'  [{idx}/{total}] ✓ {name} → {result["website_url"][:70]} (score={result["score"]})')
            else:
                if idx % 50 == 0:
                    log(f'  [{idx}/{total}] - {name} (無命中)')
            sb.table('firm_websites').update(update).eq('id', firm['id']).execute()
        except Exception as e:
            errors += 1
            if errors < 10:
                log(f'  ✗ {name}: {e}')

        # DDG 恢復正常就重置冷卻計數（上限只針對「連續」冷卻無效）
        if DDG_FAIL_STREAK == 0:
            cooldowns = 0

        # 進度報告
        if idx % 100 == 0:
            elapsed = time.time() - t0
            rate = idx / elapsed
            eta_min = (total - idx) / rate / 60
            log(f'  [{idx}/{total}] 命中 {found} ({found/idx*100:.1f}%) rate={rate:.2f}/s ETA={eta_min:.1f}min')

        time.sleep(SCRAPE_DELAY)

    elapsed = time.time() - t0
    log(f'\n=== 完成 ===')
    log(f'處理: {total} 間，找到: {found} ({found/total*100:.1f}%)，錯誤: {errors}')
    log(f'耗時: {elapsed/60:.1f} 分鐘')


if __name__ == '__main__':
    main()
