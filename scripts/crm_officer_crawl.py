# -*- coding: utf-8 -*-
"""喆律 CRM 法官/檢察官內部紀錄爬蟲。

登入 crm.lawyer（Rails Devise）→ 機關搜尋列舉全部法官/檢察官
→ 逐人抓姓名詳情頁（案件清單＋內部評論）→ upsert 進 crm_officer_reviews。

env: CRM_EMAIL, CRM_PASSWORD, SUPABASE_URL, SUPABASE_SERVICE_KEY
用法:
  python crm_officer_crawl.py                 # 全量
  python crm_officer_crawl.py --limit 5       # 只爬前 5 人（測試/估時）
  python crm_officer_crawl.py --dry-run       # 不寫 DB
  python crm_officer_crawl.py --sample        # 額外 dump 原始 HTML 到 _crm_samples/（校準解析器用）
"""
import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import requests
from bs4 import BeautifulSoup

requests.packages.urllib3.disable_warnings()

BASE = os.environ.get('CRM_BASE', 'https://crm.lawyer').rstrip('/')
SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_KEY', '').strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

SAMPLE_DIR = Path(__file__).parent / '_crm_samples'
SLEEP = 0.4  # 禮貌間隔（秒/請求）

# 機關列舉：CRM 機關搜尋若支援子字串比對，用寬鍵一次撈；否則退回逐一完整機關名
BROAD_KEYS = ['地方法院', '地方檢察署', '高等法院', '高等檢察署', '最高法院', '最高檢察署',
              '少年及家事法院', '智慧財產', '行政法院', '商業法院']
DISTRICTS = ['臺北', '新北', '士林', '桃園', '新竹', '苗栗', '臺中', '彰化', '南投', '雲林',
             '嘉義', '臺南', '橋頭', '高雄', '屏東', '臺東', '花蓮', '宜蘭', '基隆', '澎湖',
             '金門', '連江']
FULL_AGENCIES = (
    [f'臺灣{d}地方法院' for d in DISTRICTS]
    + [f'臺灣{d}地方檢察署' for d in DISTRICTS]
    + ['臺灣高等法院', '臺灣高等檢察署', '最高法院', '最高檢察署',
       '臺灣高雄少年及家事法院', '智慧財產及商業法院',
       '臺北高等行政法院', '臺中高等行政法院', '高雄高等行政法院', '最高行政法院']
    + [f'臺灣高等法院{b}分院' for b in ['臺中', '臺南', '高雄', '花蓮']]
    + [f'臺灣高等檢察署{b}檢察分署' for b in ['臺中', '臺南', '高雄', '花蓮']]
)


def log(msg):
    print(msg, flush=True)


def set_status(status, detail=None, start=False, finish=False):
    if not SUPABASE_URL or not SERVICE_KEY:
        return
    payload = {'status': status, 'detail': (detail or '')[:500]}
    if start:
        payload['started_at'] = time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime())
        payload['finished_at'] = None
    if finish:
        payload['finished_at'] = time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime())
    try:
        requests.patch(f'{SUPABASE_URL}/rest/v1/crm_crawl_status?id=eq.1', json=payload,
                       headers={**HEADERS_SB, 'Prefer': 'return=minimal'}, verify=False, timeout=30)
    except Exception as e:
        log(f'  [warn] set_status 失敗: {type(e).__name__}')


def login(session):
    """Devise 表單登入；成功後 session 帶認證 cookie。"""
    email = os.environ.get('CRM_EMAIL', '').strip()
    password = os.environ.get('CRM_PASSWORD', '')
    if not email or not password:
        sys.exit('CRM_EMAIL / CRM_PASSWORD 未設定')
    r = session.get(f'{BASE}/users/sign_in', timeout=30)
    r.raise_for_status()
    soup = BeautifulSoup(r.text, 'lxml')
    token_el = soup.select_one('form#new_user input[name="authenticity_token"]') \
        or soup.select_one('meta[name="csrf-token"]')
    token = token_el.get('value') or token_el.get('content') if token_el else None
    if not token:
        sys.exit('登入頁找不到 authenticity_token（頁面結構變了？）')
    r = session.post(f'{BASE}/users/sign_in', data={
        'authenticity_token': token,
        'user[email]': email,
        'user[password]': password,
        'user[remember_me]': '0',
    }, timeout=30, allow_redirects=True)
    # 失敗時 Devise 會 200 重繪登入表單；成功會導向 dashboard
    if 'new_user' in r.text and '/users/sign_in' in r.url:
        sys.exit('CRM 登入失敗（帳密錯誤或帳號被鎖）')
    log(f'登入成功 → {r.url}')


