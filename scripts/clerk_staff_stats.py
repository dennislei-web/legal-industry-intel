"""
書記官（司法人力）統計管線 — 司法統計年報「員工實有人數」ODS → migration INSERT SQL

資料來源：司法統計年報（www.judicial.gov.tw/tw/lp-{LP_ID}-{page}-xCat-{cat}.html）
各機關「員工實有人數」表（ODS），每張表含民國 104 年起的年別序列（年報每年換一個 LP_ID，
114 年報＝lp-2475；年更時改 LP_ID 重跑即可）。

口徑（由英文表頭自動分類欄位，中文表頭跨列合併不可靠；表頭先去連字號/空白再比對，
因為 ODS 有「Assist-ant Clerk」這種印刷斷字）：
- clerks  = 欄名以 clerk/chiefclerk 開頭（= 書記官長＋書記官兼科長/股長＋書記官；
            地院年別表為單一「書記官長及書記官/Chief Clerk and Clerk」欄）；
            排除 assistantclerk（錄事）與 clerkofthe…（會計/統計課員 Clerk of the Accounting
            Office 等，非書記官）
- judges  = 欄名含 judge 一詞（院長/庭長/法官兼庭長/法官/候補/優遇；不含 Judicial Affairs
            司法事務官、Judicial Police 法警）
- total   = 第一個 Total 欄（員工總計，含工友技工駕駛）
- 只取「計」列（男女合計）；年別取列內西元年（2015→民國 104）

輸出兩組資料：
- clerk_staff_stats     審級 × 年（104–114）趨勢
- clerk_court_snapshot  114 年各法院快照（地院／高院及分院 機關別表）

用法:
  python clerk_staff_stats.py scan       # 掃年報列表頁，列出實有人數表與 ODS 連結
  python clerk_staff_stats.py run        # 下載 + 解析 + 產生 SQL（stdout）
"""
import os
import re
import sys
import json
import zipfile
import xml.etree.ElementTree as ET
import requests

if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

LP_ID = os.environ.get('CLERK_STATS_LP', '2475')  # 114 年報
WORK_DIR = os.path.join(os.path.dirname(__file__), '.clerk_stats_work')
os.makedirs(WORK_DIR, exist_ok=True)

S = requests.Session()
S.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

# 年報分類：cat 代碼 → 審級名（114 年報；換年若代碼變動需重對）
CATS = {
    '03': '司法院', '04': '最高法院', '05': '最高行政法院', '16': '懲戒法院',
    '07': '高等法院及分院', '08': '高等行政法院', '17': '智慧財產及商業法院',
    '10': '地方法院', '12': '法官學院',
}

NS_T = '{urn:oasis:names:tc:opendocument:xmlns:table:1.0}'
NS_X = '{urn:oasis:names:tc:opendocument:xmlns:text:1.0}'
NS_O = '{urn:oasis:names:tc:opendocument:xmlns:office:1.0}'


def scan():
    """掃年報各分類列表頁，收集標題含「實有人數」的表與 ODS 下載連結"""
    out = []
    for cat, org in CATS.items():
        for page in range(1, 20):
            url = f'https://www.judicial.gov.tw/tw/lp-{LP_ID}-{page}-xCat-{cat}.html'
            r = S.get(url, timeout=60)
            r.encoding = 'utf-8'
            trs = re.findall(r'<tr>\s*<td class="num[^>]*>.*?</tr>', r.text, re.S)
            if not trs:
                break
            for tr in trs:
                title = re.search(r'data-title="標題"><span>([^<]*)</span>', tr)
                ods = re.search(r'<a class="ods"[^>]*href="([^"]+)"', tr)
                if title and '實有人數' in title.group(1) and ods:
                    out.append({'cat': cat, 'org': org,
                                'title': title.group(1).strip(), 'ods': ods.group(1)})
            if f'lp-{LP_ID}-{page + 1}-xCat-{cat}' not in r.text:
                break
    return out


