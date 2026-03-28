"""
Lawsnote 律師專長資料爬蟲 (Playwright 版)
來源：https://page.lawsnote.com/search/expertise/{case_type}/
抓取各案件類型的律師清單（不指定地區=全國），彙整後 upsert 至 lawsnote_lawyers 表

此網站為 React CSR 應用，需要使用 headless browser 等待 JS 渲染完成
策略：只遍歷 27 種案件類型（不指定地區），約 27 次請求即可完成
"""
import re
from urllib.parse import quote
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

BASE_URL = 'https://page.lawsnote.com'

# 27 種案件類型 (from site dropdown)
CASE_TYPES = [
    '公平交易',
    '專利/商標/著作/營業秘密',
    '稅務',
    '離婚相關',
    '非離婚與家庭相關',
    '繼承/遺產',
    '金錢糾紛/損害賠償',
    '土地/房屋/其他不動產事宜',
    '鄰居間紛爭/管委會相關/祭祀公業',
    '買賣/合約相關',
    '毀損/侵占',
    '性侵/性騷擾/妨害風化',
    '妨害秘密',
    '竊盜/強盜/搶奪',
    '詐欺/詐騙',
    '偽造文書',
    '毒品/違禁品',
    '誹謗/侮辱/妨害名譽',
    '車禍/酒駕',
    '行賄/貪污/背信/瀆職',
    '醫療糾紛',
    '陪偵/羈押/具保責付',
    '商業糾紛',
    '保險相關',
    '殺人/傷害/恐嚇/妨害自由/強制',
    '勞資糾紛',
    '國家賠償',
]


def build_url(case_type):
    """組合搜尋 URL（不指定地區=全國），中文 path 需要 URL encode"""
    encoded_case = quote(case_type, safe='')
    return f'{BASE_URL}/search/expertise/{encoded_case}/'


def parse_articles_js(page):
    """
    使用 JavaScript 在頁面內直接解析所有 article，比逐一 query 快很多
    回傳律師列表 [{lawsnote_id, name, case_count_5yr}]
    """
    results = page.evaluate('''() => {
        const articles = document.querySelectorAll('article');
        const lawyers = [];
        articles.forEach(a => {
            const section = a.querySelector('section');
            if (!section) return;
            const text = section.textContent;
            const nameMatch = text.match(/^(.+?)近/);
            const caseMatch = text.match(/案件數\\s*[:：]\\s*(\\d+)/);
            const link = a.querySelector('a[href*="/page/"]');
            if (!link) return;
            const idMatch = link.href.match(/page\\/([a-f0-9]+)/);
            if (!idMatch) return;
            lawyers.push({
                lawsnote_id: idMatch[1],
                name: nameMatch ? nameMatch[1].replace(/\\s/g, '') : '',
                case_count_5yr: caseMatch ? parseInt(caseMatch[1]) : null
            });
        });
        return lawyers;
    }''')
    return results


def scrape_all_expertise(page):
    """
    只遍歷 27 種案件類型（不指定地區=全國結果）
    回傳 dict: lawsnote_id -> { name, case_count_5yr, expertise_areas }
    """
    lawyers = {}  # lawsnote_id -> merged data
    total = len(CASE_TYPES)
    errors = 0

    for idx, case_type in enumerate(CASE_TYPES, 1):
        url = build_url(case_type)

        try:
            page.goto(url, wait_until='domcontentloaded', timeout=30000)

            # 等待 React 渲染出 article 元素
            try:
                page.wait_for_selector('article', timeout=15000)
            except PlaywrightTimeout:
                log(f'[{idx}/{total}] {case_type} → 無結果 (timeout)')
                polite_delay(2)
                continue

            # 額外等待確保所有 article 渲染完成
            polite_delay(1)

            results = parse_articles_js(page)

            for r in results:
                lid = r['lawsnote_id']
                if lid not in lawyers:
                    lawyers[lid] = {
                        'lawsnote_id': lid,
                        'name': r['name'],
                        'case_count_5yr': r['case_count_5yr'],
                        'expertise_areas': set(),
                    }
                else:
                    if r['case_count_5yr'] is not None:
                        existing = lawyers[lid]['case_count_5yr']
                        if existing is None or r['case_count_5yr'] > existing:
                            lawyers[lid]['case_count_5yr'] = r['case_count_5yr']

                lawyers[lid]['expertise_areas'].add(case_type)

            log(f'[{idx}/{total}] {case_type} → {len(results)} 筆, 累計 {len(lawyers)} 位不重複律師')

        except PlaywrightTimeout:
            errors += 1
            log(f'[{idx}/{total}] 逾時 {case_type}')
        except Exception as e:
            errors += 1
            log(f'[{idx}/{total}] 錯誤 {case_type}: {e}')

        # 禮貌延遲 3 秒
        polite_delay(3)

    log(f'所有案件類型爬取完成，共 {len(lawyers)} 位不重複律師，{errors} 個錯誤')
    return lawyers


