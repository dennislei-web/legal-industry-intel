"""
司法院法官名冊爬蟲
來源: https://judicial.gov.tw
產出: jy_judges 表 + 更新 courts 表

用法:
  python scrape_jy_judges.py              # 爬全部
  python scrape_jy_judges.py --limit 50   # 測試模式
  python scrape_jy_judges.py --court 臺灣臺北地方法院  # 指定法院
"""
import re
import argparse
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

SCRAPER_NAME = 'jy_judges'

# 法院名稱正規化
def normalize_court(name):
    if not name:
        return name
    return name.replace('台灣', '臺灣').replace('　', '').strip()


def resolve_court_ids(sb, judges):
    """查詢 courts 表，回傳 court_name → court_id 對應"""
    court_names = list(set(j['court_name'] for j in judges if j.get('court_name')))
    if not court_names:
        return {}

    mapping = {}
    # 批次查詢
    for i in range(0, len(court_names), 50):
        batch = court_names[i:i+50]
        result = sb.table('courts').select('id, name').in_('name', batch).execute()
        for row in result.data:
            mapping[row['name']] = row['id']

    return mapping


def scrape_judges(page, target_court=None, limit=None):
    """
    爬取司法院法官名冊

    TODO: 司法院網站結構需要實際確認，以下是基於常見政府網站的推測實作。
    實際 URL 和 selector 可能需要根據網站調整。

    可能的入口:
    1. https://judicial.gov.tw 首頁 → 便民服務 → 法官名冊
    2. https://jirs.judicial.gov.tw/GNNWS/JudgeInfo.asp (舊版)
    3. 各法院官網的法官介紹頁面
    """
    judges = {}

    # === 策略 1: 嘗試司法院法官查詢系統 ===
    try:
        url = 'https://judicial.gov.tw/tw/lp-1679-1.html'  # 法官名冊頁面 (需確認)
        log(f'嘗試載入: {url}')
        page.goto(url, wait_until='domcontentloaded', timeout=30000)
        page.wait_for_timeout(3000)

        # 嘗試擷取頁面內容來分析結構
        title = page.title()
        log(f'頁面標題: {title}')

        # 嘗試找法官列表
        # TODO: 根據實際頁面結構調整 selector
        rows = page.evaluate('''() => {
            // 嘗試常見的表格結構
            const tables = document.querySelectorAll('table');
            const results = [];
            tables.forEach(table => {
                const trs = table.querySelectorAll('tr');
                trs.forEach(tr => {
                    const tds = tr.querySelectorAll('td');
                    if (tds.length >= 3) {
                        results.push({
                            cells: Array.from(tds).map(td => td.textContent.trim())
                        });
                    }
                });
            });
            return results;
        }''')

        if rows:
            log(f'找到 {len(rows)} 行表格資料')
            for row in rows:
                cells = row.get('cells', [])
                if len(cells) >= 3:
                    # TODO: 根據實際欄位順序調整
                    name = cells[0].strip()
                    court = normalize_court(cells[1].strip()) if len(cells) > 1 else ''
                    division = cells[2].strip() if len(cells) > 2 else ''
                    rank = cells[3].strip() if len(cells) > 3 else ''

                    if not name or len(name) > 10:
                        continue
                    if target_court and court != target_court:
                        continue

                    key = f'{name}_{court}'
                    judges[key] = {
                        'name': name,
                        'court_name': court,
                        'division': division if division else None,
                        'rank': rank if rank else None,
                        'status': '現任',
                        'raw_data': {'cells': cells},
                        'scraped_at': datetime.now(timezone.utc).isoformat(),
                    }

                    if limit and len(judges) >= limit:
                        break

    except PlaywrightTimeout:
        log('策略 1 超時，嘗試策略 2...')
    except Exception as e:
        log(f'策略 1 失敗: {e}')

    # === 策略 2: 嘗試各法院官網 ===
    if not judges:
        log('嘗試從各法院官網爬取法官資料...')
        # 各法院官網通常有法官介紹頁面
        # TODO: 建立各法院法官頁面 URL 列表
        court_urls = {
            '臺灣臺北地方法院': 'https://tpd.judicial.gov.tw',
            '臺灣新北地方法院': 'https://pcd.judicial.gov.tw',
            '臺灣士林地方法院': 'https://sld.judicial.gov.tw',
            '臺灣桃園地方法院': 'https://tyd.judicial.gov.tw',
            '臺灣臺中地方法院': 'https://tcd.judicial.gov.tw',
            '臺灣高雄地方法院': 'https://ksd.judicial.gov.tw',
            '臺灣臺南地方法院': 'https://tnd.judicial.gov.tw',
        }

        if target_court and target_court in court_urls:
            court_urls = {target_court: court_urls[target_court]}

        for court_name, base_url in court_urls.items():
            if limit and len(judges) >= limit:
                break
            try:
                # 各法院通常有 /介紹/法官 之類的路徑
                url = f'{base_url}/tw/lp-167-1.html'  # 常見路徑 (需確認)
                log(f'嘗試 {court_name}: {url}')
                page.goto(url, wait_until='domcontentloaded', timeout=20000)
                page.wait_for_timeout(2000)

                # 擷取法官列表
                result = page.evaluate('''() => {
                    const items = [];
                    // 嘗試找列表或表格中的法官名稱
                    document.querySelectorAll('a, li, td').forEach(el => {
                        const text = el.textContent.trim();
                        // 法官名稱通常是 2-3 個中文字
                        if (/^[\u4e00-\u9fff]{2,3}$/.test(text)) {
                            items.push(text);
                        }
                    });
                    return [...new Set(items)];
                }''')

                if result:
                    log(f'  {court_name}: 找到 {len(result)} 個可能的法官名')
                    for name in result:
                        key = f'{name}_{court_name}'
                        if key not in judges:
                            judges[key] = {
                                'name': name,
                                'court_name': court_name,
                                'status': '現任',
                                'raw_data': {'source': 'court_website'},
                                'scraped_at': datetime.now(timezone.utc).isoformat(),
                            }
                polite_delay(3)
            except Exception as e:
                log(f'  {court_name} 失敗: {e}')
                continue

    return list(judges.values())


