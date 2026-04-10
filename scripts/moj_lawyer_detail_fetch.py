"""
MOJ 律師詳細資料補掃
對 moj_lawyers 表每位律師，用 lic_no 去打 /api/cert/lyinfosd/{lic_no}
抓出 birth_year, email, phone, address, discipline, state 等詳細欄位。

此 API 不需要 CAPTCHA，可以大量呼叫。
"""
import os
import re
import sys
import time
import requests
import urllib3
from urllib.parse import quote
from dotenv import load_dotenv

# 強制 stdout unbuffered 讓背景 task 能即時看到 log
sys.stdout.reconfigure(line_buffering=True)

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
MOJ_BASE = 'https://lawyerbc.moj.gov.tw/api'

HEADERS_MOJ = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) LegalIndustryIntel/1.0',
    'Referer': 'https://lawyerbc.moj.gov.tw/',
    'Origin': 'https://lawyerbc.moj.gov.tw',
}
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

sess_moj = requests.Session()
sess_moj.verify = False
sess_moj.headers.update(HEADERS_MOJ)


def parse_roc_date(s):
    """民國日期 '081/03/05' → '1992-03-05' (西元)"""
    if not s or not isinstance(s, str):
        return None
    m = re.match(r'(\d{2,3})/(\d{1,2})/(\d{1,2})', s.strip())
    if not m:
        return None
    roc_y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    return f'{1911 + roc_y:04d}-{mo:02d}-{d:02d}'


def parse_ad_date(s):
    """西元 '2020/11/30' → '2020-11-30'"""
    if not s:
        return None
    m = re.match(r'(\d{4})/(\d{1,2})/(\d{1,2})', s.strip())
    if not m:
        return None
    return f'{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}'


def fetch_detail(lic_no, retries=2):
    """呼叫 MOJ API 取得律師詳細資料，超時 8 秒，失敗重試一次"""
    enc = quote(lic_no)
    for attempt in range(retries):
        try:
            r = sess_moj.get(f'{MOJ_BASE}/cert/lyinfosd/{enc}', timeout=(5, 8))
            if r.status_code != 200:
                return None
            data = r.json().get('data')
            if not data or not isinstance(data, list) or len(data) == 0:
                return None
            return data[0]
        except requests.exceptions.Timeout:
            if attempt < retries - 1:
                time.sleep(0.5)
                continue
            return None
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(0.5)
                continue
            return None
    return None


def detail_to_update(d):
    """把 MOJ API 回傳轉成 moj_lawyers 欄位格式（不含 pic bytes）"""
    return {
        'birth_year': d.get('birthsday') if isinstance(d.get('birthsday'), int) else None,
        'state': str(d.get('state')) if d.get('state') is not None else None,
        'state_desc': d.get('statedesc') or None,
        'english_name': d.get('engname') or None,
        'old_name': d.get('oldname') or None,
        'foreigner': d.get('foreigner') or None,
        'qualification_govt': d.get('qualificationgovt') or None,
        'email': d.get('email') or None,
        'tel': d.get('tel') or None,
        'address': d.get('addr') or None,
        'discipline': d.get('discipline') or None,
        'professional_license': d.get('prolic') or None,
        'practice_start_date': parse_roc_date(d.get('startdate')),
        'practice_end_date': parse_roc_date(d.get('enddate')),
        'remark': d.get('remark') or None,
        'moj_mk_date': parse_ad_date(d.get('mkdate')),
        'moj_ut_date': parse_ad_date(d.get('utdate')),
        'detail_fetched_at': 'now()',
    }


def fetch_all_lic_nos(only_missing=True):
    """從 Supabase 分頁撈所有 moj_lawyers 的 lic_no"""
    out = []
    page = 0
    while True:
        filter_clause = '&detail_fetched_at=is.null' if only_missing else ''
        r = requests.get(
            f'{SUPABASE_URL}/rest/v1/moj_lawyers?select=lic_no{filter_clause}'
            f'&offset={page*1000}&limit=1000',
            headers=HEADERS_SB, verify=False, timeout=30,
        )
        rows = r.json()
        if not rows or (isinstance(rows, dict) and rows.get('message')):
            break
        out.extend([r['lic_no'] for r in rows if r.get('lic_no')])
        if len(rows) < 1000:
            break
        page += 1
    return out


def batch_update(updates):
    """逐筆 PATCH 更新 moj_lawyers (加 timeout 避免卡住)"""
    from datetime import datetime, timezone
    now_iso = datetime.now(timezone.utc).isoformat()
    headers = {
        **HEADERS_SB,
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
    }
    errors = 0
    for u in updates:
        lic_no = u.pop('lic_no', None)
        if not lic_no:
            continue
        if u.get('detail_fetched_at') == 'now()':
            u['detail_fetched_at'] = now_iso
        # PATCH /rest/v1/moj_lawyers?lic_no=eq.<encoded>
        endpoint = f'{SUPABASE_URL}/rest/v1/moj_lawyers?lic_no=eq.{quote(lic_no)}'
        try:
            r = requests.patch(endpoint, headers=headers, json=u, verify=False, timeout=(5, 10))
            if r.status_code not in (200, 204):
                errors += 1
                if errors < 3:
                    print(f'  patch err {r.status_code} for {lic_no}: {r.text[:150]}')
        except Exception as e:
            errors += 1
            if errors < 3:
                print(f'  patch exception for {lic_no}: {e}')
    if errors > 0:
        print(f'  total patch errors: {errors}/{len(updates)}')


def main(limit=None, delay=0.15):
    print('=== 取得待補掃 lic_no ===')
    lic_nos = fetch_all_lic_nos(only_missing=True)
    print(f'找到 {len(lic_nos)} 位律師尚未有 detail 資料')
    if limit:
        lic_nos = lic_nos[:limit]
        print(f'限制處理 {limit} 筆')

    if not lic_nos:
        print('無須處理')
        return

    updates = []
    ok = 0
    fail = 0
    t0 = time.time()

    for i, lic in enumerate(lic_nos, 1):
        d = fetch_detail(lic)
        if d:
            rec = detail_to_update(d)
            rec['lic_no'] = lic  # upsert key
            updates.append(rec)
            ok += 1
        else:
            fail += 1

        if i % 100 == 0:
            elapsed = time.time() - t0
            rate = i / elapsed
            eta = (len(lic_nos) - i) / rate / 60
            print(f'  [{i}/{len(lic_nos)}] ok={ok} fail={fail} rate={rate:.1f}/s ETA={eta:.1f}min')

        # 每 500 筆上傳一次
        if len(updates) >= 500:
            print(f'  ↑ batch upload {len(updates)} records')
            batch_update(updates)
            updates.clear()

        time.sleep(delay)

    # 最後批次
    if updates:
        print(f'  ↑ final batch upload {len(updates)} records')
        batch_update(updates)

    print(f'\n=== 完成 ===')
    print(f'成功: {ok} / {len(lic_nos)}')
    print(f'失敗: {fail}')
    print(f'耗時: {(time.time() - t0) / 60:.1f} 分鐘')


if __name__ == '__main__':
    import sys
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else None
    main(limit=limit)
