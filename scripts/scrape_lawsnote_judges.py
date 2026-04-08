"""
Lawsnote 法官頁面爬蟲
來源: https://page.lawsnote.com
產出: lawsnote_judges 表

用法:
  python scrape_lawsnote_judges.py              # 爬全部
  python scrape_lawsnote_judges.py --limit 50   # 測試模式
"""
import re
import argparse
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

SCRAPER_NAME = 'lawsnote_judges'

# Lawsnote 法官列表頁面（需確認實際 URL）
# 律師頁面是 page.lawsnote.com/page/{id}
# 法官頁面可能是 page.lawsnote.com/judge/{id} 或類似結構
BASE_URL = 'https://page.lawsnote.com'

# 法院名稱正規化
def normalize_court(name):
    if not name:
        return name
    return name.replace('台灣', '臺灣').replace('　', '').strip()


def discover_judge_ids(page, limit=None):
    """
    探索 Lawsnote 上的法官頁面 ID

    TODO: 需要確認 Lawsnote 法官頁面的實際 URL 結構
    可能的路徑:
    1. page.lawsnote.com/judge - 法官列表
    2. lawsnote.com 搜尋 → 篩選法官
    3. page.lawsnote.com 導航到法官區塊
    """
    judge_ids = []

    # 策略 1: 嘗試法官列表頁面
    try:
        url = f'{BASE_URL}/judges'
        log(f'嘗試法官列表: {url}')
        page.goto(url, wait_until='domcontentloaded', timeout=30000)
        page.wait_for_timeout(3000)

        # 擷取頁面上的法官連結
        links = page.evaluate('''() => {
            const results = [];
            document.querySelectorAll('a[href*="judge"]').forEach(a => {
                const href = a.getAttribute('href');
                const text = a.textContent.trim();
                if (href && text) {
                    results.push({ href, text });
                }
            });
            return results;
        }''')

        if links:
            log(f'找到 {len(links)} 個法官連結')
            for link in links:
                match = re.search(r'/judge/([^/?#]+)', link['href'])
                if match:
                    judge_ids.append({
                        'lawsnote_id': match.group(1),
                        'name': link['text'],
                    })

    except Exception as e:
        log(f'法官列表頁面失敗: {e}')

    # 策略 2: 從 Lawsnote 搜尋 API 探索
    if not judge_ids:
        log('嘗試透過搜尋探索法官...')
        try:
            url = f'{BASE_URL}/search?type=judge'
            page.goto(url, wait_until='domcontentloaded', timeout=30000)
            page.wait_for_timeout(3000)

            results = page.evaluate('''() => {
                const items = [];
                // 嘗試找搜尋結果中的法官
                document.querySelectorAll('[data-judge-id], [href*="judge"]').forEach(el => {
                    const id = el.getAttribute('data-judge-id') || '';
                    const href = el.getAttribute('href') || '';
                    const name = el.textContent.trim();
                    const match = href.match(/judge\\/([^/?#]+)/);
                    if (match) {
                        items.push({ lawsnote_id: match[1], name });
                    } else if (id) {
                        items.push({ lawsnote_id: id, name });
                    }
                });
                return items;
            }''')

            if results:
                judge_ids.extend(results)
                log(f'搜尋找到 {len(results)} 個法官')

        except Exception as e:
            log(f'搜尋策略失敗: {e}')

    # 策略 3: 從法律搜尋頁面的法官篩選器探索
    if not judge_ids:
        log('嘗試從 lawsnote.com 主站探索...')
        try:
            page.goto('https://lawsnote.com/search', wait_until='domcontentloaded', timeout=30000)
            page.wait_for_timeout(2000)

            # 看看有沒有法官相關的篩選器或連結
            page_text = page.evaluate('() => document.body.innerText.substring(0, 5000)')
            if '法官' in page_text:
                log('主站有法官相關內容，需要進一步分析頁面結構')
            else:
                log('主站未發現法官入口')

        except Exception as e:
            log(f'主站探索失敗: {e}')

    if limit:
        judge_ids = judge_ids[:limit]

    log(f'共發現 {len(judge_ids)} 位法官 ID')
    return judge_ids


