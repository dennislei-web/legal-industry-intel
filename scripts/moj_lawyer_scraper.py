"""
法務部律師查詢系統爬蟲（公會人數統計＋公會聯絡資訊）
來源：https://lawyerbc.moj.gov.tw/

2026-10-29 官網改版：舊 /api/cert/sdlyguild/* JSON 端點下架，改讀新站伺服器端渲染的 HTML（免驗證碼）：
  /Home/GuildCounter  - 16 個地方公會「XXX律師公會 N 筆」（取代 sdlyguild/summary）
  /Guild/Info         - 公會名稱／地址及服務信箱／電話／傳真表格（取代 sdlyguild/info）
  /                   - 首頁「事務所及公會資料更新截止日：民國115年10月29日」（取代 lyinfosd/notice/upDate）

個別律師查詢需人工驗證碼，不在本程式範圍（見 docs/moj-site-redesign-2026-10.md）。
"""
import json
import re
import time
import requests
from bs4 import BeautifulSoup
from datetime import datetime
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

BASE_URL = 'https://lawyerbc.moj.gov.tw'

HEADERS = {
    'User-Agent': 'LegalIndustryIntel/1.0',
    'Accept': 'text/html',
    'Referer': 'https://lawyerbc.moj.gov.tw/',
}

# 公會 ID → 地區對應（ID 沿用舊 API，law_firms.registration_number = GUILD-{ID}；
# 宜蘭 ELBA、台東 TDBA 以 DB 既有列為準）
GUILD_REGION_MAP = {
    'TBA': '全國',
    'TPBA': '台北',
    'KLBA': '基隆',
    'ELBA': '宜蘭',
    'HCBA': '新竹',
    'TYBA': '桃園',
    'MLBA': '苗栗',
    'TCBA': '台中',
    'CHBA': '彰化',
    'NTBA': '南投',
    'CYBA': '嘉義',
    'YLBA': '雲林',
    'TNBA': '台南',
    'KSBA': '高雄',
    'PTBA': '屏東',
    'TDBA': '台東',
    'HLBA': '花蓮',
}
_REGION_TO_ID = {v: k for k, v in GUILD_REGION_MAP.items()}


def guild_id(name):
    """'台北律師公會'／'臺北律師公會' → 'TPBA'；全聯會 → 'TBA'"""
    n = (name or '').replace('臺', '台').replace('社團法人', '').strip()
    if '全國' in n or '聯合會' in n:
        return 'TBA'
    return _REGION_TO_ID.get(n.replace('律師公會', ''))


# GitHub runner 偶發連不到 lawyerbc（Errno 101 Network is unreachable，2026-08-23、08-30
# 兩次週更都是首次連線就死）→ 連線類錯誤退避重試
RETRY_DELAYS = [15, 30, 60, 120]


def _get_html(path):
    """帶退避重試的 GET；連線類錯誤才重試，HTTP 4xx/5xx 直接拋"""
    last_err = None
    for attempt in range(len(RETRY_DELAYS) + 1):
        try:
            resp = requests.get(f'{BASE_URL}{path}', headers=HEADERS, timeout=30)
            resp.raise_for_status()
            resp.encoding = 'utf-8'
            return resp.text
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_err = e
            if attempt < len(RETRY_DELAYS):
                wait = RETRY_DELAYS[attempt]
                log(f'  ! 連線失敗 ({attempt + 1}/{len(RETRY_DELAYS) + 1})，{wait} 秒後重試: {e}')
                time.sleep(wait)
    raise RuntimeError(f'連線 {path} 重試 {len(RETRY_DELAYS) + 1} 次仍失敗: {last_err}')


def parse_guild_counter(html):
    """GuildCounter HTML → [{'name': '台北律師公會', 'count': 8531}, ...]"""
    soup = BeautifulSoup(html, 'html.parser')
    out = []
    for card in soup.select('.guild-counter-card'):
        name_el, cnt_el = card.select_one('.guild-counter-name'), card.select_one('.guild-counter-count')
        if not name_el or not cnt_el:
            continue
        m = re.search(r'([\d,]+)', cnt_el.get_text())
        if m:
            out.append({'name': name_el.get_text(strip=True), 'count': int(m.group(1).replace(',', ''))})
    return out


def fetch_guild_summary():
    """取得各律師公會會員人數統計"""
    log('取得各公會會員統計（/Home/GuildCounter）...')
    guilds = parse_guild_counter(_get_html('/Home/GuildCounter'))
    # 版面防呆：改版前後都是 16 個地方公會；數量差太多代表 HTML 結構又變了，寧可紅燈也不寫錯數字
    if len(guilds) < 14 or any(g['count'] <= 0 for g in guilds):
        raise RuntimeError(f'GuildCounter 解析結果異常：{len(guilds)} 個公會，請檢查版面是否改了')
    total = sum(g['count'] for g in guilds)
    log(f'共 {len(guilds)} 個公會，合計 {total} 位律師')
    return guilds


