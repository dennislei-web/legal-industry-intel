"""
全國律師聯合會 - 全國執行律師職務名單爬蟲
來源：https://nab.twba.org.tw/
無 CAPTCHA，透過姓名查詢取得律師資料

策略：遍歷常見中文姓氏，逐一查詢並彙總
"""
import re
import requests
from bs4 import BeautifulSoup
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

URL = 'https://nab.twba.org.tw/'

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Accept': 'text/html,application/xhtml+xml',
    'Referer': 'https://nab.twba.org.tw/',
}

# 台灣常見姓氏 (覆蓋 99%+ 律師)
SURNAMES = [
    '陳', '林', '黃', '張', '李', '王', '吳', '劉', '蔡', '楊',
    '許', '鄭', '謝', '郭', '洪', '曾', '邱', '廖', '賴', '周',
    '徐', '蘇', '葉', '莊', '呂', '江', '何', '蕭', '羅', '高',
    '潘', '簡', '朱', '鍾', '彭', '游', '詹', '胡', '施', '沈',
    '余', '盧', '梁', '趙', '顏', '柯', '翁', '魏', '孫', '戴',
    '范', '方', '宋', '鄧', '杜', '傅', '侯', '曹', '薛', '丁',
    '卓', '馬', '阮', '董', '温', '唐', '藍', '石', '蔣', '古',
    '紀', '姚', '連', '馮', '歐', '程', '湯', '田', '康', '姜',
    '白', '汪', '鄒', '尤', '巫', '鑰', '鐘', '黎', '涂', '龔',
    '嚴', '韓', '袁', '金', '童', '陸', '夏', '柳', '凃', '邵',
    # 第二批：從 Lawsnote 比對發現缺少的姓氏
    '溫', '鄺', '歐陽', '穆', '段', '孔', '任', '秦', '闕', '賀',
    '雷', '喬', '裴', '甘', '萬', '崔', '談', '賈', '文', '殷',
    '倪', '左', '辛', '錢', '伍', '章', '管', '樊', '郝', '祝',
    '鞏', '成', '包', '屈', '凌', '費', '單', '齊', '梅', '龍',
    '關', '華', '申', '岳', '鄧', '毛', '鮑', '易', '安', '危',
    '全', '覃', '向', '俞', '耿', '植', '聶', '景', '池', '畢',
]


def get_viewstate(session):
    """取得 ASP.NET ViewState 等隱藏欄位"""
    resp = session.get(URL, headers=HEADERS, timeout=30)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, 'html.parser')

    fields = {}
    for name in ['__VIEWSTATE', '__VIEWSTATEGENERATOR', '__EVENTVALIDATION',
                  '__EVENTTARGET', '__EVENTARGUMENT', '__VIEWSTATEENCRYPTED',
                  'ToolkitScriptManager1_HiddenField']:
        tag = soup.find('input', {'name': name})
        if tag:
            fields[name] = tag.get('value', '')

    return fields


def parse_table_page(soup):
    """解析單頁表格結果"""
    table = soup.find('table', {'id': 'GView_PIO'})
    if not table:
        return [], False

    rows = table.find_all('tr')
    results = []
    has_next_page = False

    for row in rows[1:]:  # 跳過表頭
        cells = row.find_all('td')
        if len(cells) >= 4:
            lawyer_name = cells[0].get_text(strip=True)
            bar_association = cells[1].get_text(strip=True)
            practice_start = cells[2].get_text(strip=True)
            practice_end = cells[3].get_text(strip=True)

            if lawyer_name:
                results.append({
                    'name': lawyer_name,
                    'bar_association': bar_association,
                    'practice_start': practice_start,
                    'practice_end': practice_end,
                })

        # 檢查是否有分頁列（包含 '...' 或數字連結）
        pager_links = row.find_all('a', href=True)
        for link in pager_links:
            href = link.get('href', '')
            if "Page$" in href or "Page$Next" in href:
                has_next_page = True

    return results, has_next_page


def update_viewstate(soup, viewstate):
    """從回傳頁面更新 ViewState"""
    for field_name in ['__VIEWSTATE', '__VIEWSTATEGENERATOR', '__EVENTVALIDATION',
                        '__VIEWSTATEENCRYPTED']:
        tag = soup.find('input', {'name': field_name})
        if tag:
            viewstate[field_name] = tag.get('value', '')


