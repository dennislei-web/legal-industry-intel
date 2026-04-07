"""
MOJ lawyerbc.moj.gov.tw 個別律師全量爬蟲

破解重點：
1. /api/cert/captcha 回傳的 text 欄位是 base64 編碼的驗證碼答案（以「、」分隔）
2. POST /api/cert/lydatalic/search 需要 {keyword, token, id}
   - token = 解碼後去掉分隔符的答案
   - id = captcha 回傳的 text (原始 base64)
3. 每次查詢最多 100 筆，超過會 total=0 回傳空陣列
4. 策略：先查單字姓氏，若 total=0 (>100 截斷) 就展開雙字 (姓+名第一字)

律師資料欄位：name, now_lic_no, court, guild_name, office, sex

使用方式：
  python moj_lawyer_fullscan.py demo   # 只跑 5 個姓氏測試
  python moj_lawyer_fullscan.py full   # 完整掃描 + 寫入 Supabase
  python moj_lawyer_fullscan.py scan   # 完整掃描但只寫 JSON，不入 DB
"""
import base64
import json
import os
import re
import time
import requests
import urllib3
from typing import Optional

urllib3.disable_warnings()

BASE = 'https://lawyerbc.moj.gov.tw/api'
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Referer': 'https://lawyerbc.moj.gov.tw/',
    'Origin': 'https://lawyerbc.moj.gov.tw',
    'Accept': 'application/json, text/plain, */*',
}

# 台灣常見姓氏（前 100 + 罕見補充 35 個）
COMMON_SURNAMES = list('陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴徐周葉蘇莊呂江何羅高蕭潘朱簡鍾彭游詹胡施沈余趙盧梁顏柯孫魏翁戴范方宋鄧杜傅侯曹薛丁卓阮馬董温唐藍石蔣古紀姚連馮歐程湯田康姜汪白鄒尤巫鐘龔嚴韓袁金童陸夏柳凃邵錢伍倪涂雷俞孔易段毛甘萬秦賈龍任凌包崔文殷章岳熊申聶華辛郝闕關穆梅苗費賀喬鄺')

# 台灣名字第一字高頻用字（擴充至 ~300 字，涵蓋更多組合）
COMMON_NAME_CHARS = list(dict.fromkeys(
    '志明文國家建宗信德仁義英俊豪偉正中華美秀惠芳麗玲君瑜真珍雅淑娟婷芬玉雪梅蘭慧萍靜敏智勇強豐育成傑杰銘峰嘉弘宏振誠謙安良彥展福春秋冬東西南北昌興隆泰和平樂民本立大勝承繼先進新昇陞輝煌耀光賢聖仙佑佳珮庭昕翔然斌柏森鴻宇軒辰晨睿淳潔穎瑋瑄盈婕筠筱韻靈仲孟叔季益廣琦琳薇蓉馨娜婉媛怡'
    '世永裕政哲維瀚博群凱威浩宸祥天崇晉毅恆延元亮紹定禮禎祺棋麟達鎮啟祐澤思詠鋒奕昊學勳書銓耿宜彬政暐昱朗清晟俐妤蕙凡允芝如妍寧瑩容碧素湘蓮蕊桂彩彤恩純絲菁敬茂昆昭錫圳吉利杉熙琪綺'
))


def new_session():
    s = requests.Session()
    s.verify = False
    s.headers.update(HEADERS)
    return s


def get_captcha(sess):
    r = sess.get(f'{BASE}/cert/captcha', timeout=15)
    r.raise_for_status()
    d = r.json()['data']
    text_b64 = d['text']
    decoded = base64.b64decode(text_b64).decode('utf-8')
    answer = re.sub(r'[、,，\s]', '', decoded)
    return answer, text_b64


def search_lawyers(keyword: str, retries: int = 3) -> Optional[dict]:
    """查詢律師。回傳 {lawyers, total} 或 None。"""
    last_err = None
    for attempt in range(retries):
        try:
            sess = new_session()
            answer, token_id = get_captcha(sess)
            body = {'keyword': keyword, 'token': answer, 'id': token_id}
            r = sess.post(f'{BASE}/cert/lydatalic/search', json=body, timeout=15)
            if r.status_code == 200:
                return r.json().get('data', {})
            if r.status_code == 406:
                # 驗證碼驗證失敗，重試（應該很少發生）
                last_err = f'406 captcha'
                time.sleep(0.5)
                continue
            last_err = f'HTTP {r.status_code}'
        except Exception as e:
            last_err = str(e)
            time.sleep(1)
    print(f'  ! {keyword} failed after {retries} retries: {last_err}')
    return None


