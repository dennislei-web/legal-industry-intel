"""
司法院法官名冊爬蟲（PDF 解析版）
來源: 各法院官網的法官名錄 PDF
產出: jy_judges 表

每個法院都有自己的法官名錄頁面，內含 PDF 下載連結。
PDF 表格欄位: 庭別 / 職稱 / 姓名 / 現辦事(職)務 / 承辦專業案件類別 / 學歷

用法:
  pip install pdfplumber playwright
  python scrape_jy_judges.py                          # 爬全部法院
  python scrape_jy_judges.py --court 臺灣臺北地方法院  # 指定法院
  python scrape_jy_judges.py --limit 3                # 只爬前 3 個法院（測試）
"""
import re
import os
import argparse
import tempfile
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

try:
    import pdfplumber
except ImportError:
    print("請先安裝 pdfplumber: pip install pdfplumber")
    exit(1)

from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

SCRAPER_NAME = 'jy_judges'

# ============================================================
# 各法院法官名錄頁面 URL
# 格式: 法院名稱 → (子域名, 法官名錄頁面路徑)
# 頁面上會有 PDF 下載連結
# ============================================================
COURT_PAGES = {
    # 格式: 法院名稱 → (子域名, 起始搜尋頁面列表)
    # 爬蟲會依序嘗試每個頁面，在其中搜尋 PDF 下載連結
    # 優先放已知有 PDF 的 cp- 頁面，再放目錄頁 np- 作為 fallback

    # 高等法院系統（已確認頁面結構：cp- 頁面直接有 PDF）
    '臺灣高等法院': ('tph', ['/tw/np-1639-051.html']),

    # 地方法院（台北地院已確認：np → lp → cp → dl-PDF）
    '臺灣臺北地方法院': ('tpd', ['/tw/lp-2927-151.html', '/tw/np-2842-151.html']),
    '臺灣新北地方法院': ('pcd', ['/tw/np-1225-161.html']),
    '臺灣士林地方法院': ('sld', ['/tw/np-3006-171.html']),
    '臺灣桃園地方法院': ('tyd', ['/tw/np-1344-181.html']),
    '臺灣新竹地方法院': ('scd', ['/tw/np-1230-191.html']),
    '臺灣苗栗地方法院': ('mld', ['/tw/np-1249-201.html']),
    '臺灣臺中地方法院': ('tcd', ['/tw/np-1328-211.html']),
    '臺灣彰化地方法院': ('chd', ['/tw/np-1111-231.html']),
    '臺灣臺南地方法院': ('tnd', ['/tw/np-1334-261.html']),
    '臺灣高雄地方法院': ('ksd', ['/tw/np-1198-271.html']),
    '臺灣屏東地方法院': ('ptd', ['/tw/np-1277-291.html']),
    '臺灣花蓮地方法院': ('hld', ['/tw/np-1183-311.html']),
    '臺灣宜蘭地方法院': ('ild', ['/tw/np-1188-321.html']),
    '臺灣基隆地方法院': ('kld', ['/tw/np-1209-331.html']),
}


def normalize_court(name):
    """法院名稱正規化"""
    if not name:
        return name
    return name.replace('台灣', '臺灣').replace('　', '').strip()