def scrape_judge_profile(page, lawsnote_id, name=None):
    """
    爬取單一法官的詳細資料

    TODO: 確認實際頁面 URL 和資料結構
    """
    url = f'{BASE_URL}/judge/{lawsnote_id}'

    try:
        page.goto(url, wait_until='domcontentloaded', timeout=20000)
        page.wait_for_timeout(2000)

        # 擷取法官資料
        data = page.evaluate('''() => {
            const result = {
                name: '',
                court_name: '',
                case_count_total: 0,
                case_count_by_year: {},
                case_type_distribution: {},
                avg_processing_days: null,
            };

            // 嘗試擷取名稱
            const h1 = document.querySelector('h1, .judge-name, [class*="name"]');
            if (h1) result.name = h1.textContent.trim();

            // 嘗試擷取法院
            const courtEl = document.querySelector('.court-name, [class*="court"], .subtitle');
            if (courtEl) result.court_name = courtEl.textContent.trim();

            // 嘗試擷取案件數
            const statEls = document.querySelectorAll('.stat-value, .count, [class*="case"]');
            statEls.forEach(el => {
                const text = el.textContent.trim();
                const num = parseInt(text.replace(/,/g, ''));
                if (!isNaN(num) && num > 0) {
                    result.case_count_total = Math.max(result.case_count_total, num);
                }
            });

            // 嘗試擷取案件類型分布
            document.querySelectorAll('[class*="type"], [class*="category"]').forEach(el => {
                const text = el.textContent.trim();
                const match = text.match(/(.+?)[\s:：]+(\d+)/);
                if (match) {
                    result.case_type_distribution[match[1].trim()] = parseInt(match[2]);
                }
            });

            // 嘗試擷取年度案件數
            document.querySelectorAll('[class*="year"], [class*="annual"]').forEach(el => {
                const text = el.textContent.trim();
                const match = text.match(/(20\d{2})[\s:：]+(\d+)/);
                if (match) {
                    result.case_count_by_year[match[1]] = parseInt(match[2]);
                }
            });

            return result;
        }''')

        if data:
            data['court_name'] = normalize_court(data.get('court_name', ''))
            if not data['name'] and name:
                data['name'] = name

        return data

    except PlaywrightTimeout:
        log(f'  超時: {lawsnote_id}')
        return None
    except Exception as e:
        log(f'  錯誤 {lawsnote_id}: {e}')
        return None


def main():
    parser = argparse.ArgumentParser(description='Lawsnote 法官頁面爬蟲')
    parser.add_argument('--limit', type=int, default=None, help='測試模式: 限制筆數')
    args = parser.parse_args()

    sb = get_supabase()
    log_id = scrape_start(sb, SCRAPER_NAME)

    playwright_inst = None
    browser = None

    try:
        log('=== Lawsnote 法官爬蟲啟動 ===')

        playwright_inst = sync_playwright().start()
        browser = playwright_inst.chromium.launch(headless=True)
        page = browser.new_page(
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
            locale='zh-TW',
        )

        # Phase 1: 探索法官 ID
        judge_ids = discover_judge_ids(page, limit=args.limit)

        if not judge_ids:
            log('未發現任何法官 ID')
            log('可能原因:')
            log('  1. Lawsnote 法官頁面 URL 結構已改變')
            log('  2. 需要登入才能存取')
            log('  3. 法官資料在不同的子路徑下')
            log('請手動檢查 page.lawsnote.com 的法官頁面結構')
            scrape_end(sb, log_id, status='partial',
                       records_found=0, records_inserted=0)
            return

        # Phase 2: 爬取每位法官的詳細資料
        records = []
        for i, judge in enumerate(judge_ids):
            lid = judge['lawsnote_id']
            log(f'  [{i+1}/{len(judge_ids)}] 爬取 {judge.get("name", lid)}...')

            data = scrape_judge_profile(page, lid, name=judge.get('name'))
            if data and data.get('name'):
                records.append({
                    'lawsnote_id': lid,
                    'name': data['name'],
                    'court_name': data.get('court_name') or None,
                    'case_count_total': data.get('case_count_total') or None,
                    'case_count_by_year': data.get('case_count_by_year') or None,
                    'case_type_distribution': data.get('case_type_distribution') or None,
                    'avg_processing_days': data.get('avg_processing_days') or None,
                    'source_url': f'{BASE_URL}/judge/{lid}',
                    'raw_data': data,
                    'scraped_at': datetime.now(timezone.utc).isoformat(),
                })

            polite_delay(2)

        log(f'成功擷取 {len(records)} 位法官資料')

        # Phase 3: 儲存到 DB
        inserted = 0
        if records:
            batch_size = 200
            for i in range(0, len(records), batch_size):
                batch = records[i:i+batch_size]
                result = sb.table('lawsnote_judges').upsert(
                    batch,
                    on_conflict='lawsnote_id'
                ).execute()
                inserted += len(result.data) if result.data else 0
                polite_delay(0.5)

        scrape_end(sb, log_id, status='success',
                   records_found=len(judge_ids),
                   records_inserted=inserted)

        log('=== 爬蟲完成 ===')

    except Exception as e:
        log(f'錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise

    finally:
        if browser:
            browser.close()
        if playwright_inst:
            playwright_inst.stop()


if __name__ == '__main__':
    main()