def read_ods(path):
    """ODS → list[sheet]，sheet = list[list[str]]。
    寬表會橫向分頁成多張 sheet（地院機關別表 4 張）；文字用 itertext()（法院名前有
    <text:s/> 縮排元素，p.text 會漏掉 tail 裡的名字）；數字取 office:value。"""
    z = zipfile.ZipFile(path)
    root = ET.fromstring(z.read('content.xml'))
    sheets = []
    for tbl in root.iter(f'{NS_T}table'):
        rows = []
        for row in tbl.iter(f'{NS_T}table-row'):
            cells = []
            for c in row:
                if c.tag not in (f'{NS_T}table-cell', f'{NS_T}covered-table-cell'):
                    continue
                rep = int(c.get(f'{NS_T}number-columns-repeated', 1))
                v = c.get(f'{NS_O}value')
                if v is None:
                    v = ''.join(''.join(p.itertext()) for p in c.iter(f'{NS_X}p'))
                cells += [str(v).strip()] * min(rep, 80)
            rows.append(cells)
        sheets.append(rows)
    return sheets


def classify_header(rows):
    """找英文表頭列，回傳 (header_row_idx, total_col, judge_cols, clerk_cols)。
    橫向分頁的續頁 sheet 沒有 Total 欄（total_col=None）；完全沒相關欄回 None。"""
    for i, r in enumerate(rows):
        total_col = None
        judges, clerks = [], []
        for j, h in enumerate(r):
            h = str(h)
            if not h:
                continue
            norm = re.sub(r'[-\s]', '', h).lower()  # 'Assist-ant Clerk' → 'assistantclerk'
            if total_col is None and norm == 'total':
                total_col = j
            if re.search(r'\bjudge\b', h, re.I) and 'judicial' not in norm:
                judges.append(j)
            # 排除錄事(assistantclerk)與會計/統計/人事室的課員(… of the … Office)
            if norm.startswith('c') and norm.startswith(('clerk', 'chiefclerk')) \
                    and 'ofthe' not in norm:
                clerks.append(j)
        if judges or clerks:
            return i, total_col, judges, clerks
    return None


