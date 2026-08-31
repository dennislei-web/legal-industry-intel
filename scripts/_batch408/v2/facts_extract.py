# -*- coding: utf-8 -*-
"""firm_facts 抽取：把 ai_analysis 文字＋leaders json＋DB 訊號抽成每所一列的分析資料集。
輸出：facts.tsv（同目錄）。營收/掛名等文字欄位抽取為啟發式，parse 不到留空並計數回報。
"""
import io, os, json, re, sys, urllib.request, urllib.parse

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
ROOT = r"C:\projects\legal-industry-intel\scripts\_batch408"
ENV = r"C:\projects\legal-industry-intel\scripts\.env"

env = {}
for ln in io.open(ENV, encoding='utf-8-sig'):
    ln = ln.strip()
    if ln and '=' in ln and not ln.startswith('#'):
        k, v = ln.split('=', 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
URL = env['SUPABASE_URL']
KEY = env.get('SUPABASE_SERVICE_KEY') or env.get('SUPABASE_KEY')


def getall(path):
    out, start = [], 0
    while True:
        req = urllib.request.Request(URL + path, headers={
            'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
            'Range': '%d-%d' % (start, start + 999)})
        with urllib.request.urlopen(req) as r:
            rows = json.load(r)
        out += rows
        if len(rows) < 1000:
            break
        start += 1000
    return out


def num(s):
    return float(s.replace(',', ''))


def to_wan(val, unit):
    return val * 10000 if unit == '億' else val


AMT = r'([\d,]+(?:\.\d+)?)\s*(億|萬)'
RANGE = re.compile(r'([\d,]+(?:\.\d+)?)\s*(億|萬)?\s*(?:元)?\s*[–~～\-]\s*([\d,]+(?:\.\d+)?)\s*(億|萬)')
AMT_ONE = re.compile(AMT)


def _rng_val(m2):
    u1 = m2.group(2) or m2.group(4)
    lo = to_wan(num(m2.group(1)), u1)
    hi = to_wan(num(m2.group(3)), m2.group(4))
    if 0 < lo <= hi and hi / max(lo, 1) < 20:  # 排除抓到係數/件數的荒謬區間
        return (lo, hi)
    return None


FIVE_Y = re.compile(r'[5５五]\s*年|累計')
PER_Y = re.compile(r'[／/]\s*年|每年|年化|年營收')


def _parse_rev_line(l, header=''):
    """單一合計行 → 年化 (low_wan, high_wan) 或 None。header＝表格標頭行（僅表格列用）。
    表格列只看短值格（避開說明欄行情數字）；表頭標「5年」口徑且值格未標「/年」→ ÷5。
    散文行「年化」標記後的區間優先（「5 年營收」的年營收是 5 年值、不算標記）；
    無標記時取最後一個合計字樣後的區間，行含「5 年/累計」且區間後未緊跟「／年」→ ÷5。"""
    cells = [c.strip() for c in l.split('|')]
    if l.lstrip().startswith('|') and len(cells) >= 4:
        if not re.search(r'合計|總計', cells[1]):
            return None  # 表格列但標籤不是合計（合計字樣在說明欄）→ 整行跳過
        tbl5 = bool(FIVE_Y.search(header)) and not PER_Y.search(header)
        vals = []
        for c in cells[2:]:
            if len(c) > 40:
                continue  # 長格＝說明欄，內含行情/件數雜訊
            div = 5.0 if tbl5 and not PER_Y.search(c) else 1.0
            mr = RANGE.search(c)
            if mr:
                v = _rng_val(mr)
                if v:
                    return (v[0] / div, v[1] / div)  # 單格即區間（如「約 1,300～1,900 萬/年」）
            ma = AMT_ONE.search(c)
            if ma:
                vals.append(to_wan(num(ma.group(1)), ma.group(2)) / div)
        if len(vals) == 2 and 0 < vals[0] <= vals[1] and vals[1] / max(vals[0], 1) < 20:
            return (vals[0], vals[1])
        return None
    last_hj = None
    for mh in re.finditer(r'合計|總計', l):
        last_hj = mh
    for mk in re.finditer(r'年化|年營收', l):
        if mk.start() <= last_hj.start():
            continue  # 合計字樣前的年化是分項值（如「年化得標僅約20–30萬…合計約3,600–4,800萬」）
        if mk.group(0) == '年營收' and re.search(r'[0-9５五]\s*$', l[:mk.start()]):
            continue  # 「5 年營收」= 5 年值，非年化標記
        m2 = RANGE.search(l, mk.end())
        if m2:
            v = _rng_val(m2)
            if v:
                return v
    m2 = RANGE.search(l, last_hj.end()) or RANGE.search(l)
    if m2:
        v = _rng_val(m2)
        if v:
            tail = l[m2.end():m2.end() + 12]
            if FIVE_Y.search(l) and not re.search(r'[／/]\s*年|每年', tail):
                return (v[0] / 5.0, v[1] / 5.0)
            return v
    return None


def parse_rev_sec6(sec6):
    """第六節 → 年化 (low_wan, high_wan) 或 None。
    先剔除 <details> 摺疊（v2.1 的通用計算邏輯區，內含中間計算合計行）；
    「三側合計/小計/加總」行優先（全所口徑），沒有再走一般合計行，皆由後往前。"""
    body = re.sub(r'<details>.*?(</details>|\Z)', '', sec6, flags=re.S)
    lines = body.split('\n')
    cands = []  # (行, 所屬表格標頭行)
    for i, l in enumerate(lines):
        if not re.search(r'合計|總計', l):
            continue
        header = ''
        if l.lstrip().startswith('|'):
            j = i
            while j > 0 and lines[j - 1].lstrip().startswith('|'):
                j -= 1
            header = lines[j]
        cands.append((l, header))
    for only_3side in (True, False):
        for l, header in reversed(cands):
            if only_3side and '三側' not in l:
                continue
            v = _parse_rev_line(l, header)
            if v:
                return v
    return None


def extract(a):
    f = {}
    # 型態：**【X型】**
    m = re.search(r'【(B2C行銷型|傳統轉介型|機構標案型|企業非訟型|精品專業型|一人綜合型)】', a)
    f['type'] = m.group(1) if m else ''
    # 30秒速讀規模行（分段容錯：位後可帶括號、件數前可有「約/署名合計」等）
    scale_line = ''
    m = re.search(r'[^\n]*規模與案量[^\n]*', a)
    if m:
        scale_line = m.group(0)
    m = re.search(r'在籍\s*([\d,]+)\s*位（([^）]*)）', scale_line)
    f['roster_n'] = int(num(m.group(1))) if m else ''
    f['region_txt'] = m.group(2)[:12] if m else ''
    m = re.search(r'有出庭\s*([\d,]+)\s*位', scale_line)
    f['court_n'] = int(num(m.group(1))) if m else ''
    m = re.search(r'近\s*5\s*年[^｜|\n]*?([\d,]+)\s*件', scale_line)
    f['cases_5y'] = int(num(m.group(1))) if m else ''
    # 營收：第六節切片，找合計行（年化優先；5 年累計 ÷5；表格列走值欄）
    sec6 = ''
    m = re.search(r'\n## 六[、.].*?(?=\n## 七|\Z)', a, re.S)
    if m:
        sec6 = m.group(0)
    rev = parse_rev_sec6(sec6)
    f['rev_low_wan'], f['rev_high_wan'] = (round(rev[0]), round(rev[1])) if rev else ('', '')
    # 掛名判定（第二節）
    sec2 = ''
    m = re.search(r'\n## 二[、.].*?(?=\n## 三|\Z)', a, re.S)
    if m:
        sec2 = m.group(0)
    neg = re.search(r'排除掛名|非掛名|不構成掛名|無掛名|未達掛名|掛名.{0,6}排除|不符掛名', sec2)
    pos = re.search(r'判(為|定|斷為)掛名|掛名(制度)?確證|屬掛名|掛名制度成立|→\s*掛名|確證.{0,4}掛名|掛名/督導', sec2)
    if pos and not (neg and not pos):
        f['concentration'] = '掛名制度'
    elif re.search(r'真集中|真實(關鍵人)?集中|關鍵人(依賴|風險|集中)', sec2):
        f['concentration'] = '真集中'
    elif neg or re.search(r'無明顯集中|分布(平均|均勻)|承辦廣度佳', sec2):
        f['concentration'] = '分散/非掛名'
    else:
        f['concentration'] = '不明'
    # 接班風險（第五節）
    # 只認速讀「最大風險」行點名接班/斷層/高齡/熄燈者（第五節照規格必談接班，不能當訊號）
    mrisk = re.search(r'[^\n]*最大風險[^\n]*', a)
    f['succession_risk'] = 1 if (mrisk and re.search(r'接班|斷層|高齡|熄燈|世代交替', mrisk.group(0))) else 0
    return f


def main():
    rows = getall('/rest/v1/firm_profiles?select=firm_name,ai_analysis,practice_focus,founded_year,ex_judicial_officers&ai_analysis=not.is.null')
    cache = {r['firm_name']: r for r in getall('/rest/v1/moj_firm_stats_cache?select=firm_name,lawyer_count,main_region,avg_cases')}
    gplaces = {r['firm_name']: r for r in getall('/rest/v1/firm_google_places?select=firm_name,rating,reviews_count')}
    dsig = {r['firm_name']: r for r in getall('/rest/v1/firm_digital_signals?select=*')}
    gov = {}
    for r in getall('/rest/v1/gov_tender_firms?select=firm_name,award_amount,is_winner&is_winner=eq.true'):
        gov[r['firm_name']] = gov.get(r['firm_name'], 0) + (r.get('award_amount') or 0)
    indep = {}
    for r in getall('/rest/v1/firm_indep_directorships?select=office_normalized'):
        k = r.get('office_normalized')
        if k:
            indep[k] = indep.get(k, 0) + 1
    awards = {}
    try:
        for r in getall('/rest/v1/firm_awards?select=firm_name'):
            awards[r['firm_name']] = awards.get(r['firm_name'], 0) + 1
    except Exception:
        pass

    # leaders json 補 type/tagline（文字抽不到時）
    ldir = os.path.join(ROOT, 'leaders')
    ljson = {}
    for fn in os.listdir(ldir):
        if fn.endswith('.json'):
            try:
                d = json.load(io.open(os.path.join(ldir, fn), encoding='utf-8'))
                ljson[d.get('firm', fn[:-5])] = d
            except Exception:
                pass

    out = []
    miss = {'type': 0, 'scale': 0, 'rev': 0}
    for r in rows:
        nm = r['firm_name']
        a = r['ai_analysis'] or ''
        f = extract(a)
        lj = ljson.get(nm, {})
        if not f['type']:
            f['type'] = lj.get('type', '')
        if not f['type']:
            miss['type'] += 1
        if f['roster_n'] == '':
            miss['scale'] += 1
        if f['rev_low_wan'] == '':
            miss['rev'] += 1
        c = cache.get(nm, {})
        g = gplaces.get(nm, {})
        d = dsig.get(nm, {})
        sig = []
        for k, tag in (('fb_url', 'fb'), ('line_url', 'line'), ('ig_url', 'ig'), ('yt_url', 'yt')):
            if d.get(k):
                sig.append(tag)
        pixel = 1 if d.get('has_fb_pixel') else 0
        gads = 1 if d.get('has_google_ads') else 0
        exj = r.get('ex_judicial_officers') or []
        out.append({
            'firm': nm,
            'lawyer_count': c.get('lawyer_count', ''),
            'region': c.get('main_region', '') or f['region_txt'],
            'avg_cases': c.get('avg_cases', ''),
            'type': f['type'],
            'founded_year': r.get('founded_year') or '',
            'roster_n': f['roster_n'],
            'court_n': f['court_n'],
            'cases_5y': f['cases_5y'],
            'rev_low_wan': f['rev_low_wan'],
            'rev_high_wan': f['rev_high_wan'],
            'concentration': f['concentration'],
            'succession_risk': f['succession_risk'],
            'ex_judicial_n': len(exj),
            'practice_focus': ','.join(r.get('practice_focus') or []),
            'g_rating': g.get('rating', ''),
            'g_reviews': g.get('reviews_count', ''),
            'social': '+'.join(sig),
            'fb_pixel': pixel,
            'google_ads': gads,
            'gov_tender_amt': round(gov.get(nm, 0)),
            'indep_seats': indep.get(nm, 0),
            'awards_n': awards.get(nm, 0),
            'tagline': lj.get('tagline', ''),
        })
    cols = list(out[0].keys())
    dst = os.path.join(ROOT, 'v2', 'facts.tsv')
    with io.open(dst, 'w', encoding='utf-8', newline='\n') as fp:
        fp.write('\t'.join(cols) + '\n')
        for o in out:
            fp.write('\t'.join(str(o[c]) for c in cols) + '\n')
    print('rows=%d  miss_type=%d miss_scale=%d miss_rev=%d  -> %s' % (
        len(out), miss['type'], miss['scale'], miss['rev'], dst))


if __name__ == '__main__':
    main()