def fetch(session, path, sample_name=None, sample=False):
    r = session.get(f'{BASE}{path}', timeout=60)
    r.raise_for_status()
    if '/users/sign_in' in r.url:
        raise RuntimeError('session 失效，被導回登入頁')
    if sample and sample_name:
        SAMPLE_DIR.mkdir(exist_ok=True)
        (SAMPLE_DIR / sample_name).write_text(r.text, encoding='utf-8')
    time.sleep(SLEEP)
    return r.text


def _header_index(table):
    """回傳 {欄名: index}。"""
    ths = table.select('thead th') or (table.find('tr').find_all(['th', 'td']) if table.find('tr') else [])
    return {th.get_text(strip=True).rstrip('▲▼ '): i for i, th in enumerate(ths)}


def parse_officer_list(html):
    """機關搜尋結果頁 → [{name, agency, sub_agency, division, officer_type, note}]"""
    soup = BeautifulSoup(html, 'lxml')
    out = []
    for table in soup.find_all('table'):
        idx = _header_index(table)
        if not any(k.startswith('姓名') for k in idx):
            continue
        col = {}
        for key, i in idx.items():
            if key.startswith('姓名'):
                col['name'] = i
            elif key.startswith('機關'):
                col['agency'] = i
            elif key.startswith('附屬'):
                col['sub_agency'] = i
            elif key.startswith('股別'):
                col['division'] = i
            elif key.startswith('職稱'):
                col['type'] = i
            elif key.startswith('共通'):
                col['note'] = i
        for tr in table.select('tbody tr') or table.find_all('tr')[1:]:
            tds = tr.find_all('td')
            if len(tds) <= col.get('name', 0):
                continue
            get = lambda k: tds[col[k]].get_text(strip=True) if k in col and col[k] < len(tds) else ''
            name = get('name')
            if not name:
                continue
            out.append({
                'name': name,
                'agency': get('agency'),
                'sub_agency': get('sub_agency').replace('無', '') or None,
                'division': get('division') or None,
                'officer_type': get('type') or None,
                'note': get('note') or None,
            })
    return out


def parse_officer_detail(html):
    """姓名詳情頁 → {cases: [...], comments: [...]}
    案件表：案件編號 / 承辦分所 / 案由；評論區塊：機關 / 股別 / 類型 / 評論 / 建立日期。"""
    soup = BeautifulSoup(html, 'lxml')
    cases, comments = [], []

    for table in soup.find_all('table'):
        idx = _header_index(table)
        if not any(k.startswith('案件編號') for k in idx):
            continue
        col = {}
        for key, i in idx.items():
            if key.startswith('案件編號'):
                col['case_no'] = i
            elif key.startswith('承辦'):
                col['branch'] = i
            elif key.startswith('案由'):
                col['cause'] = i
        for tr in table.select('tbody tr') or table.find_all('tr')[1:]:
            tds = tr.find_all('td')
            if not tds:
                continue
            get = lambda k: tds[col[k]].get_text(strip=True) if k in col and col[k] < len(tds) else ''
            case_no = get('case_no')
            if case_no:
                cases.append({'case_no': case_no, 'branch': get('branch') or None,
                              'cause': get('cause') or None})

    # 評論區：找「評論」標題後的區塊；每則含 機關:xxx 股別:xxx 類型:xxx 評論: ... N 建立
    text_blocks = []
    for el in soup.find_all(string=re.compile(r'評論\s*[:：]')):
        block = el.find_parent(['div', 'section', 'li', 'td'])
        for _ in range(3):  # 往上找含「機關」的完整卡片
            if block is None:
                break
            if re.search(r'機關\s*[:：]', block.get_text()):
                break
            block = block.parent
        if block is not None and block.get_text() not in text_blocks:
            text_blocks.append(block.get_text('\n', strip=True))

    def pick(txt, label):
        m = re.search(label + r'\s*[:：]\s*([^\n]*)', txt)
        return (m.group(1).strip() or None) if m else None

    for txt in dict.fromkeys(text_blocks):  # 去重保序
        m = re.search(r'評論\s*[:：]\s*(.*?)(?:\n(\d{2,3}-\d{2}-\d{2})\s*建立|\Z)', txt, re.S)
        comment_body = m.group(1).strip() if m else None
        created = m.group(2) if m and m.lastindex and m.lastindex >= 2 and m.group(2) else None
        comments.append({
            'agency': pick(txt, r'機關'),
            'division': pick(txt, r'股別'),
            'officer_type': pick(txt, r'類型'),
            'comment': comment_body,
            'created_at': created,
        })
    return {'cases': cases, 'comments': comments}


