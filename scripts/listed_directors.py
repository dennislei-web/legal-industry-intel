"""上市櫃公司內部人（董監事/經理人）同步：TWSE/TPEx OpenAPI → listed_company_insiders

資料源（免 key、單一 call 全量）：
  上市：https://openapi.twse.com.tw/v1/opendata/t187ap11_L
  上櫃：https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap11_O
月頻快照（資料年月為民國 yyymm），每次執行全量覆蓋、只留最新一份。

用法:
  python listed_directors.py         # 抓兩市場 + 覆蓋上傳
  python listed_directors.py report  # 只印獨董×律師比對摘要（需先同步）
"""
import json
import os
import sys
import urllib.parse
import urllib.request

from dotenv import load_dotenv

from utils import log

# 不用 supabase-py：本機 2.11.0 不認新版 sb_secret_ key，直接走 PostgREST
load_dotenv()
SB_URL = os.environ['SUPABASE_URL']
SB_KEY = os.environ['SUPABASE_SERVICE_KEY']


def rest(method, path, body=None, headers=None):
    h = {'apikey': SB_KEY, 'Authorization': f'Bearer {SB_KEY}',
         'Content-Type': 'application/json', 'Prefer': 'return=minimal'}
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f'{SB_URL}/rest/v1/{path}', data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None

SOURCES = [
    ('listed', 'https://openapi.twse.com.tw/v1/opendata/t187ap11_L'),
    ('otc', 'https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap11_O'),
]
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'
# 筆數防呆：兩市場合計向來 4 萬多筆，低於此值視為來源異常，不覆蓋既有資料
MIN_TOTAL_ROWS = 30000


def norm_name(s):
    return (s or '').replace(' ', '').replace('　', '').strip()


def to_int(s):
    try:
        return int(str(s).replace(',', '').strip())
    except (ValueError, TypeError):
        return None


def fetch_all():
    rows = []
    for market, url in SOURCES:
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.load(resp)
        log(f'{market}: {len(data)} 筆')
        for d in data:
            name = (d.get('姓名') or '').strip()
            if not name:
                continue
            rows.append({
                'market': market,
                'company_code': (d.get('公司代號') or '').strip(),
                'company_name': (d.get('公司名稱') or '').strip(),
                'title': (d.get('職稱') or '').strip(),
                'person_name': name,
                'person_name_norm': norm_name(name),
                'data_month': (d.get('資料年月') or '').strip(),
                'current_shares': to_int(d.get('目前持股')),
            })
    return rows


def cmd_sync():
    rows = fetch_all()
    if len(rows) < MIN_TOTAL_ROWS:
        log(f'防呆觸發：只抓到 {len(rows)} 筆（門檻 {MIN_TOTAL_ROWS}），不覆蓋既有資料')
        sys.exit(2)
    log('清空舊快照…')
    rest('DELETE', 'listed_company_insiders?market=neq.')
    log(f'寫入 {len(rows)} 筆…')
    for i in range(0, len(rows), 1000):
        rest('POST', 'listed_company_insiders', body=rows[i:i + 1000])
    log('同步完成')


def cmd_report():
    matches = []
    off = 0
    while True:
        page = rest('GET', f'indep_director_lawyer_matches?select=*&limit=1000&offset={off}',
                    headers={'Prefer': ''})
        matches.extend(page)
        if len(page) < 1000:
            break
        off += 1000
    people = {}
    for m in matches:
        p = people.setdefault(m['person_name'], {'seats': [], 'same_name_lawyers': m['same_name_lawyers'],
                                                 'offices': m['lawyer_offices']})
        p['seats'].append(f"{m['company_code']} {m['company_name']}({'上市' if m['market'] == 'listed' else '上櫃'})")
    sure = {k: v for k, v in people.items() if v['same_name_lawyers'] == 1}
    fuzzy = {k: v for k, v in people.items() if v['same_name_lawyers'] > 1}
    log(f'獨董席次命中 {len(matches)} 席 / 去重 {len(people)} 人；高信心 {len(sure)} 人、同名需覆核 {len(fuzzy)} 人')
    for group, title in [(sure, '── 高信心（名冊唯一同名）──'), (fuzzy, '── 同名 ≥2，需覆核 ──')]:
        print(title)
        for name, v in sorted(group.items(), key=lambda x: -len(x[1]['seats'])):
            offices = '、'.join((v['offices'] or [])[:3])
            print(f"{name}（{len(v['seats'])} 席）{'；'.join(v['seats'])}｜{offices}")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'report':
        cmd_report()
    else:
        cmd_sync()
