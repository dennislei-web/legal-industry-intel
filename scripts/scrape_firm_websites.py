"""
事務所官網爬蟲 v2
- 自動從 moj_firm_statistics() sync 所有事務所進 firm_websites
- 支援 BATCH_SIZE=0 代表跑所有未爬過的
- 改善命中率：多重 query 策略 + 評分機制
- 延遲可控 (SCRAPE_DELAY)
"""
import os
import re
import time
import requests
from bs4 import BeautifulSoup
from urllib.parse import urlparse, unquote
from utils import get_supabase, log

BATCH_SIZE = int(os.environ.get('BATCH_SIZE', '0'))  # 0 = 全部
SCRAPE_DELAY = float(os.environ.get('SCRAPE_DELAY', '1.8'))  # 秒
RETRY_MISSING = os.environ.get('RETRY_MISSING', 'false').lower() == 'true'  # 重試未找到官網的

# Google Custom Search API (優先使用，命中率遠高於 DDG)
GOOGLE_API_KEY = os.environ.get('GOOGLE_API_KEY', '').strip()
GOOGLE_CSE_ID = os.environ.get('GOOGLE_CSE_ID', '').strip()
GOOGLE_DAILY_LIMIT = 100  # 免費額度
_google_used_today = 0

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


def search_google_cse(query, num=5):
    """Google Custom Search API。免費 100/日，超過會回 429。"""
    global _google_used_today
    if not GOOGLE_API_KEY or not GOOGLE_CSE_ID:
        return None  # 未設定，fallback
    if _google_used_today >= GOOGLE_DAILY_LIMIT:
        return None  # 額度用完，fallback
    try:
        url = 'https://www.googleapis.com/customsearch/v1'
        params = {
            'key': GOOGLE_API_KEY,
            'cx': GOOGLE_CSE_ID,
            'q': query,
            'num': num,
            'lr': 'lang_zh-TW',  # 偏好繁中
            'gl': 'tw',  # 地區：台灣
        }
        resp = requests.get(url, params=params, timeout=15)
        _google_used_today += 1
        if resp.status_code == 429:
            log(f'  Google CSE 額度用完 (已用 {_google_used_today})')
            return None
        if resp.status_code != 200:
            log(f'  Google CSE HTTP {resp.status_code}: {resp.text[:200]}')
            return []
        data = resp.json()
        results = []
        for item in data.get('items', []):
            results.append({
                'url': item.get('link', ''),
                'title': item.get('title', ''),
                'description': item.get('snippet', ''),
            })
        return results
    except Exception as e:
        log(f'  Google CSE 錯誤: {e}')
        return []


def search_duckduckgo(query, retries=2):
    """用 DuckDuckGo HTML 版搜尋"""
    url = 'https://html.duckduckgo.com/html/'
    for attempt in range(retries):
        try:
            resp = requests.post(url, data={'q': query}, headers=HEADERS, timeout=15)
            if resp.status_code != 200:
                time.sleep(1)
                continue
            soup = BeautifulSoup(resp.text, 'html.parser')
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
    return []


def score_candidate(url, title, description, firm_name):
    """評分一個搜尋結果是否像官網 (0-100)"""
    domain = urlparse(url).netloc.lower()
    # 排除黑名單
    for excl in EXCLUDE_DOMAINS:
        if excl in domain:
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


def find_firm_website(firm_name):
    """搜尋事務所官網，優先 Google CSE，fallback DDG。"""
    clean = firm_name.strip()
    # 去掉「國際/聯合/商務」後的主名（用於輔助判斷，不用來搜尋）
    # 搜尋策略：用完整名稱，避免「宏光展」→ 一堆無關結果
    queries = [
        f'{clean} 官網',
        f'{clean} 律師',
        f'"{clean}"',
        clean,
    ]

    all_candidates = []
    seen_urls = set()

    for q in queries:
        # 優先 Google，失敗才 fallback DDG
        results = search_google_cse(q) if GOOGLE_API_KEY else None
        if results is None:  # Google 未設定或額度用完
            results = search_duckduckgo(q)

        for i, r in enumerate(results or []):
            if r['url'] in seen_urls:
                continue
            seen_urls.add(r['url'])
            s = score_candidate(r['url'], r['title'], r['description'], firm_name)
            # Google 結果的 top 3 額外加分（Google 排名已經是相關性加權）
            if GOOGLE_API_KEY and i < 3:
                s += (3 - i) * 5  # top1 +15, top2 +10, top3 +5
            if s > 0:
                all_candidates.append((s, r))

        # 已有高信心候選就停
        if all_candidates and max(c[0] for c in all_candidates) >= 50:
            break
        time.sleep(0.3)

    if not all_candidates:
        return None
    all_candidates.sort(key=lambda x: -x[0])
    best_score, best = all_candidates[0]

    # 門檻：Google 結果用較寬鬆的 20，DDG 保留較嚴格的 25
    threshold = 20 if GOOGLE_API_KEY else 25
    if best_score < threshold:
        return None

    return {
        'website_url': best['url'],
        'website_title': (best['title'] or '')[:200],
        'description': (best['description'] or '')[:500],
        'score': best_score,
    }


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


def main():
    sb = get_supabase()

    # Step 1: sync MOJ 事務所到 firm_websites
    sync_moj_firms_to_table(sb)

    # Step 2: 取得待爬的事務所
    log(f'\n=== 爬取官網 ===')
    query = sb.table('firm_websites').select('id, firm_name')
    if RETRY_MISSING:
        # 爬已掃過但沒找到官網的
        query = query.is_('website_url', 'null')
    else:
        # 只爬從未掃過的
        query = query.eq('website_scraped', False)

    if BATCH_SIZE > 0:
        query = query.limit(BATCH_SIZE)
    else:
        # Supabase 默認 limit 1000，要手動分頁
        query = query.limit(10000)

    resp = query.execute()
    firms = resp.data or []
    total = len(firms)
    log(f'本批次待爬: {total} 間 (BATCH_SIZE={BATCH_SIZE}, RETRY_MISSING={RETRY_MISSING})')

    if total == 0:
        log('無待爬事務所')
        return

    found = 0
    errors = 0
    t0 = time.time()

    for idx, firm in enumerate(firms, 1):
        name = firm['firm_name']
        try:
            result = find_firm_website(name)
            update = {'website_scraped': True, 'scraped_at': 'now()'}
            if result:
                update['website_url'] = result['website_url']
                update['website_title'] = result['website_title']
                update['description'] = result['description']
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
