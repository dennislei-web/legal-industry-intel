"""
Lawsnote 律師專長資料爬蟲
來源：https://page.lawsnote.com/search/expertise/{case_type}/{region}/
抓取各案件類型 x 地區的律師清單，彙整後 upsert 至 lawsnote_lawyers 表

策略：遍歷 27 種案件類型 x 17 個地區 = 459 組合
每組合 GET 一頁 HTML，解析 <article> 元素取得律師資料
"""
import re
import requests
from urllib.parse import quote
from bs4 import BeautifulSoup
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

BASE_URL = 'https://page.lawsnote.com'

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
    'Referer': 'https://page.lawsnote.com/',
}

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
    '鄰居間糾爭/管委會相關/祭祀公業',
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

# 17 個地區
REGIONS = [
    '台北', '新北', '基隆', '桃園', '新竹', '苗栗',
    '台中', '彰化', '南投', '雲林', '嘉義',
    '台南', '高雄', '屏東', '台東', '花蓮', '宜蘭',
]


def build_url(case_type, region):
    """組合搜尋 URL，中文 path 需要 URL encode"""
    encoded_case = quote(case_type, safe='')
    encoded_region = quote(region, safe='')
    return f'{BASE_URL}/search/expertise/{encoded_case}/{encoded_region}/'


def parse_listing_page(html, case_type, region):
    """
    解析搜尋結果頁面，回傳律師列表
    每個 <article> 包含：律師名、近5年案件數、lawsnote_id (from link)
    """
    soup = BeautifulSoup(html, 'html.parser')
    articles = soup.find_all('article')
    results = []

    for article in articles:
        try:
            # 律師名稱 - 在 h2 或 h3 標籤中
            name_tag = article.find(['h2', 'h3'])
            if not name_tag:
                continue
            name = name_tag.get_text(strip=True)
            if not name:
                continue

            # 近5年案件數
            case_count = None
            text = article.get_text()
            match = re.search(r'近5年案件數[：:]\s*(\d[\d,]*)', text)
            if match:
                case_count = int(match.group(1).replace(',', ''))

            # lawsnote_id from link (/page/{id})
            lawsnote_id = None
            link = article.find('a', href=re.compile(r'/page/'))
            if link:
                href = link.get('href', '')
                id_match = re.search(r'/page/([^/?\s]+)', href)
                if id_match:
                    lawsnote_id = id_match.group(1)

            if not lawsnote_id:
                continue

            results.append({
                'lawsnote_id': lawsnote_id,
                'name': name,
                'case_count_5yr': case_count,
            })

        except Exception as e:
            log(f'  解析 article 失敗: {e}')
            continue

    return results


def scrape_all_combos(session):
    """
    遍歷所有 case_type x region 組合
    回傳 dict: lawsnote_id -> { name, case_count_5yr, expertise_areas, regions }
    """
    lawyers = {}  # lawsnote_id -> merged data
    total_combos = len(CASE_TYPES) * len(REGIONS)
    combo_idx = 0
    errors = 0

    for case_type in CASE_TYPES:
        for region in REGIONS:
            combo_idx += 1
            url = build_url(case_type, region)

            try:
                resp = session.get(url, headers=HEADERS, timeout=30)
                resp.raise_for_status()
                resp.encoding = 'utf-8'

                results = parse_listing_page(resp.text, case_type, region)

                for r in results:
                    lid = r['lawsnote_id']
                    if lid not in lawyers:
                        lawyers[lid] = {
                            'lawsnote_id': lid,
                            'name': r['name'],
                            'case_count_5yr': r['case_count_5yr'],
                            'expertise_areas': set(),
                            'regions': set(),
                        }
                    else:
                        # 更新案件數為最大值 (同律師在不同組合可能顯示不同)
                        if r['case_count_5yr'] is not None:
                            existing = lawyers[lid]['case_count_5yr']
                            if existing is None or r['case_count_5yr'] > existing:
                                lawyers[lid]['case_count_5yr'] = r['case_count_5yr']

                    lawyers[lid]['expertise_areas'].add(case_type)
                    lawyers[lid]['regions'].add(region)

                if combo_idx % 17 == 0 or combo_idx == total_combos:
                    log(f'[{combo_idx}/{total_combos}] {case_type} / {region}'
                        f' → {len(results)} 筆, 累計 {len(lawyers)} 位律師')

            except requests.exceptions.HTTPError as e:
                if e.response is not None and e.response.status_code == 404:
                    # 某些組合可能無結果頁面
                    pass
                else:
                    errors += 1
                    log(f'[{combo_idx}/{total_combos}] HTTP 錯誤 {case_type}/{region}: {e}')
            except Exception as e:
                errors += 1
                log(f'[{combo_idx}/{total_combos}] 錯誤 {case_type}/{region}: {e}')

            # 禮貌延遲 1-2 秒
            polite_delay(1.5)

    log(f'所有組合爬取完成，共 {len(lawyers)} 位不重複律師，{errors} 個錯誤')
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
            'regions': sorted(data['regions']),
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

    try:
        session = requests.Session()

        log('=== Lawsnote 律師專長爬蟲開始 ===')
        log(f'案件類型: {len(CASE_TYPES)} 種')
        log(f'地區: {len(REGIONS)} 個')
        log(f'組合數: {len(CASE_TYPES) * len(REGIONS)}')

        # Phase 1: 爬取所有組合
        lawyers_dict = scrape_all_combos(session)

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


if __name__ == '__main__':
    main()
