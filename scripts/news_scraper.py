"""
法律新聞爬蟲
來源：Google News RSS + 法律媒體

搜尋關鍵字：律師事務所、法律市場、司法改革、律師公會
"""
import re
import xml.etree.ElementTree as ET
from datetime import datetime
from urllib.parse import quote
import requests
from bs4 import BeautifulSoup
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
}

# 搜尋關鍵字
SEARCH_QUERIES = [
    '律師事務所 台灣',
    '法律市場 台灣',
    '律師公會',
    '司法改革',
    '法律科技 LegalTech 台灣',
]


def fetch_google_news_rss(query, max_results=20):
    """從 Google News RSS 取得新聞"""
    encoded_query = quote(query)
    url = f'https://news.google.com/rss/search?q={encoded_query}&hl=zh-TW&gl=TW&ceid=TW:zh-Hant'

    try:
        resp = requests.get(url, headers=HEADERS, timeout=30)
        resp.raise_for_status()
    except Exception as e:
        log(f'Google News RSS 請求失敗 ({query}): {e}')
        return []

    articles = []
    try:
        root = ET.fromstring(resp.content)
        items = root.findall('.//item')

        for item in items[:max_results]:
            title = item.findtext('title', '')
            link = item.findtext('link', '')
            pub_date = item.findtext('pubDate', '')
            source = item.findtext('source', '')

            # 清理標題 (Google News 會附來源)
            title = re.sub(r'\s*-\s*[^-]+$', '', title).strip()

            if not title or not link:
                continue

            # 解析日期
            published_at = None
            if pub_date:
                try:
                    published_at = datetime.strptime(
                        pub_date, '%a, %d %b %Y %H:%M:%S %Z'
                    ).isoformat()
                except ValueError:
                    pass

            articles.append({
                'title': title,
                'url': link,
                'source_name': source or 'Google News',
                'published_at': published_at,
                'content_snippet': None,
                'tags': [query],
            })
    except ET.ParseError as e:
        log(f'RSS 解析錯誤 ({query}): {e}')

    return articles


def deduplicate_articles(articles):
    """根據 URL 去重"""
    seen = set()
    unique = []
    for a in articles:
        if a['url'] not in seen:
            seen.add(a['url'])
            unique.append(a)
    return unique


def save_articles(sb, articles):
    """儲存新聞到 Supabase"""
    inserted = 0
    skipped = 0

    for article in articles:
        record = {
            'title': article['title'],
            'url': article['url'],
            'source_name': article['source_name'],
            'published_at': article.get('published_at'),
            'content_snippet': article.get('content_snippet'),
            'tags': article.get('tags', []),
        }

        try:
            sb.table('news_articles').upsert(
                record, on_conflict='url'
            ).execute()
            inserted += 1
        except Exception as e:
            if 'duplicate' in str(e).lower() or 'conflict' in str(e).lower():
                skipped += 1
            else:
                log(f'儲存失敗: {e}')
                skipped += 1

    return inserted, skipped


def main():
    sb = get_supabase()
    log_id = scrape_start(sb, 'news')

    try:
        all_articles = []

        for query in SEARCH_QUERIES:
            log(f'搜尋: {query}')
            articles = fetch_google_news_rss(query)
            log(f'  找到 {len(articles)} 篇')
            all_articles.extend(articles)
            polite_delay(2)

        # 去重
        unique = deduplicate_articles(all_articles)
        log(f'去重後共 {len(unique)} 篇 (原始 {len(all_articles)} 篇)')

        # 儲存
        inserted, skipped = save_articles(sb, unique)

        scrape_end(sb, log_id, status='success',
                   records_found=len(unique),
                   records_inserted=inserted,
                   records_updated=skipped)

        log(f'=== 新聞爬蟲完成: 新增 {inserted} 篇, 略過 {skipped} 篇 ===')

    except Exception as e:
        log(f'爬蟲錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise


if __name__ == '__main__':
    main()