def save_lawyers(sb, lawyers_dict):
    """將律師資料批次 upsert 至 lawsnote_lawyers 表"""
    records = []
    for lid, data in lawyers_dict.items():
        records.append({
            'lawsnote_id': data['lawsnote_id'],
            'name': data['name'],
            'case_count_5yr': data['case_count_5yr'],
            'expertise_areas': sorted(data['expertise_areas']),
            'source_url': f'{BASE_URL}/page/{data["lawsnote_id"]}',
            'is_active': True,
        })

    log(f'準備寫入 {len(records)} 筆律師資料...')

    inserted = 0
    updated = 0
    batch_size = 200

    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]

        # 查詢已存在的 lawsnote_id
        batch_ids = [r['lawsnote_id'] for r in batch]
        existing = sb.table('lawsnote_lawyers').select('lawsnote_id').in_(
            'lawsnote_id', batch_ids
        ).execute()
        existing_ids = {r['lawsnote_id'] for r in existing.data}

        for r in batch:
            if r['lawsnote_id'] in existing_ids:
                updated += 1
            else:
                inserted += 1

        sb.table('lawsnote_lawyers').upsert(
            batch, on_conflict='lawsnote_id'
        ).execute()

        progress = min(i + batch_size, len(records))
        log(f'  已寫入 {progress}/{len(records)} 筆')

        if i + batch_size < len(records):
            polite_delay(0.5)

    log(f'寫入完成: 新增 {inserted}, 更新 {updated}')
    return inserted, updated


def main():
    sb = get_supabase()
    log_id = scrape_start(sb, 'lawsnote_lawyers')

    playwright = None
    browser = None

    try:
        log('=== Lawsnote 律師專長爬蟲開始 (Playwright) ===')
        log(f'案件類型: {len(CASE_TYPES)} 種（不指定地區=全國）')
        log(f'預估請求數: {len(CASE_TYPES)}')

        # 啟動 headless Chromium
        playwright = sync_playwright().start()
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
            locale='zh-TW',
        )

        # Phase 1: 爬取所有案件類型
        lawyers_dict = scrape_all_expertise(page)

        if not lawyers_dict:
            log('未爬取到任何律師資料')
            scrape_end(sb, log_id, status='error',
                       error_message='No lawyers found from any combo')
            return

        # Phase 2: 寫入 Supabase
        inserted, updated = save_lawyers(sb, lawyers_dict)

        scrape_end(sb, log_id, status='success',
                   records_found=len(lawyers_dict),
                   records_inserted=inserted,
                   records_updated=updated)

        log(f'=== Lawsnote 爬蟲完成 ===')
        log(f'不重複律師: {len(lawyers_dict)}')
        log(f'新增: {inserted}, 更新: {updated}')

    except Exception as e:
        log(f'爬蟲錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise

    finally:
        # 確保瀏覽器資源被釋放
        if browser:
            browser.close()
        if playwright:
            playwright.stop()


if __name__ == '__main__':
    main()
