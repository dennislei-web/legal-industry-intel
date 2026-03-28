"""
Lawsnote 律師個人頁面爬蟲 (分批處理)
從 lawsnote_lawyers 表中取出尚未爬取 profile 的律師，
逐一訪問個人頁面抓取事務所、證書、學歷、經歷等資料。

每次執行處理 BATCH_SIZE 筆（預設 600），可多次執行直到全部完成。
"""
import os
import re
import json
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
from utils import get_supabase, log

BATCH_SIZE = int(os.environ.get('BATCH_SIZE', '600'))
BASE_URL = 'https://page.lawsnote.com/page'


def extract_profile(page, lawsnote_id):
    """訪問律師個人頁面，提取事務所、證書、學歷、經歷等"""
    url = f'{BASE_URL}/{lawsnote_id}'
    try:
        page.goto(url, wait_until='domcontentloaded', timeout=20000)
        # 等待頁面內容渲染
        page.wait_for_selector('section, article, div.profile', timeout=12000)
        # 額外等待確保 React 渲染完成
        page.wait_for_timeout(1500)
    except PlaywrightTimeout:
        log(f'  頁面載入超時: {lawsnote_id}')
        return None
    except Exception as e:
        log(f'  頁面錯誤 {lawsnote_id}: {e}')
        return None

    # 用 JS 在頁面內提取所有資料
    try:
        data = page.evaluate('''() => {
            const body = document.body.innerText;
            const result = {};

            // 證書字號 (含各種變體：台/臺、檢證/檢補證/檢覆證)
            const certMatch = body.match(/(\\d+)[台臺]檢[補覆]?證字第(\\d+)號/);
            result.cert_number = certMatch ? certMatch[0] : null;

            // 服務區域
            const regionIdx = body.indexOf('服務區域') || body.indexOf('服 務 區 域');
            if (regionIdx > -1) {
                const regionText = body.substring(regionIdx, regionIdx + 200);
                const lines = regionText.split('\\n').slice(1).filter(l => l.trim());
                result.service_regions = lines.slice(0, 3).map(l => l.trim()).join(', ');
            }

            // 找所有包含「事務所」的文字作為事務所名稱
            const allElements = document.querySelectorAll('div, li, p, span');
            const firms = [];
            const experiences = [];
            const educations = [];
            const otherCerts = [];

            allElements.forEach(el => {
                const t = el.textContent.trim();
                // 事務所（通常在經歷中第一個出現的）
                if (t.includes('事務所') && t.length < 60 && !firms.includes(t)) {
                    firms.push(t);
                }
            });

            // 用 body text 找經歷、學歷、其他證照區塊
            const sections = body.split('\\n').map(l => l.trim()).filter(l => l);

            let currentSection = '';
            for (const line of sections) {
                if (line.includes('經　歷') || line === '經歷') {
                    currentSection = 'exp';
                    continue;
                }
                if (line.includes('學　歷') || line === '學歷') {
                    currentSection = 'edu';
                    continue;
                }
                if (line.includes('其　他') || line.includes('證　照') || line === '其他證照') {
                    currentSection = 'cert';
                    continue;
                }
                if (line.includes('擅長領域') || line.includes('計費方式') || line === '客服') {
                    currentSection = '';
                    continue;
                }

                if (currentSection === 'exp' && line.length > 2 && line.length < 80) {
                    experiences.push(line);
                }
                if (currentSection === 'edu' && line.length > 2 && line.length < 80) {
                    educations.push(line);
                }
                if (currentSection === 'cert' && line.length > 2 && line.length < 60) {
                    otherCerts.push(line);
                }
            }

            result.firm_name = firms.length > 0 ? firms[0] : (experiences.length > 0 && experiences[0].includes('事務所') ? experiences[0] : null);
            result.experience = experiences.slice(0, 10);
            result.education = educations.slice(0, 5);
            result.other_certs = otherCerts.slice(0, 10);

            // 如果沒找到事務所但經歷有資料，取第一個作為所屬機構
            if (!result.firm_name && experiences.length > 0) {
                result.firm_name = experiences[0];
            }

            return result;
        }''')
        return data
    except Exception as e:
        log(f'  JS 解析錯誤 {lawsnote_id}: {e}')
        return None


def main():
    sb = get_supabase()

    # 取得需要爬取的律師：未爬過 OR 已爬過但缺少證書字號
    import os
    rescrape = os.environ.get('RESCRAPE_MISSING_CERT', 'false').lower() == 'true'

    if rescrape:
        log('模式: 重新爬取缺少證書字號的律師')
        resp = sb.table('lawsnote_lawyers') \
            .select('id, lawsnote_id, name') \
            .eq('profile_scraped', True) \
            .is_('cert_number', 'null') \
            .order('case_count_5yr', desc=True) \
            .limit(BATCH_SIZE) \
            .execute()
    else:
        resp = sb.table('lawsnote_lawyers') \
            .select('id, lawsnote_id, name') \
            .or_('profile_scraped.is.null,profile_scraped.eq.false') \
            .order('case_count_5yr', desc=True) \
            .limit(BATCH_SIZE) \
            .execute()

    lawyers = resp.data
    total = len(lawyers)
    log(f'本批次待處理: {total} 位律師')

    if total == 0:
        log('所有律師 profile 已爬取完成！')
        return

    scraped = 0
    errors = 0

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        )
        page = context.new_page()

        for idx, lawyer in enumerate(lawyers, 1):
            lid = lawyer['lawsnote_id']
            name = lawyer['name']

            if idx % 50 == 0 or idx == 1:
                log(f'進度: {idx}/{total} ({idx*100//total}%) - 正在處理: {name}')

            data = extract_profile(page, lid)

            if data:
                update = {
                    'profile_scraped': True,
                    'firm_name': data.get('firm_name'),
                    'cert_number': data.get('cert_number'),
                    'education': data.get('education', []),
                    'experience': data.get('experience', []),
                    'other_certs': data.get('other_certs', []),
                }

                # 更新服務區域（如果有）
                if data.get('service_regions'):
                    regions = [r.strip() for r in data['service_regions'].replace('．', '.').replace(' . ', ', ').split(',') if r.strip()]
                    if regions:
                        update['service_regions'] = regions

                try:
                    sb.table('lawsnote_lawyers') \
                        .update(update) \
                        .eq('id', lawyer['id']) \
                        .execute()
                    scraped += 1
                except Exception as e:
                    log(f'  DB 更新失敗 {name}: {e}')
                    errors += 1
            else:
                # 標記為已嘗試（避免重複爬取失敗的頁面）
                try:
                    sb.table('lawsnote_lawyers') \
                        .update({'profile_scraped': True}) \
                        .eq('id', lawyer['id']) \
                        .execute()
                except:
                    pass
                errors += 1

        browser.close()

    log(f'完成！成功: {scraped}, 失敗: {errors}, 總計: {total}')

    # 記錄到 scrape_logs
    remaining = sb.table('lawsnote_lawyers') \
        .select('id', count='exact') \
        .or_('profile_scraped.is.null,profile_scraped.eq.false') \
        .execute()

    remaining_count = remaining.count if remaining.count else 0
    log(f'剩餘未爬取: {remaining_count} 位')


if __name__ == '__main__':
    main()