def fullscan(delay: float = 0.3, limit_surnames: Optional[int] = None) -> dict:
    """執行全量掃描。回傳 {lic_no: lawyer_dict}。"""
    results = {}  # key = now_lic_no, value = lawyer dict

    surnames = COMMON_SURNAMES[:limit_surnames] if limit_surnames else COMMON_SURNAMES
    truncated_surnames = []

    # Pass 1: 單字姓氏
    print(f'=== Pass 1: 單字姓氏 ({len(surnames)} 個) ===')
    for i, s in enumerate(surnames, 1):
        d = search_lawyers(s)
        if d is None:
            continue
        lawyers = d.get('lawyers', [])
        total = d.get('total', 0)
        if total == 0 and len(lawyers) == 0:
            # 可能是 >100 截斷，或真的無人
            truncated_surnames.append(s)
            print(f'  [{i}/{len(surnames)}] {s}: 0 (可能 >100，加入細分)')
        else:
            for ly in lawyers:
                results[ly['now_lic_no']] = ly
            print(f'  [{i}/{len(surnames)}] {s}: {total} -> 累計 {len(results)}')
        time.sleep(delay)

    # 中途上傳（每累積 1000 筆新資料就上傳一次）
    def maybe_upload(force=False):
        nonlocal results, _uploaded_keys
        new_records = [v for k, v in results.items() if k not in _uploaded_keys]
        if len(new_records) >= 1000 or (force and new_records):
            try:
                upload_to_supabase(new_records)
                _uploaded_keys.update(r['now_lic_no'] for r in new_records)
                print(f'  [batch upload] +{len(new_records)} (total uploaded: {len(_uploaded_keys)})')
            except Exception as e:
                print(f'  ! batch upload error: {e}')

    _uploaded_keys = set()
    maybe_upload()  # no-op, just init

    # Pass 2: 雙字（姓 + 名字第一字）細分被截斷的姓氏
    print(f'\n=== Pass 2: 雙字細分 ({len(truncated_surnames)} 個姓氏 × {len(COMMON_NAME_CHARS)} 字) ===')
    for si, s in enumerate(truncated_surnames, 1):
        pass_total = 0
        for c in COMMON_NAME_CHARS:
            kw = s + c
            d = search_lawyers(kw)
            if d is None:
                continue
            lawyers = d.get('lawyers', [])
            if lawyers:
                for ly in lawyers:
                    results[ly['now_lic_no']] = ly
                pass_total += len(lawyers)
            time.sleep(delay)
        print(f'  [{si}/{len(truncated_surnames)}] {s}*: +{pass_total} -> 累計 {len(results)}')
        maybe_upload()

    # 最後上傳剩餘
    maybe_upload(force=True)

    return results


# ============================================================
# 正規化與 Supabase 寫入
# ============================================================

# 公會名稱 → 地區
GUILD_TO_REGION = {
    '台北律師公會': '台北', '基隆律師公會': '基隆', '宜蘭律師公會': '宜蘭',
    '新竹律師公會': '新竹', '桃園律師公會': '桃園', '苗栗律師公會': '苗栗',
    '台中律師公會': '台中', '彰化律師公會': '彰化', '南投律師公會': '南投',
    '嘉義律師公會': '嘉義', '雲林律師公會': '雲林', '台南律師公會': '台南',
    '高雄律師公會': '高雄', '屏東律師公會': '屏東', '台東律師公會': '台東',
    '花蓮律師公會': '花蓮',
}

# 佔位值 → None
OFFICE_PLACEHOLDERS = {'律師未提供', '未提供', '無', '未登記', '-', ''}


def normalize_office(office: Optional[str]) -> Optional[str]:
    """正規化事務所名稱：去空白、去佔位、統一全半形。"""
    if not office:
        return None
    s = office.strip()
    # 全形空白 → 半形空白 → 移除
    s = s.replace('\u3000', ' ').strip()
    s = re.sub(r'\s+', '', s)
    if s in OFFICE_PLACEHOLDERS:
        return None
    return s