def search_by_name(session, viewstate, name):
    """以姓名查詢，支援分頁，回傳所有頁面的律師列表"""
    # 第一頁：送出查詢
    data = dict(viewstate)
    data['tb_CName'] = name
    data['Button1'] = '查詢'

    resp = session.post(URL, data=data, headers=HEADERS, timeout=60)
    resp.raise_for_status()
    resp.encoding = 'utf-8'

    soup = BeautifulSoup(resp.text, 'html.parser')
    update_viewstate(soup, viewstate)

    results, has_next = parse_table_page(soup)
    all_results = list(results)

    # 分頁處理：如果有下一頁，繼續抓取
    page = 2
    max_pages = 20  # 安全上限
    while has_next and page <= max_pages:
        polite_delay(1.0)
        log(f'    → 翻頁 {page}...')

        data = dict(viewstate)
        data['__EVENTTARGET'] = 'GView_PIO'
        data['__EVENTARGUMENT'] = f'Page${page}'
        data['tb_CName'] = name

        try:
            resp = session.post(URL, data=data, headers=HEADERS, timeout=60)
            resp.raise_for_status()
            resp.encoding = 'utf-8'
            soup = BeautifulSoup(resp.text, 'html.parser')
            update_viewstate(soup, viewstate)

            results, has_next = parse_table_page(soup)
            if not results:
                break
            all_results.extend(results)
            page += 1
        except Exception as e:
            log(f'    → 分頁 {page} 失敗: {e}')
            break

    return all_results


def normalize_bar_association(raw):
    """正規化公會名稱 → 地區"""
    # 社團法人宜蘭律師公會 → 宜蘭
    # 社團法人台北律師公會 → 台北
    cleaned = raw.replace('社團法人', '').replace('律師公會', '').replace('臺', '台').strip()
    return cleaned


def parse_practice_date(ym_str):
    """將 2026/01 轉為 2026-01-01 格式"""
    if not ym_str or '/' not in ym_str:
        return None
    parts = ym_str.split('/')
    if len(parts) == 2:
        return f"{parts[0]}-{parts[1].zfill(2)}-01"
    return None


def save_lawyers(sb, all_lawyers):
    """批次寫入 lawyer_members 表"""
    records = []
    seen = set()

    for l in all_lawyers:
        # 用 name + bar_association 去重
        key = f"{l['name']}|{l['bar_association']}"
        if key in seen:
            continue
        seen.add(key)

        region = normalize_bar_association(l['bar_association'])
        practice_start = parse_practice_date(l['practice_start'])
        practice_end = parse_practice_date(l['practice_end'])

        # 判斷是否執業中
        is_active = l['practice_end'] >= '2026/01' if l['practice_end'] else False

        records.append({
            'name': l['name'],
            'bar_association': l['bar_association'],
            'region': region,
            'practice_start_date': practice_start,
            'practice_end_date': practice_end,
            'is_active': is_active,
            'source': 'twba_nab',
            'source_url': 'https://nab.twba.org.tw/',
        })

    log(f'去重後共 {len(records)} 筆律師資料')

    # 批次 upsert
    batch_size = 200
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        sb.table('lawyer_members').upsert(
            batch, on_conflict='name,bar_association'
        ).execute()
        if i + batch_size < len(records):
            polite_delay(0.3)

    log(f'已寫入 {len(records)} 筆至 lawyer_members')
    return len(records)


def main():
    sb = get_supabase()
    log_id = scrape_start(sb, 'twba_lawyers')

    try:
        session = requests.Session()

        # 取得初始 ViewState
        log('取得初始頁面 ViewState...')
        viewstate = get_viewstate(session)
        log('ViewState 取得成功')

        all_lawyers = []
        total_surnames = len(SURNAMES)

        for idx, surname in enumerate(SURNAMES, 1):
            log(f'[{idx}/{total_surnames}] 查詢姓氏: {surname}')

            try:
                results = search_by_name(session, viewstate, surname)
                log(f'  → 找到 {len(results)} 筆')
                all_lawyers.extend(results)
            except Exception as e:
                log(f'  → 查詢失敗: {e}')
                # 重新取得 ViewState
                try:
                    session = requests.Session()
                    viewstate = get_viewstate(session)
                    log('  → 已重新取得 ViewState')
                except Exception:
                    pass

            # 禮貌延遲
            polite_delay(1.0)

        log(f'所有姓氏查詢完成，共 {len(all_lawyers)} 筆 (含重複)')

        # 儲存至 Supabase
        unique_count = save_lawyers(sb, all_lawyers)

        scrape_end(sb, log_id, status='success',
                   records_found=len(all_lawyers),
                   records_inserted=unique_count,
                   records_updated=0)

        log(f'=== 全聯會律師爬蟲完成 ===')
        log(f'查詢姓氏數: {total_surnames}')
        log(f'原始筆數: {len(all_lawyers)}')
        log(f'去重後: {unique_count}')

    except Exception as e:
        log(f'爬蟲錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise


if __name__ == '__main__':
    main()