def num(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def row_year(r):
    """計列的年份：西元年格右鄰是英文列標 'Total'（直接找 20xx 會誤抓人數值如 2085）"""
    for j, x in enumerate(r[:-1]):
        m = re.fullmatch(r'(20\d\d)(?:\.0)?', str(x))
        if m and str(r[j + 1]).strip() == 'Total' and 2010 <= int(m.group(1)) <= 2030:
            return int(m.group(1)) - 1911
    m = re.search(r'民國\s*(\d{3})\s*年', ' '.join(str(x) for x in r[:3]))
    return int(m.group(1)) if m else None


def parse_year_table(sheets):
    """年別表 → {year_roc: (total, judges, clerks)}；只取「計」列。
    多 sheet（橫向分頁）時各 sheet 貢獻自己欄位的加總。"""
    out = {}
    for rows in sheets:
        h = classify_header(rows)
        if not h:
            continue
        hi, tcol, jcols, ccols = h
        for r in rows[hi + 1:]:
            if '計' not in r[:4]:
                continue
            year = row_year(r)
            if year is None:
                continue
            cur = out.setdefault(year, [None, 0, 0])
            if tcol is not None and tcol < len(r) and num(r[tcol]) is not None:
                cur[0] = num(r[tcol])
            cur[1] += sum(num(r[j]) or 0 for j in jcols if j < len(r))
            cur[2] += sum(num(r[c]) or 0 for c in ccols if c < len(r))
    return {y: tuple(v) for y, v in out.items() if v[0] is not None}


SKIP_ORGS = ('合計', '總計', '臺灣高等法院及分院')  # 小計/總計列


def parse_org_table(sheets):
    """機關別表（單年快照）→ {court: [total, judges, clerks]}。
    地院表個別法院只有男/女列（名稱掛在男列、無計列），值＝男＋女；
    合計/小計列有計列，直接跳過不收。多 sheet 以法院名合併。"""
    out = {}
    for rows in sheets:
        h = classify_header(rows)
        if not h:
            continue
        hi, tcol, jcols, ccols = h
        # 先按法院收列（高院表每院有計列、地院表只有男/女列）
        per_org, cur = {}, None
        for r in rows[hi + 1:]:
            gi = next((i for i, g in enumerate(r[:5]) if g in ('計', '男', '女')), None)
            if gi is None:
                continue
            gender = r[gi]
            # 名稱＝性別格前最後一個非空格（高院表為 群組/法院 兩層巢狀欄）
            name = next((str(x).strip() for x in reversed(r[:gi]) if str(x).strip()), '')
            if name:
                cur = None if (name in SKIP_ORGS or name.startswith(('臺灣各', '福建各'))
                               or '小計' in name) else name
            if cur is None:
                continue
            per_org.setdefault(cur, {}).setdefault(gender, []).append(r)
        # 有計列用計列，否則男＋女
        for org, g in per_org.items():
            use = g.get('計') or g.get('男', []) + g.get('女', [])
            d = out.setdefault(org, [0, 0, 0])
            for r in use:
                if tcol is not None and tcol < len(r) and num(r[tcol]) is not None:
                    d[0] += num(r[tcol])
                d[1] += sum(num(r[j]) or 0 for j in jcols if j < len(r))
                d[2] += sum(num(r[c]) or 0 for c in ccols if c < len(r))
    return out


def run():
    tables = scan()
    trend = {}     # org → {year: (total, judges, clerks)}
    snapshot = {}  # court → [total, judges, clerks]
    for t in tables:
        fn = os.path.join(WORK_DIR, re.search(r'dl-(\d+)', t['ods']).group(1) + '.ods')
        if not os.path.exists(fn):
            r = S.get(t['ods'], timeout=120)
            open(fn, 'wb').write(r.content)
        sheets = read_ods(fn)
        if '機關別' in t['title'] and '年別' not in t['title']:
            part = parse_org_table(sheets)
            snapshot.update(part)
            print(f"-- [snapshot] {t['title']}：{len(part)} 機關", file=sys.stderr)
        else:
            data = parse_year_table(sheets)
            # 高行「按年別、機關別」表：年別列在前，僅取年別序列
            trend[t['org']] = data
            print(f"-- [trend] {t['org']} {min(data)}–{max(data)} ({len(data)} 年)", file=sys.stderr)

    print('-- clerk_staff_stats（審級×年）')
    vals = []
    for org, data in trend.items():
        for y, (tot, j, c) in sorted(data.items()):
            vals.append(f"  ({y}, '{org}', {tot}, {j}, {c})")
    print('INSERT INTO clerk_staff_stats (year_roc, org, total_staff, judges, clerks) VALUES')
    print(',\n'.join(vals))
    print('ON CONFLICT (year_roc, org) DO UPDATE SET total_staff=EXCLUDED.total_staff, judges=EXCLUDED.judges, clerks=EXCLUDED.clerks;')
    print()
    print('-- clerk_court_snapshot（114 年各法院）')
    vals = [f"  (114, '{n}', {v[0]}, {v[1]}, {v[2]})" for n, v in snapshot.items()]
    print('INSERT INTO clerk_court_snapshot (year_roc, court, total_staff, judges, clerks) VALUES')
    print(',\n'.join(vals))
    print('ON CONFLICT (year_roc, court) DO UPDATE SET total_staff=EXCLUDED.total_staff, judges=EXCLUDED.judges, clerks=EXCLUDED.clerks;')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'run'
    if cmd == 'scan':
        for t in scan():
            print(t['org'], '|', t['title'], '|', t['ods'])
    else:
        run()
