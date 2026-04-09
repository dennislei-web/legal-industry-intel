"""
爬取剩餘 13 個法院的法官資料
使用 requests + pdfplumber，不依賴 Playwright
"""
import sys
import re
import json
import warnings
import time
import os
import tempfile

sys.stdout.reconfigure(encoding='utf-8')
warnings.filterwarnings('ignore')

import requests
import pdfplumber
from utils import get_supabase, log

sb = get_supabase()
session = requests.Session()
session.headers.update({
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept-Language': 'zh-TW,zh;q=0.9',
    'Accept': 'text/html,application/xhtml+xml',
})
session.verify = False


def normalize_court(name):
    return name.replace('台灣', '臺灣').strip()


def extract_judges_html(html):
    return re.findall(r'>(院長|庭長|法官兼庭長|法官兼審判長|審判長|法官)[_＿]([^<]{1,10})<', html)


def find_dl_links(html, subdomain):
    all_dl = re.findall(r'href=["\'](/tw/dl-[^"\']*)["\']', html)
    all_dl += re.findall(r'href=["\'](https?://[^"\']*' + subdomain + r'[^"\']*/tw/dl-[^"\']*)["\']', html)
    return list(set(all_dl))


def find_sub_links(html, base_url, subdomain):
    links = re.findall(r'href=["\'](/tw/(?:np|lp|cp)-[^"\']*)["\'][^>]*>([^<]*)', html)
    links += re.findall(r'href=["\'](https?://[^"\']*' + subdomain + r'[^"\']*/tw/(?:np|lp|cp)-[^"\']*)["\'][^>]*>([^<]*)', html)
    result = []
    seen = set()
    for href, text in links:
        text = text.strip()
        url = href if href.startswith('http') else base_url + href
        if url in seen:
            continue
        if '法官' in text or '名錄' in text or '名冊' in text:
            seen.add(url)
            result.append((url, text))
    return result


def download_parse_pdf(pdf_url, court_name):
    try:
        resp = session.get(pdf_url, timeout=30)
        if resp.status_code != 200 or resp.content[:4] != b'%PDF':
            return []

        tmp = os.path.join(tempfile.gettempdir(), f'judge_{court_name}.pdf')
        with open(tmp, 'wb') as f:
            f.write(resp.content)

        judges = []
        seen = set()
        with pdfplumber.open(tmp) as pdf:
            current_div = ''
            for page in pdf.pages:
                for table in page.extract_tables():
                    for row in table:
                        if not row or all(not c or not c.strip() for c in row):
                            continue
                        cells = [c.strip().replace('\n', '') if c else '' for c in row]
                        if any(h in ''.join(cells) for h in ['庭別', '職稱', '姓名', '現辦事']):
                            continue
                        if cells[0] and '庭' in cells[0]:
                            current_div = cells[0]
                        name = ''
                        rank = '法官'
                        for i, c in enumerate(cells):
                            if re.match(r'^[\u4e00-\u9fff]{2,4}$', c) and '庭' not in c and '事' not in c:
                                name = c
                                if i > 0 and cells[i-1]:
                                    rank = cells[i-1]
                                break
                        if name and name not in seen:
                            seen.add(name)
                            judges.append({'name': name, 'division': current_div or None, 'rank': rank})

        try:
            os.remove(tmp)
        except:
            pass
        return judges
    except Exception as e:
        log(f'    PDF error: {e}')
        return []


