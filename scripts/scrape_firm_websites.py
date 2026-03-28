"""
事務所官網爬蟲
從 firm_websites 表取出尚未搜尋的事務所，用 Google 搜尋找到官網 URL。
每批處理 BATCH_SIZE 間（預設 30），避免被 Google 封鎖。
"""
import os
import re
import time
import requests
from bs4 import BeautifulSoup
from urllib.parse import urlparse, unquote
from utils import get_supabase, log

BATCH_SIZE = int(os.environ.get('BATCH_SIZE', '30'))

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
}

# 排除的網域（非官網）
EXCLUDE_DOMAINS = [
    'facebook.com', 'linkedin.com', 'twitter.com', 'instagram.com',
    'youtube.com', 'wikipedia.org', 'ptt.cc', 'dcard.tw',
    'lawsnote.com', 'law.moj.gov.tw', 'judicial.gov.tw',
    'google.com', 'maps.google', 'plus.google',
    '104.com.tw', '1111.com.tw', 'yes123.com.tw',
    'findlaw.com.tw', 'legalaid.gov.tw',
]


def search_google(query):
    """用 Google 搜尋，回傳前 5 個結果的 URL 和標題"""
    url = 'https://www.google.com/search'
    params = {'q': query, 'hl': 'zh-TW', 'num': 10}

    try:
        resp = requests.get(url, params=params, headers=HEADERS, timeout=15)
        resp.raise_for_status()
        soup = BeautifulSoup(resp.text, 'html.parser')

        results = []
        for g in soup.select('div.g, div[data-sokoban-container]'):
            link = g.find('a', href=True)
            if not link:
                continue
            href = link['href']
            # 過濾 Google 內部連結
            if href.startswith('/search') or href.startswith('#'):
                continue
            # 提取標題
            title_el = g.find('h3')
            title = title_el.get_text(strip=True) if title_el else ''
            # 提取描述
            desc_el = g.find('div', class_=re.compile('VwiC3b|IsZvec|s3v9rd'))
            desc = desc_el.get_text(strip=True) if desc_el else ''

            results.append({'url': href, 'title': title, 'description': desc})

        return results
    except Exception as e:
        log(f'  Google 搜尋失敗: {e}')
        return []


def is_likely_official(url, firm_name):
    """判斷 URL 是否可能是官網"""
    domain = urlparse(url).netloc.lower()

    # 排除已知非官網
    for excl in EXCLUDE_DOMAINS:
        if excl in domain:
            return False

    # 優先 .tw 網域
    # 有 law, legal, lawyer 等關鍵字更好
    return True


def find_firm_website(firm_name):
    """搜尋事務所官網"""
    # 嘗試搜尋「事務所名 官網」
    results = search_google(f'{firm_name} 律師')

    if not results:
        return None

    # 找到第一個可能的官網
    for r in results:
        if is_likely_official(r['url'], firm_name):
            return {
                'website_url': r['url'],
                'website_title': r['title'][:200] if r['title'] else None,
                'description': r['description'][:500] if r['description'] else None,
            }

    return None


def main():
    sb = get_supabase()

    # 取得未搜尋的事務所
    resp = sb.table('firm_websites') \
        .select('id, firm_name') \
        .eq('website_scraped', False) \
        .is_('website_url', 'null') \
        .limit(BATCH_SIZE) \
        .execute()

    firms = resp.data
    total = len(firms)
    log(f'本批次待搜尋: {total} 間事務所')

    if total == 0:
        log('所有事務所官網已搜尋完成！')
        return

    found = 0
    errors = 0

    for idx, firm in enumerate(firms, 1):
        name = firm['firm_name']
        if idx % 10 == 0 or idx == 1:
            log(f'進度: {idx}/{total} - 搜尋: {name}')

        try:
            result = find_firm_website(name)

            update = {'website_scraped': True, 'scraped_at': 'now()'}
            if result:
                update['website_url'] = result['website_url']
                update['website_title'] = result['website_title']
                update['description'] = result['description']
                found += 1

            sb.table('firm_websites') \
                .update(update) \
                .eq('id', firm['id']) \
                .execute()

        except Exception as e:
            log(f'  錯誤 {name}: {e}')
            errors += 1

        # 禮貌延遲 3-5 秒避免被 Google 封鎖
        time.sleep(3 + (idx % 3))

    log(f'完成！找到官網: {found}/{total}, 錯誤: {errors}')

    # 顯示剩餘
    remaining = sb.table('firm_websites') \
        .select('id', count='exact') \
        .eq('website_scraped', False) \
        .execute()
    log(f'剩餘未搜尋: {remaining.count or 0} 間')


if __name__ == '__main__':
    main()