def find_pdf_url(page, base_url):
    """在法院法官名錄頁面找 PDF 下載連結"""
    subdomain = base_url.replace('https://', '').split('.')[0]  # e.g. 'tpd'

    # 策略 1: 直接在頁面找 PDF 連結
    links = page.evaluate('''() => {
        const results = [];
        document.querySelectorAll('a').forEach(a => {
            const href = a.getAttribute('href') || '';
            const text = a.textContent.trim().toLowerCase();
            if (href.includes('dl-') || href.includes('.pdf') || text.includes('pdf')) {
                results.push({ href: a.href, text: a.textContent.trim() });
            }
        });
        // 也找 iframe（有些法院直接嵌入 PDF）
        document.querySelectorAll('iframe').forEach(f => {
            if (f.src && f.src.includes('dl-')) {
                results.push({ href: f.src, text: 'iframe-pdf' });
            }
        });
        return results;
    }''')

    # 優先選擇同一法院子域名的連結
    for link in links:
        if 'dl-' in link['href'] and subdomain in link['href']:
            return link['href']
    # 退而求其次：任何 dl- 連結
    for link in links:
        if 'dl-' in link['href'] and 'judicial.gov.tw' in link['href']:
            return link['href']

    # 策略 2: 找頁面上的子連結（有些法院名錄放在子頁面）
    sub_links = page.evaluate('''() => {
        const results = [];
        document.querySelectorAll('a').forEach(a => {
            const text = a.textContent.trim();
            const href = a.getAttribute('href') || '';
            // 找包含「法官」「名錄」的連結，或 cp- 開頭的子頁面
            if (text.includes('法官') || text.includes('名錄') ||
                (href.includes('cp-') && !href.includes('javascript'))) {
                results.push({ href: a.href, text });
            }
        });
        return results;
    }''')

    for link in sub_links:
        try:
            # 只訪問同域名的子連結
            if subdomain not in link['href'] and 'judicial.gov.tw' not in link['href']:
                continue
            log(f'    搜尋子頁面: {link["text"][:30]} → {link["href"][-50:]}')
            page.goto(link['href'], wait_until='domcontentloaded', timeout=15000)
            page.wait_for_timeout(2000)
            # 找同域名的 PDF 下載連結
            inner_links = page.evaluate('''() => {
                const results = [];
                document.querySelectorAll('a, iframe').forEach(el => {
                    const href = el.getAttribute('href') || el.getAttribute('src') || '';
                    const fullHref = el.href || href;
                    if (href.includes('dl-')) {
                        const text = el.textContent ? el.textContent.trim().toLowerCase() : '';
                        results.push({ href: fullHref, text });
                    }
                });
                return results;
            }''')
            # 優先同域名 + pdf 相關
            for il in inner_links:
                if subdomain in il['href'] and ('pdf' in il['text'] or 'dl-' in il['href']):
                    return il['href']
            # 退而求其次：同域名的任何 dl-
            for il in inner_links:
                if subdomain in il['href']:
                    return il['href']
        except:
            continue

    return None


def download_pdf(page, pdf_url, court_name):
    """下載 PDF 到暫存檔（用 requests 直接下載，避免 Playwright 拿到 HTML wrapper）"""
    import requests
    import warnings
    warnings.filterwarnings('ignore', message='Unverified HTTPS')

    tmp_path = os.path.join(tempfile.gettempdir(), f'judge_{court_name}.pdf')

    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0'}
        resp = requests.get(pdf_url, headers=headers, timeout=30, verify=False)

        if resp.status_code == 200 and resp.content[:4] == b'%PDF':
            with open(tmp_path, 'wb') as f:
                f.write(resp.content)
            log(f'  PDF 下載成功: {len(resp.content):,} bytes')
            return tmp_path
        else:
            log(f'  PDF 下載失敗: HTTP {resp.status_code}, content-type={resp.headers.get("content-type")}')
            # 如果不是 PDF，嘗試看內容是不是 HTML 包含 PDF 連結
            if b'%PDF' not in resp.content[:10]:
                log(f'  回傳非 PDF 內容，跳過')
            return None
    except Exception as e:
        log(f'  PDF 下載錯誤: {e}')
        return None