def scrape_court(court_name, subdomain, start_urls):
    base = f'https://{subdomain}.judicial.gov.tw'
    judges = []
    seen_names = set()
    seen_urls = set()

    all_urls = list(start_urls)
    # Also try homepage
    all_urls.append('/')

    for start_path in all_urls:
        if judges:
            break
        url = start_path if start_path.startswith('http') else base + start_path
        if url in seen_urls:
            continue
        seen_urls.add(url)

        try:
            resp = session.get(url, timeout=15, allow_redirects=True)
            if resp.status_code != 200:
                continue
            html = resp.content.decode('utf-8', errors='replace')

            # Check for PDF
            dl_links = find_dl_links(html, subdomain)
            for dl in dl_links[:3]:
                pdf_url = dl if dl.startswith('http') else base + dl
                log(f'  嘗試 PDF: ...{pdf_url[-50:]}')
                pdf_judges = download_parse_pdf(pdf_url, court_name)
                if pdf_judges:
                    for j in pdf_judges:
                        if j['name'] not in seen_names:
                            seen_names.add(j['name'])
                            judges.append(j)
                    break

            if judges:
                break

            # Check for HTML judges
            html_judges = extract_judges_html(html)
            for rank, name in html_judges:
                name = name.strip()
                if name not in seen_names and len(name) <= 4:
                    seen_names.add(name)
                    judges.append({'name': name, 'division': '未分類', 'rank': rank})

            if judges:
                break

            # Go deeper - find sub links
            sub_links = find_sub_links(html, base, subdomain)
            for sub_url, sub_text in sub_links[:10]:
                if sub_url in seen_urls:
                    continue
                seen_urls.add(sub_url)
                time.sleep(1)

                try:
                    resp2 = session.get(sub_url, timeout=15, allow_redirects=True)
                    if resp2.status_code != 200:
                        continue
                    html2 = resp2.content.decode('utf-8', errors='replace')

                    # PDF in sub page?
                    dl2 = find_dl_links(html2, subdomain)
                    for dl in dl2[:3]:
                        pdf_url2 = dl if dl.startswith('http') else base + dl
                        log(f'    L2 PDF: ...{pdf_url2[-50:]}')
                        pj2 = download_parse_pdf(pdf_url2, court_name)
                        if pj2:
                            for j in pj2:
                                if j['name'] not in seen_names:
                                    seen_names.add(j['name'])
                                    judges.append(j)
                            break

                    if judges:
                        break

                    # HTML judges in sub page?
                    hj2 = extract_judges_html(html2)
                    div_name = sub_text.replace('法官名錄', '').replace('法官', '').strip() or '未分類'
                    for rank, name in hj2:
                        name = name.strip()
                        if name not in seen_names and len(name) <= 4:
                            seen_names.add(name)
                            judges.append({'name': name, 'division': div_name, 'rank': rank})

                    # Level 3
                    if not judges:
                        sub2 = find_sub_links(html2, base, subdomain)
                        for s2_url, s2_text in sub2[:5]:
                            if s2_url in seen_urls:
                                continue
                            seen_urls.add(s2_url)
                            time.sleep(0.5)
                            try:
                                r3 = session.get(s2_url, timeout=10, allow_redirects=True)
                                h3 = r3.content.decode('utf-8', errors='replace')
                                dl3 = find_dl_links(h3, subdomain)
                                for dl in dl3[:2]:
                                    pu3 = dl if dl.startswith('http') else base + dl
                                    log(f'      L3 PDF: ...{pu3[-50:]}')
                                    pj3 = download_parse_pdf(pu3, court_name)
                                    if pj3:
                                        for j in pj3:
                                            if j['name'] not in seen_names:
                                                seen_names.add(j['name'])
                                                judges.append(j)
                                        break
                                if judges:
                                    break
                                hj3 = extract_judges_html(h3)
                                for rank, name in hj3:
                                    name = name.strip()
                                    if name not in seen_names and len(name) <= 4:
                                        seen_names.add(name)
                                        judges.append({'name': name, 'division': s2_text.strip(), 'rank': rank})
                            except:
                                pass
                except:
                    continue

                if judges:
                    break

        except Exception as e:
            log(f'  Error: {e}')
            continue

    return judges


def main():
    with open('court_judge_urls.json', 'r', encoding='utf-8') as f:
        court_urls = json.load(f)

    all_results = []

    for court_name, info in court_urls.items():
        sub = info['sub']
        urls = info['urls']
        log(f'--- {court_name} ({sub}) ---')

        judges = scrape_court(court_name, sub, urls)
        log(f'  結果: {len(judges)} 位法官')

        if judges:
            records = [{
                'name': j['name'],
                'court_name': normalize_court(court_name),
                'division': j.get('division'),
                'rank': j.get('rank', '法官'),
                'status': '現任',
                'scraped_at': '2026-04-09T00:00:00Z',
            } for j in judges]

            sb.table('jy_judges').upsert(records, on_conflict='name,court_name').execute()
            log(f'  DB 寫入: {len(records)} 筆')

        all_results.append((court_name, len(judges)))
        time.sleep(3)

    log('\n=== 爬取結果 ===')
    total = 0
    for court, count in all_results:
        status = '✓' if count > 0 else '✗'
        log(f'  {status} {court}: {count}')
        total += count
    log(f'  新增: {total}')

    result = sb.table('jy_judges').select('name', count='exact').execute()
    log(f'  DB 總數: {result.count}')


if __name__ == '__main__':
    main()
