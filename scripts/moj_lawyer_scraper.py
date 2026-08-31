"""
法務部律師查詢系統爬蟲
來源：https://lawyerbc.moj.gov.tw/

已確認的 API endpoints (免 CAPTCHA):
  /api/cert/sdlyguild/summary  - 各公會會員人數統計
  /api/cert/sdlyguild/info     - 各公會聯絡資訊
  /api/cert/lyinfosd/notice/upDate - 資料更新日期

個別律師查詢需要 CAPTCHA，留待後續實作。
"""
import json
import time
import requests
from datetime import datetime
from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

BASE_URL = 'https://lawyerbc.moj.gov.tw/api'

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Accept': 'application/json',
    'Referer': 'https://lawyerbc.moj.gov.tw/',
}

# 公會 ID → 地區對應
GUILD_REGION_MAP = {
    'TBA': '全國',
    'TPBA': '台北',
    'KLBA': '基隆',
    'ILBA': '宜蘭',
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
    'TTBA': '台東',
    'HLBA': '花蓮',
}


# GitHub runner 偶發連不到 lawyerbc（Errno 101 Network is unreachable，2026-08-23、08-30
# 兩次週更都是首次連線就死）。同 host 的 moj_licno_scan.py 有 retry 所以沒事，這裡補上。
RETRY_DELAYS = [15, 30, 60, 120]


def _get_json(path):
    """帶退避重試的 GET；連線類錯誤才重試，HTTP 4xx/5xx 直接拋"""
    last_err = None
    for attempt in range(len(RETRY_DELAYS) + 1):
        try:
            resp = requests.get(f'{BASE_URL}{path}', headers=HEADERS, timeout=30)
            resp.raise_for_status()
            return resp.json()
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            last_err = e
            if attempt < len(RETRY_DELAYS):
                wait = RETRY_DELAYS[attempt]
                log(f'  ! 連線失敗 ({attempt + 1}/{len(RETRY_DELAYS) + 1})，{wait} 秒後重試: {e}')
                time.sleep(wait)
    raise RuntimeError(f'連線 {path} 重試 {len(RETRY_DELAYS) + 1} 次仍失敗: {last_err}')


def fetch_guild_summary():
    """取得各律師公會會員人數統計"""
    log('取得各公會會員統計...')
    data = _get_json('/cert/sdlyguild/summary')

    if data.get('status') != 1:
        raise Exception(f"API 回應異常: {data}")

    guilds = data['data']
    total = sum(g['count'] for g in guilds)
    log(f'共 {len(guilds)} 個公會，合計 {total} 位律師')
    return guilds


def fetch_guild_info():
    """取得各律師公會聯絡資訊"""
    log('取得各公會聯絡資訊...')
    data = _get_json('/cert/sdlyguild/info')

    if data.get('status') != 1:
        raise Exception(f"API 回應異常: {data}")

    return data['data']


def fetch_update_date():
    """取得資料最後更新日期"""
    data = _get_json('/cert/lyinfosd/notice/upDate')
    return data.get('data', '')


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
            'source_url': 'https://lawyerbc.moj.gov.tw/',
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
        'source_url': 'https://lawyerbc.moj.gov.tw/',
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
            'source_url': 'https://lawyerbc.moj.gov.tw/guild/info',
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