def parse_judge_pdf(pdf_path, court_name):
    """用 pdfplumber 解析法官名錄 PDF"""
    judges = []

    try:
        with pdfplumber.open(pdf_path) as pdf:
            log(f'  PDF 共 {len(pdf.pages)} 頁')

            current_division = ''

            for page_num, page in enumerate(pdf.pages):
                tables = page.extract_tables()

                for table in tables:
                    for row in table:
                        if not row or all(cell is None or cell.strip() == '' for cell in row):
                            continue

                        # 清理 cell
                        cells = [c.strip().replace('\n', '') if c else '' for c in row]

                        # 跳過表頭
                        if any(h in ''.join(cells) for h in ['庭別', '職稱', '姓名', '現辦事']):
                            continue

                        # 根據欄位數量判斷結構
                        # 常見格式: 庭別 / 職稱 / 姓名 / 現辦事務 / 承辦專業 / 學歷
                        if len(cells) >= 3:
                            division = cells[0] if cells[0] else current_division
                            if division and '庭' in division:
                                current_division = division

                            # 找出姓名（通常 2-3 個中文字）
                            name = ''
                            rank = ''
                            duty = ''
                            specialty = ''
                            education = ''

                            if len(cells) >= 6:
                                division = cells[0] if cells[0] else current_division
                                rank = cells[1]
                                name = cells[2]
                                duty = cells[3]
                                specialty = cells[4]
                                education = cells[5]
                            elif len(cells) >= 4:
                                rank = cells[0] if not cells[0].endswith('庭') else ''
                                name = cells[1] if len(cells[1]) <= 4 else cells[2]
                                if len(cells) > 3:
                                    duty = cells[3]
                            elif len(cells) >= 3:
                                name = cells[1] if len(cells[1]) <= 4 else cells[0]
                                rank = cells[0] if name != cells[0] else ''

                            # 驗證姓名格式（2-4 個中文字）
                            name = name.strip()
                            if not name or not re.match(r'^[\u4e00-\u9fff]{2,4}$', name):
                                continue

                            # 清理職稱
                            rank = rank.strip()
                            if rank and '庭' in rank:
                                if not current_division:
                                    current_division = rank
                                rank = ''

                            judges.append({
                                'name': name,
                                'court_name': normalize_court(court_name),
                                'division': current_division if current_division else None,
                                'rank': rank if rank else '法官',
                                'status': '現任',
                                'raw_data': {
                                    'duty': duty,
                                    'specialty': specialty,
                                    'education': education,
                                    'page': page_num + 1,
                                },
                                'scraped_at': datetime.now(timezone.utc).isoformat(),
                            })

    except Exception as e:
        log(f'  PDF 解析錯誤: {e}')

    # 去重（同一法院同一法官可能出現多次）
    seen = set()
    unique = []
    for j in judges:
        key = f"{j['name']}_{j['court_name']}"
        if key not in seen:
            seen.add(key)
            unique.append(j)

    return unique


def resolve_court_ids(sb, judges):
    """查詢 courts 表取得 court_id"""
    court_names = list(set(j['court_name'] for j in judges if j.get('court_name')))
    if not court_names:
        return {}
    mapping = {}
    for i in range(0, len(court_names), 50):
        batch = court_names[i:i+50]
        result = sb.table('courts').select('id, name').in_('name', batch).execute()
        for row in result.data:
            mapping[row['name']] = row['id']
    return mapping