def save_judges(sb, judges):
    """儲存法官資料到 jy_judges"""
    if not judges:
        return 0, 0

    # 解析 court_id
    court_map = resolve_court_ids(sb, judges)

    records = []
    for j in judges:
        j['court_id'] = court_map.get(j['court_name'])
        records.append(j)

    # 批次 upsert
    inserted = 0
    updated = 0
    batch_size = 200

    for i in range(0, len(records), batch_size):
        batch = records[i:i+batch_size]
        result = sb.table('jy_judges').upsert(
            batch,
            on_conflict='name,court_name'
        ).execute()
        # 粗略估計
        inserted += len(result.data) if result.data else 0
        polite_delay(0.5)

    return inserted, updated


def main():
    parser = argparse.ArgumentParser(description='司法院法官名冊爬蟲')
    parser.add_argument('--limit', type=int, default=None, help='測試模式: 限制筆數')
    parser.add_argument('--court', type=str, default=None, help='指定法院名稱')
    args = parser.parse_args()

    sb = get_supabase()
    log_id = scrape_start(sb, SCRAPER_NAME)

    playwright_inst = None
    browser = None

    try:
        log('=== 司法院法官名冊爬蟲啟動 ===')

        playwright_inst = sync_playwright().start()
        browser = playwright_inst.chromium.launch(headless=True)
        page = browser.new_page(
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
            locale='zh-TW',
        )

        target_court = normalize_court(args.court) if args.court else None
        judges = scrape_judges(page, target_court=target_court, limit=args.limit)
        log(f'共擷取 {len(judges)} 位法官資料')

        if judges:
            inserted, updated = save_judges(sb, judges)
            log(f'儲存完成: inserted={inserted}')
        else:
            inserted, updated = 0, 0
            log('未擷取到任何資料，可能需要調整爬蟲 selector')
            log('請手動檢查 judicial.gov.tw 的頁面結構')

        scrape_end(sb, log_id, status='success',
                   records_found=len(judges),
                   records_inserted=inserted,
                   records_updated=updated)

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