def infer_main_region(guild_names: list) -> Optional[str]:
    """從公會清單推斷主要執業地區（取第一個非全聯會）。"""
    if not guild_names:
        return None
    for g in guild_names:
        if g and g != '全國律師聯合會':
            return GUILD_TO_REGION.get(g.strip(), None)
    return None


def to_db_record(ly: dict) -> dict:
    """將 MOJ API 回傳的律師資料轉為 moj_lawyers 表格式。"""
    lic_no = (ly.get('now_lic_no') or '').strip()
    name = (ly.get('name') or '').strip()
    office = (ly.get('office') or '').strip() or None
    office_norm = normalize_office(office)
    guilds = [g.strip() for g in (ly.get('guild_name') or []) if g and g.strip()]
    court = [c.strip() for c in (ly.get('court') or []) if c and c.strip()]
    return {
        'lic_no': lic_no,
        'name': name,
        'sex': ly.get('sex'),
        'office': office,
        'office_normalized': office_norm,
        'guild_names': guilds or None,
        'main_region': infer_main_region(guilds),
        'court': court or None,
        'raw_data': ly,
    }


def upload_to_supabase(lawyers: list):
    """批次寫入 moj_lawyers 表（直接打 PostgREST，避免 SDK 依賴問題）。"""
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
    url = os.environ.get('SUPABASE_URL', '').strip()
    key = os.environ.get('SUPABASE_SERVICE_KEY', '').strip()
    if not url or not key:
        raise RuntimeError(f'Missing env vars: URL={bool(url)}, KEY={bool(key)} (len={len(key)})')
    endpoint = f'{url}/rest/v1/moj_lawyers'
    headers = {
        'apikey': key,
        'Authorization': f'Bearer {key}',
        'Content-Type': 'application/json',
        'Prefer': 'resolution=merge-duplicates,return=minimal',
    }
    records = [to_db_record(ly) for ly in lawyers if ly.get('now_lic_no')]
    print(f'[{time.strftime("%H:%M:%S")}] 準備上傳 {len(records)} 筆到 moj_lawyers')

    batch_size = 500
    uploaded = 0
    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]
        # PostgREST upsert via POST with Prefer: resolution=merge-duplicates
        r = requests.post(endpoint + '?on_conflict=lic_no', json=batch, headers=headers, verify=False, timeout=60)
        if r.status_code not in (200, 201, 204):
            print(f'  ! upload error {r.status_code}: {r.text[:300]}')
            raise RuntimeError(f'upload failed: {r.status_code}')
        uploaded += len(batch)
        print(f'[{time.strftime("%H:%M:%S")}]   已上傳 {uploaded}/{len(records)}')
    print(f'[{time.strftime("%H:%M:%S")}] done - uploaded {uploaded}')
    return uploaded


if __name__ == '__main__':
    import sys
    mode = sys.argv[1] if len(sys.argv) > 1 else 'demo'

    if mode == 'demo':
        print('DEMO MODE: 只跑前 5 個姓氏')
        results = fullscan(delay=0.2, limit_surnames=5)
    elif mode in ('full', 'scan'):
        print(f'{mode.upper()} MODE: 完整掃描')
        results = fullscan(delay=0.3)
    else:
        print(f'Unknown mode: {mode}. 用 demo/scan/full')
        sys.exit(1)

    # 寫 JSON 備份
    out = os.path.join(os.path.dirname(__file__), '..', 'moj_lawyers_output.json')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(list(results.values()), f, ensure_ascii=False, indent=2)
    print(f'\n=== 掃描完成 ===')
    print(f'共 {len(results)} 位律師')
    print(f'JSON 備份: {out}')

    # 統計
    offices = {}
    for ly in results.values():
        o = normalize_office(ly.get('office'))
        if o:
            offices[o] = offices.get(o, 0) + 1
    print(f'\n正規化後不同事務所: {len(offices)}')
    print(f'Top 10 事務所:')
    for o, c in sorted(offices.items(), key=lambda x: -x[1])[:10]:
        print(f'  {c:4d}  {o}')

    # 寫入 Supabase（demo 和 full 都上傳）
    if mode in ('demo', 'full'):
        print('\n=== 寫入 Supabase ===')
        upload_to_supabase(list(results.values()))