def main():
    parser = argparse.ArgumentParser(description='司法院法官名冊爬蟲（PDF 解析版）')
    parser.add_argument('--limit', type=int, default=None, help='限制爬取法院數量（測試用）')
    parser.add_argument('--court', type=str, default=None, help='指定法院名稱')
    args = parser.parse_args()

    sb = get_supabase()
    log_id = scrape_start(sb, SCRAPER_NAME)

    playwright_inst = None
    browser = None
    all_judges = []

    try:
        log('=== 司法院法官名冊爬蟲啟動（PDF 解析版）===')

        playwright_inst = sync_playwright().start()
        browser = playwright_inst.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
            locale='zh-TW',
        )
        page = context.new_page()

        # 篩選法院
        courts_to_scrape = dict(COURT_PAGES)
        if args.court:
            target = normalize_court(args.court)
            courts_to_scrape = {k: v for k, v in courts_to_scrape.items() if target in k}
            if not courts_to_scrape:
                log(f'找不到法院: {args.court}')
                log(f'可用法院: {", ".join(COURT_PAGES.keys())}')
                return

        if args.limit:
            courts_to_scrape = dict(list(courts_to_scrape.items())[:args.limit])

        log(f'將爬取 {len(courts_to_scrape)} 個法院')

        for court_name, (subdomain, paths) in courts_to_scrape.items():
            log(f'\n--- {court_name} ---')
            base_url = f'https://{subdomain}.judicial.gov.tw'

            try:
                pdf_url = None

                # 嘗試每個起始頁面
                for path in paths:
                    if pdf_url:
                        break
                    url = base_url + path
                    log(f'  載入: {url}')
                    try:
                        page.goto(url, wait_until='domcontentloaded', timeout=30000)
                        page.wait_for_timeout(3000)
                    except:
                        log(f'  載入失敗，跳過此頁面')
                        continue

                    # Level 1: 直接在此頁找 PDF
                    pdf_url = find_pdf_url(page, base_url)
                    if pdf_url:
                        break

                    # Level 2: 找子頁面（cp- 開頭，或含「法官」「名錄」）
                    sub_pages = page.evaluate('''() => {
                        const links = [];
                        const seen = new Set();
                        document.querySelectorAll('a').forEach(a => {
                            const href = a.href || '';
                            const text = a.textContent.trim();
                            if (seen.has(href)) return;
                            seen.add(href);
                            if ((href.includes('cp-') || href.includes('lp-')) &&
                                (text.includes('法官') || text.includes('名錄') || text.includes('名冊'))) {
                                links.push({ href, text: text.substring(0, 30) });
                            }
                        });
                        return links;
                    }''')

                    for sp in sub_pages[:5]:
                        if pdf_url:
                            break
                        if subdomain not in sp['href']:
                            continue
                        log(f'    L2: {sp["text"]} → ...{sp["href"][-40:]}')
                        try:
                            page.goto(sp['href'], wait_until='domcontentloaded', timeout=15000)
                            page.wait_for_timeout(2000)
                        except:
                            continue
                        pdf_url = find_pdf_url(page, base_url)
                        if pdf_url:
                            break

                        # Level 3: 再深入一層
                        inner_pages = page.evaluate('''() => {
                            const links = [];
                            const seen = new Set();
                            document.querySelectorAll('a').forEach(a => {
                                const href = a.href || '';
                                const text = a.textContent.trim();
                                if (seen.has(href)) return;
                                seen.add(href);
                                if (href.includes('cp-') &&
                                    (text.includes('法官') || text.includes('名錄') || text.includes('pdf'))) {
                                    links.push({ href, text: text.substring(0, 30) });
                                }
                            });
                            return links;
                        }''')

                        for ip in inner_pages[:3]:
                            if subdomain not in ip['href']:
                                continue
                            log(f'      L3: {ip["text"]} → ...{ip["href"][-40:]}')
                            try:
                                page.goto(ip['href'], wait_until='domcontentloaded', timeout=15000)
                                page.wait_for_timeout(2000)
                            except:
                                continue
                            pdf_url = find_pdf_url(page, base_url)
                            if pdf_url:
                                break

                if not pdf_url:
                    log(f'  ⚠ 無法找到 PDF，跳過')
                    continue

                log(f'  PDF URL: {pdf_url}')

                # 下載 PDF
                pdf_path = download_pdf(page, pdf_url, court_name)
                if not pdf_path:
                    continue

                # 解析 PDF
                judges = parse_judge_pdf(pdf_path, court_name)
                log(f'  解析出 {len(judges)} 位法官')

                all_judges.extend(judges)

                # 清理暫存
                try:
                    os.remove(pdf_path)
                except:
                    pass

                polite_delay(3)

            except PlaywrightTimeout:
                log(f'  ⚠ 超時，跳過')
            except Exception as e:
                log(f'  ⚠ 錯誤: {e}')
                continue

        # 儲存到 DB
        log(f'\n=== 共 {len(all_judges)} 位法官，開始儲存 ===')

        if all_judges:
            # 解析 court_id
            court_map = resolve_court_ids(sb, all_judges)
            for j in all_judges:
                j['court_id'] = court_map.get(j['court_name'])

            # 批次 upsert
            inserted = 0
            batch_size = 200
            for i in range(0, len(all_judges), batch_size):
                batch = all_judges[i:i+batch_size]
                result = sb.table('jy_judges').upsert(
                    batch, on_conflict='name,court_name'
                ).execute()
                inserted += len(result.data) if result.data else 0
                polite_delay(0.5)

            log(f'儲存完成: {inserted} 筆')
        else:
            inserted = 0

        scrape_end(sb, log_id, status='success',
                   records_found=len(all_judges),
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
