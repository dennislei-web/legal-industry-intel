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


def parse_rev_range(line):
    """從一行文字抽『保守～樂觀』區間，回 (low_wan, high_wan) 或 None"""
    pairs = re.findall(AMT, line)
    if not pairs:
        return None
    # 「1.05 億～1.48 億」或「5,700萬…8,100萬」→ 取頭尾兩個金額
    vals = [to_wan(num(v), u) for v, u in pairs]
    # 排除明顯是乘數/件數的行（此函式只吃已篩選過的行）
    if len(vals) == 1:
        return (vals[0], vals[0])
    return (min(vals[0], vals[-1]), max(vals[0], vals[-1]))


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
    # 營收：第六節切片，找合計行
    sec6 = ''
    m = re.search(r'\n## 六[、.].*?(?=\n## 七|\Z)', a, re.S)
    if m:
        sec6 = m.group(0)
    # 只認「合計/總計」行內的明確區間「約 X–Y 億/萬」（首數字單位可省略），取最後一個合計行
    RANGE = re.compile(r'([\d,]+(?:\.\d+)?)\s*(億|萬)?\s*(?:元)?\s*[–~～\-]\s*([\d,]+(?:\.\d+)?)\s*(億|萬)')
    rev = None
    cands = [l for l in sec6.split('\n') if re.search(r'合計|總計', l)]
    for l in reversed(cands):
        m2 = RANGE.search(l)
        if m2:
            u1 = m2.group(2) or m2.group(4)
            lo = to_wan(num(m2.group(1)), u1)
            hi = to_wan(num(m2.group(3)), m2.group(4))
            if 0 < lo <= hi and hi / max(lo, 1) < 20:  # 排除抓到係數/件數的荒謬區間
                rev = (lo, hi)
                break
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