def enumerate_officers(session, sample=False):
    """機關搜尋列舉全部人員；先試寬鍵（子字串比對），無效再退回完整機關名。"""
    from urllib.parse import quote
    seen = {}
    keys = BROAD_KEYS
    got_broad = False
    for i, key in enumerate(keys):
        html = fetch(session, f'/dashboard/search_officer_by_agency?agency_category={quote(key)}',
                     sample_name=f'list_{i}_{key}.html', sample=sample)
        rows = parse_officer_list(html)
        if rows:
            got_broad = True
        for r in rows:
            k = (r['name'], r['officer_type'] or '')
            if k not in seen:
                seen[k] = r
            else:  # 同人多機關列 → 併進 agencies 由呼叫端整理
                seen[k].setdefault('extra_agencies', []).append(
                    {'agency': r['agency'], 'sub_agency': r['sub_agency'],
                     'division': r['division'], 'note': r['note']})
        log(f'  機關搜尋「{key}」→ {len(rows)} 列（累計 {len(seen)} 人）')
    if not got_broad:
        log('寬鍵全空 → 退回逐一完整機關名（exact match 模式）')
        for i, key in enumerate(FULL_AGENCIES):
            html = fetch(session, f'/dashboard/search_officer_by_agency?agency_category={quote(key)}',
                         sample_name=f'list_full_{i}.html', sample=sample and i < 3)
            rows = parse_officer_list(html)
            for r in rows:
                k = (r['name'], r['officer_type'] or '')
                if k not in seen:
                    seen[k] = r
                else:
                    seen[k].setdefault('extra_agencies', []).append(
                        {'agency': r['agency'], 'sub_agency': r['sub_agency'],
                         'division': r['division'], 'note': r['note']})
            if rows:
                log(f'  「{key}」→ {len(rows)} 列（累計 {len(seen)} 人）')
    return list(seen.values())


def upsert_rows(rows):
    r = requests.post(
        f'{SUPABASE_URL}/rest/v1/crm_officer_reviews?on_conflict=name,officer_type',
        json=rows,
        headers={**HEADERS_SB, 'Content-Type': 'application/json',
                 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        verify=False, timeout=60)
    if r.status_code not in (200, 201, 204):
        raise RuntimeError(f'upsert 失敗 {r.status_code}: {r.text[:300]}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--sample', action='store_true')
    args = ap.parse_args()

    t0 = time.time()
    session = requests.Session()
    session.headers['User-Agent'] = 'Mozilla/5.0 (zhelu-internal-sync)'
    try:
        set_status('running', '登入中', start=True)
        login(session)

        set_status('running', '列舉機關人員中')
        officers = enumerate_officers(session, sample=args.sample)
        log(f'共列舉 {len(officers)} 位人員')
        if not officers:
            raise RuntimeError('機關搜尋 0 列 — 可能是 SPA/解析失敗，開 --sample 檢查 HTML')
        if args.limit:
            officers = officers[:args.limit]

        from urllib.parse import quote, urlencode
        batch, done = [], 0
        for i, off in enumerate(officers):
            otype = off['officer_type'] or 'Judge'
            qs = urlencode({'name': off['name'], 'type': otype})
            try:
                html = fetch(session, f'/dashboard/officers?{qs}',
                             sample_name=f'detail_{i}.html',
                             sample=args.sample and i < 5)
                detail = parse_officer_detail(html)
            except Exception as e:
                # repo 公開、Actions log 公開可見 → 只印序號不印人名
                log(f'  [warn] 第 {i} 位詳情失敗: {type(e).__name__}')
                continue
            agencies = [{'agency': off['agency'], 'sub_agency': off['sub_agency'],
                         'division': off['division'], 'note': off['note']}] \
                + off.get('extra_agencies', [])
            distinct_cases = len({c['case_no'] for c in detail['cases']})
            batch.append({
                'name': off['name'],
                'officer_type': otype,
                'agencies': agencies,
                'case_count': distinct_cases,
                'cases': detail['cases'],
                'comments': [c for c in detail['comments'] if c.get('comment')],
                'crawled_at': time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime()),
            })
            done += 1
            if len(batch) >= 50:
                if not args.dry_run:
                    upsert_rows(batch)
                batch = []
                set_status('running', f'{done}/{len(officers)} 位完成')
                log(f'  進度 {done}/{len(officers)}（{time.time()-t0:.0f}s）')
        if batch and not args.dry_run:
            upsert_rows(batch)

        summary = f'{done} 位完成，耗時 {time.time()-t0:.0f}s'
        log(summary)
        set_status('done', summary, finish=True)
    except SystemExit as e:
        set_status('error', str(e), finish=True)
        raise
    except Exception as e:
        set_status('error', f'{type(e).__name__}: {e}', finish=True)
        raise


if __name__ == '__main__':
    main()