def parse_guild_info(html):
    """Guild/Info 表格 → [{'id','name','zip','address','email','phone','fax'}, ...]"""
    soup = BeautifulSoup(html, 'html.parser')
    out = []
    for tr in soup.select('tr.guild-row'):
        tds = tr.find_all('td')
        if len(tds) < 4:
            continue
        name = tds[0].get_text(strip=True)
        addr_el = tds[1].select_one('.guild-address-text')
        address = addr_el.get_text(strip=True) if addr_el else ''
        strings = [s.strip() for s in tds[1].stripped_strings]
        zip_code = strings[0] if strings and re.fullmatch(r'\d{3,6}', strings[0]) else ''
        email = next((s for s in strings if '@' in s), '')
        out.append({
            'id': guild_id(name),
            'name': name,
            'zip': zip_code,
            'address': [address] if address else [],
            'email': email,
            'phone': [tds[2].get_text(strip=True)],
            'fax': [tds[3].get_text(strip=True)],
        })
    return out


def fetch_guild_info():
    """取得各律師公會聯絡資訊"""
    log('取得各公會聯絡資訊（/Guild/Info）...')
    info = parse_guild_info(_get_html('/Guild/Info'))
    if len(info) < 14:
        raise RuntimeError(f'Guild/Info 解析結果異常：{len(info)} 列，請檢查版面是否改了')
    unknown = [g['name'] for g in info if not g['id']]
    if unknown:
        log(f'  ! 對不上公會 ID、略過：{unknown}')
    return [g for g in info if g['id']]


def fetch_update_date():
    """首頁「事務所及公會資料更新截止日」（只記 log）"""
    html = _get_html('/')
    text = BeautifulSoup(html, 'html.parser').get_text(' ', strip=True)
    m = re.search(r'更新截止日[：:]\s*(民國\s*\d+\s*年\s*\d+\s*月\s*\d+\s*日)', text)
    return m.group(1).replace(' ', '') if m else '（首頁找不到更新截止日）'


def save_guild_stats(sb, guilds):
    """將公會統計存入 industry_stats"""
    year = datetime.now().year
    month = datetime.now().month

    records = []
    total = 0
    for g in guilds:
        name = g['name']
        count = g['count']
        total += count

        # 從名稱提取地區
        region = name.replace('律師公會', '')
        records.append({
            'year': year,
            'month': month,
            'stat_type': 'guild_lawyer_count',
            'value': count,
            'unit': '人',
            'region': region,
            'source': 'moj_lawyerbc',
            'source_url': 'https://lawyerbc.moj.gov.tw/Home/GuildCounter',
            'notes': name,
        })

    # 全國總計
    records.append({
        'year': year,
        'month': month,
        'stat_type': 'lawyer_count',
        'value': total,
        'unit': '人',
        'region': None,
        'source': 'moj_lawyerbc',
        'source_url': 'https://lawyerbc.moj.gov.tw/Home/GuildCounter',
        'notes': f'全國執業律師合計 ({len(guilds)} 個公會)',
    })

    # Upsert by unique constraint (year, month, stat_type, region)
    for r in records:
        sb.table('industry_stats').upsert(
            r, on_conflict='year,month,stat_type,region'
        ).execute()

    log(f'已寫入 {len(records)} 筆公會統計 (含全國合計)')
    return len(records)


def save_guild_info_as_firms(sb, guild_info):
    """將公會資訊存入 law_firms (作為組織記錄)"""
    records = []
    for g in guild_info:
        if g['id'] == 'TBA':  # 全聯會不是事務所
            continue

        region = GUILD_REGION_MAP.get(g['id'], '')
        address = g.get('address', [''])[0] if g.get('address') else ''
        phone = g.get('phone', [''])[0] if g.get('phone') else ''

        records.append({
            'name': g['name'],
            'registration_number': f"GUILD-{g['id']}",
            'address': address,
            'city': region,
            'phone': phone,
            'status': 'active',
            'organization_type': '律師公會',
            'source': 'moj_lawyerbc',
            'source_url': 'https://lawyerbc.moj.gov.tw/Guild/Info',
            'raw_data': json.dumps(g, ensure_ascii=False),
        })

    for r in records:
        sb.table('law_firms').upsert(
            r, on_conflict='registration_number'
        ).execute()

    log(f'已寫入 {len(records)} 筆公會組織資料')
    return len(records)


def main():
    sb = get_supabase()
    log_id = scrape_start(sb, 'moj_lawyers')

    try:
        # 1. 取得並儲存公會統計
        guilds = fetch_guild_summary()
        polite_delay()

        stats_count = save_guild_stats(sb, guilds)

        # 2. 取得並儲存公會資訊
        guild_info = fetch_guild_info()
        polite_delay()

        org_count = save_guild_info_as_firms(sb, guild_info)

        # 3. 取得更新日期
        update_date = fetch_update_date()
        log(f'法務部資料更新日期: {update_date}')

        total_found = len(guilds) + len(guild_info)
        total_inserted = stats_count + org_count

        scrape_end(sb, log_id, status='success',
                   records_found=total_found,
                   records_inserted=total_inserted,
                   records_updated=0)

        log('=== 法務部爬蟲完成 ===')
        log(f'公會數: {len(guilds)}')
        log(f'律師總數: {sum(g["count"] for g in guilds)}')

    except Exception as e:
        log(f'爬蟲錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise


if __name__ == '__main__':
    main()
