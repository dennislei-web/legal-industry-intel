"""上市櫃公司內部人（董監事/經理人）同步：TWSE/TPEx OpenAPI → listed_company_insiders

資料源（免 key、單一 call 全量）：
  上市：https://openapi.twse.com.tw/v1/opendata/t187ap11_L
  上櫃：https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap11_O
月頻快照（資料年月為民國 yyymm），每次執行全量覆蓋、只留最新一份。

用法:
  python listed_directors.py         # 抓兩市場 + 覆蓋上傳
  python listed_directors.py verify  # 抓 t187ap30 獨董簡歷 + 律師身分覆核 → lawyer_indep_directorships
  python listed_directors.py report  # 只印獨董×律師比對摘要（需先同步）

覆核資料源＝席次母體：TWSE t187ap30_L / TPEx mopsfin_t187ap30_O「獨立董監事兼任情形
彙總表」，含每位獨董的主要現職/主要經歷（揭露義務，全數有填），且比 t187ap11 持股
快照新（股東會改選後 ap11 要隔月才反映）。興櫃無 ap30，席次取 ap11_R。覆核邏輯：
  office_matched   簡歷提到該同名律師名冊登記的事務所 → 釘到特定 lic_no
  lawyer_confirmed 簡歷含「律師」字樣
  legal_related    簡歷僅含 法律/法學/法務
  no_signal        簡歷無法律相關字樣（很可能同名非律師）
  cross_confirmed  興櫃席次，同名者已有上市/上櫃覆核確認席次 → 繼承 lic_no
  name_match_only  興櫃席次，僅姓名比對（無簡歷可核）→ 不上前端頁面
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
    ('emerging', 'https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap11_R'),
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
                # 興櫃 _R 資料集用英文欄位鍵（SecuritiesCompanyCode/CompanyName）
                'company_code': (d.get('公司代號') or d.get('SecuritiesCompanyCode') or '').strip(),
                'company_name': (d.get('公司名稱') or d.get('CompanyName') or '').strip(),
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
        page = rest('GET', f'lawyer_indep_directorships?select=*&limit=1000&offset={off}',
                    headers={'Prefer': ''})
        matches.extend(page)
        if len(page) < 1000:
            break
        off += 1000
    confirmed = [m for m in matches if m['verify_status'] in ('office_matched', 'lawyer_confirmed')]
    people = {}
    for m in confirmed:
        p = people.setdefault(m['person_name'], {'seats': [], 'office': None})
        p['seats'].append(f"{m['company_code']} {m['company_name']}({'上市' if m['market'] == 'listed' else '上櫃'})")
        p['office'] = p['office'] or m['matched_office']
    log(f'名冊同名 {len(matches)} 席；覆核確認律師 {len(confirmed)} 席 / {len(people)} 人')
    for name, v in sorted(people.items(), key=lambda x: -len(x[1]['seats'])):
        print(f"{name}（{len(v['seats'])} 席）{'；'.join(v['seats'])}｜{v['office'] or ''}")


AP30_SOURCES = [
    ('listed', 'https://openapi.twse.com.tw/v1/opendata/t187ap30_L', '公司代號', '公司名稱', '姓名'),
    ('otc', 'https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap30_O', 'SecuritiesCompanyCode', 'CompanyName', 'Name'),
]

OFFICE_SUFFIXES = ['聯合法律事務所', '國際法律事務所', '法律事務所', '聯合律師事務所', '律師事務所', '聯合事務所', '事務所']


def office_core(office):
    """事務所核心名：去空白後剝除常見後綴，供簡歷子字串比對"""
    s = (office or '').replace(' ', '').replace('　', '')
    for suf in OFFICE_SUFFIXES:
        if s.endswith(suf) and len(s) > len(suf):
            return s[:-len(suf)]
    return s


def fetch_profiles():
    """抓 t187ap30 兩市場，留職稱含「獨立」列，依 (公司代號, 姓名) 去重"""
    profiles = {}
    for market, url, code_k, cname_k, name_k in AP30_SOURCES:
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.load(resp)
        n = 0
        for d in data:
            title = (d.get('職稱') or '').strip()
            name = (d.get(name_k) or '').strip()
            code = (d.get(code_k) or '').strip()
            if '獨立' not in title or not name or not code:
                continue
            key = (code, name)
            if key in profiles:
                continue
            profiles[key] = {
                'company_code': code,
                'company_name': (d.get(cname_k) or '').strip(),
                'person_name': name,
                'person_name_norm': norm_name(name),
                'market': market,
                'title': title,
                'appointed_date': (d.get('就任日期') or '').strip(),
                'current_position': (d.get('主要現職') or '').strip(),
                'experience': (d.get('主要經歷') or '').strip(),
            }
            n += 1
        log(f'{market} t187ap30: 獨立董監事 {n} 筆（去重後累計 {len(profiles)}）')
    return profiles


def cmd_verify():
    profiles = fetch_profiles()
    rows = list(profiles.values())
    if len(rows) < 5000:
        log(f'防呆觸發：t187ap30 只有 {len(rows)} 筆獨董簡歷，不覆蓋')
        sys.exit(2)
    log('覆蓋 indep_director_profiles…')
    rest('DELETE', 'indep_director_profiles?company_code=neq.')
    for i in range(0, len(rows), 1000):
        rest('POST', 'indep_director_profiles', body=rows[i:i + 1000])

    # 席次母體直接用 ap30（比 ap11 持股快照新：6 月股東會改選後 ap11 尚未反映）
    seats = rows

    # 興櫃：無 ap30 簡歷資料集，席次取自 ap11_R 持股明細（獨立董事本人）
    req = urllib.request.Request('https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap11_R',
                                 headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=90) as resp:
        rdata = json.load(resp)
    emerging = {}
    for d in rdata:
        title = (d.get('職稱') or '').strip()
        name = (d.get('姓名') or '').strip()
        code = (d.get('SecuritiesCompanyCode') or '').strip()
        if '獨立董事' not in title or not name or not code or (code, name) in emerging:
            continue
        emerging[(code, name)] = {
            'company_code': code,
            'company_name': (d.get('CompanyName') or '').strip(),
            'person_name': name,
            'person_name_norm': norm_name(name),
            'market': 'emerging',
            'title': '獨立董事',
            'appointed_date': None,
            'current_position': None,
            'experience': None,
        }
    log(f'emerging t187ap11_R: 獨立董事 {len(emerging)} 席')

    # 名冊候選：只抓有出現在席次中的姓名
    names = sorted({s['person_name_norm'] for s in seats} |
                   {s['person_name_norm'] for s in emerging.values()})
    roster = {}  # name_norm -> [ {lic_no, office_normalized}, ... ]
    for i in range(0, len(names), 80):
        batch = ','.join(f'"{n}"' for n in names[i:i + 80])
        page = rest('GET', f'moj_lawyers?select=lic_no,name,office_normalized&name=in.({urllib.parse.quote(batch)})',
                    headers={'Prefer': ''})
        for r in page:
            roster.setdefault(norm_name(r['name']), []).append(r)

    # 逐席覆核
    out = []
    for s in seats:
        cands = roster.get(s['person_name_norm'])
        if not cands:
            continue  # 非名冊命中席次
        bio = norm_name(s['current_position'] + s['experience'])
        lic_no, status, matched_office = None, None, None
        for c in cands:
            core = office_core(c.get('office_normalized') or '')
            full = norm_name(c.get('office_normalized') or '')
            if len(core) >= 2 and ((core != s['person_name_norm'] and core in bio) or (full and full in bio)):
                lic_no, status, matched_office = c['lic_no'], 'office_matched', c['office_normalized']
                break
        if status is None:
            if '律師' in bio:
                status = 'lawyer_confirmed'
            elif any(k in bio for k in ('法律', '法學', '法務')):
                status = 'legal_related'
            else:
                status = 'no_signal'
            if len(cands) == 1:
                lic_no = cands[0]['lic_no']
        out.append({
            'lic_no': lic_no,
            'person_name': s['person_name'],
            'company_code': s['company_code'],
            'company_name': s['company_name'],
            'market': s['market'],
            'title': s['title'],
            'appointed_date': s['appointed_date'],
            'same_name_lawyers': len(cands),
            'verify_status': status,
            'matched_office': matched_office,
            'current_position': s['current_position'],
            'experience': s['experience'],
        })

    # 興櫃席次：交叉確認（同名者已有上市/上櫃簡歷覆核確認 → 繼承身分），否則僅名單
    confirmed_lic = {norm_name(r['person_name']): r['lic_no'] for r in out
                     if r['verify_status'] in ('office_matched', 'lawyer_confirmed') and r['lic_no']}
    for s in emerging.values():
        cands = roster.get(s['person_name_norm'])
        if not cands:
            continue
        lic_no = confirmed_lic.get(s['person_name_norm'])
        if lic_no:
            status = 'cross_confirmed'
        else:
            status = 'name_match_only'
            if len(cands) == 1:
                lic_no = cands[0]['lic_no']
        out.append({
            'lic_no': lic_no,
            'person_name': s['person_name'],
            'company_code': s['company_code'],
            'company_name': s['company_name'],
            'market': 'emerging',
            'title': s['title'],
            'appointed_date': None,
            'same_name_lawyers': len(cands),
            'verify_status': status,
            'matched_office': None,
            'current_position': None,
            'experience': None,
        })

    log(f'覆核完成 {len(out)} 席，覆蓋 lawyer_indep_directorships…')
    rest('DELETE', 'lawyer_indep_directorships?company_code=neq.')
    for i in range(0, len(out), 500):
        rest('POST', 'lawyer_indep_directorships', body=out[i:i + 500])
    import collections
    dist = collections.Counter(r['verify_status'] for r in out)
    log('verify_status 分布: ' + json.dumps(dist, ensure_ascii=False))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'report':
        cmd_report()
    elif len(sys.argv) > 1 and sys.argv[1] == 'verify':
        cmd_verify()
    else:
        cmd_sync()
