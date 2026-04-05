"""
MOJ lawyerbc API 探測腳本 (Phase 1)
目標：
1. 找出所有可用 endpoint
2. 分析 SVG 驗證碼結構
3. 驗證個別律師查詢是否真的被 CAPTCHA 擋住
"""
import json
import re
import requests
from urllib.parse import quote

BASE = 'https://lawyerbc.moj.gov.tw/api'
H = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Referer': 'https://lawyerbc.moj.gov.tw/',
    'Origin': 'https://lawyerbc.moj.gov.tw',
}

sess = requests.Session()
sess.headers.update(H)
sess.verify = False
import urllib3
urllib3.disable_warnings()


def hit(path, method='GET', **kw):
    url = f'{BASE}/{path}'
    try:
        r = sess.request(method, url, timeout=15, **kw)
        ct = r.headers.get('content-type', '')
        body = r.text[:400] if 'json' not in ct and 'xml' not in ct else r.text[:600]
        print(f'[{r.status_code}] {method} {path} ({len(r.content)}B) -> {body}')
        return r
    except Exception as e:
        print(f'[ERR] {path}: {e}')
        return None


print('\n=== 1. Known endpoints ===')
hit('cert/sdlyguild/summary')
hit('cert/sdlyguild/info')
hit('cert/lyinfosd/notice/upDate')
hit('cert/captcha')

print('\n=== 2. 猜測個別律師 endpoints ===')
# 從 JS 反編譯看到的三個 path
hit('cert/lyinfosd/test')
hit('cert/lyinfosd/licNo/001')
hit('cert/lyinfosd/receipt/001')

# 實際常見的台灣律師字號格式 (年度3碼+台字+5碼)
# 試幾種格式
for lic in ['0950001', '(95)台字第0001號', '95臺律字0001',
            '1', '01', '001', '0001', '00001', '000001',
            'TPE-001', 'TPE0001', 'A001']:
    hit(f'cert/lyinfosd/licNo/{quote(lic)}')

print('\n=== 3. 猜測 bulk / list endpoints ===')
for p in ['cert/lyinfosd', 'cert/lyinfosd/all',
          'cert/lyinfosd/list/TPBA', 'cert/lyinfosd/guild/TPBA',
          'cert/lyinfosd/byGuild/TPBA', 'cert/lyinfosd/search',
          'cert/lyinfosd/name/陳']:
    hit(p)

print('\n=== 4. POST 測試 ===')
hit('cert/lyinfosd', method='POST', json={'name': '陳'})
hit('cert/lyinfosd/search', method='POST', json={'name': '陳'})
hit('cert/lyinfosd', method='POST', json={'guild': 'TPBA'})

print('\n=== 5. 分析 captcha 結構 ===')
r = sess.get(f'{BASE}/cert/captcha')
if r and r.status_code == 200:
    cap = r.json()
    print('captcha json keys:', list(cap.keys()))
    if isinstance(cap.get('data'), dict):
        d = cap['data']
        print('data keys:', list(d.keys()))
        for k, v in d.items():
            if k == 'data':
                svg = v
                print(f'svg length: {len(svg)}')
                # 找 <text> 節點（若有就是明文）
                text_nodes = re.findall(r'<text[^>]*>([^<]+)</text>', svg)
                print(f'<text> nodes: {text_nodes[:10]}')
                # 找 path count
                paths = re.findall(r'<path', svg)
                print(f'<path> count: {len(paths)}')
                # 存起來
                with open('C:/projects/legal-industry-intel/tmp_cap.svg', 'w', encoding='utf-8') as f:
                    f.write(svg)
                print('saved svg')
            else:
                print(f'  {k} = {str(v)[:200]}')
    # cookies from response?
    print('session cookies:', dict(sess.cookies))

print('\n=== 6. 取得第二個 captcha 比對 ===')
r2 = sess.get(f'{BASE}/cert/captcha')
if r2:
    d2 = r2.json()['data']
    if 'data' in d2:
        with open('C:/projects/legal-industry-intel/tmp_cap2.svg', 'w', encoding='utf-8') as f:
            f.write(d2['data'])
        # 看其他欄位是否變動
        for k, v in d2.items():
            if k != 'data':
                print(f'  {k} = {str(v)[:200]}')
