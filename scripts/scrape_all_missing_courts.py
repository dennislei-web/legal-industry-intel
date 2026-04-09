"""
爬取所有未覆蓋法院的法官資料
多策略：PDF 表格 / HTML 表格 / 職稱_姓名連結 / 頁面文字擷取
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

# 所有未覆蓋法院的子域名
ALL_COURTS = {
    # 最高法院
    '最高法院': 'tps',
    '最高行政法院': 'tpa',
    # 高等法院
    '臺灣高等法院臺中分院': 'tch',
    '臺灣高等法院臺南分院': 'tnh',
    '臺灣高等法院高雄分院': 'ksh',
    '臺灣高等法院花蓮分院': 'hlh',
    '臺北高等行政法院': 'tpb',
    '臺中高等行政法院': 'tcb',
    '高雄高等行政法院': 'ksb',
    # 專業法院
    '智慧財產及商業法院': 'ipc',
    '懲戒法院': 'tpp',
    '臺灣高雄少年及家事法院': 'ksy',
    # 地方法院（之前失敗的）
    '臺灣新竹地方法院': 'scd',
    '臺灣南投地方法院': 'ntd',
    '臺灣彰化地方法院': 'chd',
    '臺灣雲林地方法院': 'uld',
    '臺灣嘉義地方法院': 'cyd',
    '臺灣高雄地方法院': 'ksd',
    '臺灣橋頭地方法院': 'ctd',
    '臺灣臺東地方法院': 'ttd',
    '臺灣花蓮地方法院': 'hld',
    '臺灣基隆地方法院': 'kld',
    '臺灣澎湖地方法院': 'phd',
    '福建金門地方法院': 'kmd',
    '福建連江地方法院': 'lcd',
}


def normalize_court(name):
    return name.replace('台灣', '臺灣').strip()


def get_page(url, timeout=15):
    """取得頁面 HTML，處理 redirect"""
    try:
        resp = session.get(url, timeout=timeout, allow_redirects=True)
        if resp.status_code == 200:
            return resp.content.decode('utf-8', errors='replace'), resp.url
    except:
        pass
    return None, None


def extract_table_judges(html):
    """策略 A: HTML 表格（<td>職稱</td><td>姓名</td>）"""
    judges = []
    seen = set()
    rows = re.findall(r'<tr[^>]*>(.*?)</tr>', html, re.DOTALL)
    for row in rows:
        cells = re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL)
        if len(cells) >= 2:
            rank = re.sub(r'<[^>]+>', '', cells[0]).strip().replace('\n', '')
            name = re.sub(r'<[^>]+>', '', cells[1]).strip().replace('\n', '')
            if re.match(r'^(院長|庭長|法官兼庭長|法官兼審判長|審判長|法官)', rank) and re.match(r'^[\u4e00-\u9fff]{2,4}$', name):
                if name not in seen:
                    seen.add(name)
                    judges.append({'name': name, 'rank': rank})
    return judges


def extract_link_judges(html):
    """策略 B: 連結格式（>職稱_姓名<）"""
    judges = []
    seen = set()
    matches = re.findall(r'>(院長|庭長|法官兼庭長|法官兼審判長|審判長|法官)[_＿]([^<]{1,10})<', html)
    for rank, name in matches:
        name = name.strip()
        if re.match(r'^[\u4e00-\u9fff]{2,4}$', name) and name not in seen:
            seen.add(name)
            judges.append({'name': name, 'rank': rank})
    return judges


def extract_pdf_judges(pdf_url):
    """策略 C: 下載 PDF 並解析表格"""
    try:
        resp = session.get(pdf_url, timeout=30)
        if resp.content[:4] != b'%PDF':
            return []
        tmp = tempfile.mktemp(suffix='.pdf')
        with open(tmp, 'wb') as f:
            f.write(resp.content)
        judges = []
        seen = set()
        with pdfplumber.open(tmp) as pdf:
            cur_div = ''
            for page in pdf.pages:
                for table in page.extract_tables():
                    for row in table:
                        if not row:
                            continue
                        cells = [c.strip().replace('\n', '') if c else '' for c in row]
                        if any(h in ''.join(cells) for h in ['庭別', '職稱', '姓名', '現辦事']):
                            continue
                        if cells[0] and '庭' in cells[0]:
                            cur_div = cells[0]
                        for i, c in enumerate(cells):
                            if re.match(r'^[\u4e00-\u9fff]{2,4}$', c) and '庭' not in c and '事' not in c:
                                if c not in seen:
                                    seen.add(c)
                                    rank = cells[i-1] if i > 0 and cells[i-1] else '法官'
                                    judges.append({'name': c, 'division': cur_div or None, 'rank': rank})
                                break
        os.remove(tmp)
        return judges
    except:
        return []


def find_dl_links(html, subdomain):
    """找同域名的 PDF 下載連結"""
    dls = re.findall(r'(?:href|src)=["\'](/tw/dl-[^"\']*)["\']', html)
    dls += re.findall(r'(?:href|src)=["\'](https?://[^"\']*' + subdomain + r'[^"\']*/tw/dl-[^"\']*)["\']', html)
    return list(set(dls))


def find_judge_links(html, base, subdomain):
    """找法官名錄相關的子連結"""
    links = re.findall(r'href=["\'](/tw/(?:np|lp|cp)-[^"\']*)["\'][^>]*>([^<]*)', html)
    links += re.findall(r'href=["\'](https?://[^"\']*' + subdomain + r'[^"\']*/tw/(?:np|lp|cp)-[^"\']*)["\'][^>]*>([^<]*)', html)
    result = []
    seen = set()
    for href, text in links:
        text = text.strip()
        url = href if href.startswith('http') else base + href
        if url in seen or subdomain not in url:
            continue
        if '法官' in text or '名錄' in text or '名冊' in text or '事務分配' in text:
            if '國民' not in text and '學院' not in text and '助理' not in text and '轉任' not in text:
                seen.add(url)
                result.append((url, text))
    return result


def scrape_court(court_name, subdomain):
    """用多策略嘗試爬取法官資料"""
    base = f'https://{subdomain}.judicial.gov.tw'
    all_judges = []
    seen_names = set()
    seen_urls = set()

    def add_judges(judges, division=None):
        for j in judges:
            if j['name'] not in seen_names:
                seen_names.add(j['name'])
                j['division'] = j.get('division', division)
                all_judges.append(j)

    def try_page(url, depth=0, max_depth=3):
        """遞迴嘗試頁面"""
        if url in seen_urls or depth > max_depth:
            return
        seen_urls.add(url)

        html, final_url = get_page(url)
        if not html:
            return

        # 嘗試 PDF
        dls = find_dl_links(html, subdomain)
        for dl in dls[:3]:
            dl_url = dl if dl.startswith('http') else base + dl
            judges = extract_pdf_judges(dl_url)
            if judges:
                log(f'  {"  " * depth}PDF: {len(judges)} 位 ({dl_url[-40:]})')
                add_judges(judges)
                return

        # 嘗試 HTML 表格
        judges = extract_table_judges(html)
        if judges:
            log(f'  {"  " * depth}表格: {len(judges)} 位')
            add_judges(judges)
            return

        # 嘗試連結格式
        judges = extract_link_judges(html)
        if judges:
            log(f'  {"  " * depth}連結: {len(judges)} 位')
            add_judges(judges)
            return

        # 深入子連結
        sub_links = find_judge_links(html, base, subdomain)
        for sub_url, sub_text in sub_links[:8]:
            time.sleep(0.5)
            try_page(sub_url, depth + 1, max_depth)
            if all_judges:
                return

    # Level 0: 首頁
    try_page(base)

    return all_judges


def main():
    # 查目前已有的法院
    result = sb.table('jy_judges').select('court_name').execute()
    from collections import Counter
    covered = set(Counter(j['court_name'] for j in result.data).keys())

    # 只處理未覆蓋的
    todo = {k: v for k, v in ALL_COURTS.items() if normalize_court(k) not in covered}

    log(f'=== 開始爬取 {len(todo)} 個未覆蓋法院 ===')

    results = []
    for court_name, sub in todo.items():
        log(f'\n--- {court_name} ({sub}) ---')

        judges = scrape_court(court_name, sub)
        log(f'  結果: {len(judges)} 位法官')

        if judges:
            records = [{
                'name': j['name'],
                'court_name': normalize_court(court_name),
                'division': j.get('division'),
                'rank': j.get('rank', '法官'),
                'status': '現任',
                'scraped_at': '2026-04-09T03:00:00Z',
            } for j in judges]

            sb.table('jy_judges').upsert(records, on_conflict='name,court_name').execute()
            log(f'  DB: {len(records)} 筆')

        results.append((court_name, len(judges)))
        time.sleep(3)

    # 彙總
    log('\n=== 爬取結果 ===')
    total_new = 0
    for court, count in results:
        status = '✓' if count > 0 else '✗'
        log(f'  {status} {court}: {count}')
        total_new += count
    log(f'  新增: {total_new}')

    result = sb.table('jy_judges').select('name', count='exact').execute()
    log(f'  DB 總數: {result.count}')


if __name__ == '__main__':
    main()
