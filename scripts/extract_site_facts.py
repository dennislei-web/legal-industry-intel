"""
官網結構化抽取（第一階段：定位／團隊揭露／進線管道）— mig 278

對 firm_websites 驗證通過、連得上的法律事務所官網：
  抓首頁＋最多 MAX_SUBPAGES 個相關子頁 → 存文字快照（firm_site_snapshots）
  → 用規則抽結構化欄位（firm_site_facts）。不經語言模型，結果可重現。

定位怎麼判：
  領域詞出現在「網頁標題／meta 描述」加 5 分、「選單連結文字／h1–h3 小標」加 3 分、內文每詞最多 3 分。
  主打領域＝標題／選單／小標那一層有分的領域（依總分排序，最多 6 個）。
  光是內文提到不算主打——幾乎每間都會在內文寫「法律顧問」「刑事」。
  客群＝主打領域裡企業類與個人類的分數比。

環境變數：
  LIMIT=0          只跑前 N 間（按上次抽取時間舊者優先）
  DRY_RUN=false    true＝只印不寫
  ONLY=所名         只跑指定事務所（逗號分隔，測試用）
  WORKERS=8  MAX_SUBPAGES=10
"""
import html as html_mod
import os
import re
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from urllib.parse import urljoin, urlparse

import requests

from recheck_firm_websites import API_HEADERS, BASE, _retry, load_roster, log, rest_get_all
from website_verify import LINK_RE, WS_RE, fetch_page, page_text

LIMIT = int(os.environ.get('LIMIT', '0') or 0)
DRY_RUN = os.environ.get('DRY_RUN', 'false').lower() == 'true'
ONLY = [x.strip() for x in os.environ.get('ONLY', '').split(',') if x.strip()]
WORKERS = int(os.environ.get('WORKERS', '8') or 8)
MAX_SUBPAGES = int(os.environ.get('MAX_SUBPAGES', '10') or 10)
PAGE_TEXT_CAP = 6000

SUBPAGE_HINT = re.compile(
    r'團隊|律師|成員|關於|簡介|介紹|聯絡|據點|服務|專業|業務|領域|收費|費用|諮詢|預約'
    r'|about|team|lawyer|attorney|people|member|contact|service|practice|expertise|fee|price', re.I)

# 領域分類：企業類（B）／個人類（C）／中性（N）
AREAS = {
    '家事':       ('C', ['離婚', '監護', '親權', '扶養', '繼承', '遺產', '遺囑', '家事', '收養', '剩餘財產', '婚姻']),
    '刑事':       ('C', ['刑事', '辯護', '詐欺', '毒品', '酒駕', '偵查', '不起訴', '妨害名譽', '竊盜', '傷害', '告訴']),
    '車禍交通':   ('C', ['車禍', '交通事故', '肇事']),
    '債務執行':   ('C', ['債務', '強制執行', '支付命令', '本票', '借款', '消債', '更生', '清算', '討債', '欠款']),
    '消費保險':   ('C', ['消費糾紛', '消保', '保險理賠', '理賠']),
    '性平':       ('C', ['性騷擾', '性平', '跟蹤騷擾', '性侵', '妨害性自主']),
    '勞動':       ('N', ['勞資', '勞動', '資遣', '職災', '加班費', '解僱', '職場霸凌', '勞基法']),
    '不動產':     ('N', ['不動產', '土地', '房屋', '租賃', '共有物', '都更', '危老', '公寓大廈', '越界', '買賣糾紛']),
    '行政':       ('N', ['行政訴訟', '訴願', '國家賠償', '行政救濟', '公務員', '政府採購']),
    '醫療':       ('N', ['醫療糾紛', '醫療過失', '醫療訴訟', '醫療法']),
    '公司商務':   ('B', ['公司法', '公司治理', '股東', '併購', '投資', '契約審閱', '合約審閱', '企業法務', '商務契約',
                         '新創', '法遵', '常年法律顧問', '企業法律顧問']),
    '智慧財產':   ('B', ['智慧財產', '專利', '商標', '著作權', '營業秘密']),
    '金融證券':   ('B', ['證券', '金融', '銀行', '期貨', '洗錢', '虛擬貨幣', '資本市場']),
    '稅務':       ('B', ['稅務', '稅捐', '稅法', '租稅']),
    '工程':       ('B', ['工程', '營建', '承攬', '工程款']),
    '涉外':       ('B', ['涉外', '跨境', '跨國', '兩岸', '外國人', '移民', '國際貿易', '海商']),
    '科技個資':   ('B', ['個資', '資安', '電商', '科技法', '人工智慧', '隱私']),
}
HEAD_RE = re.compile(r'<h[1-3][^>]*>(.*?)</h[1-3]>', re.S | re.I)
NAV_RE = re.compile(r'<(?:nav|header)\b.*?</(?:nav|header)>', re.S | re.I)
TITLE_RE = re.compile(r'<title[^>]*>(.*?)</title>', re.S | re.I)
META_DESC_RE = re.compile(
    r'<meta[^>]+(?:name|property)=["\'](?:description|og:description)["\'][^>]*content=["\']([^"\']*)["\']'
    r'|<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:name|property)=["\'](?:description|og:description)["\']', re.I)
INNER_TAG = re.compile(r'<[^>]+>')

LINE_RE = re.compile(r'https?://(?:line\.me|lin\.ee|page\.line\.me|liff\.line\.me)/[^\s"\'<>)]+', re.I)
FB_RE = re.compile(r'https?://(?:www\.|m\.)?facebook\.com/(?!sharer|share|tr\b|plugins|dialog)[^\s"\'<>?)]+', re.I)
IG_RE = re.compile(r'https?://(?:www\.)?instagram\.com/[^\s"\'<>?)]+', re.I)
YT_RE = re.compile(r'https?://(?:www\.)?youtube\.com/(?:@|channel/|c/|user/)[^\s"\'<>?)]+', re.I)
PHONE_RE = re.compile(r'(?<!\d)(0\d{1,2})[\-\s)）]{0,2}(\d{3,4})[\-\s]?(\d{3,4})(?!\d)')
FEE_RE = re.compile(r'[^。；\n]{0,30}(?:諮詢|收費|費用|每小時|鐘點|半小時|一小時)[^。；\n]{0,25}?(?:NT\$?|新[台臺]幣)?\s?\d[\d,]{2,}\s?元[^。；\n]{0,15}')
EXJ_RE = re.compile(r'[^。；\n]{0,12}(?:前|曾任)[^。；\n]{0,14}(?:法官(?!助理)|檢察官(?!助理)|庭長|檢察長)[^。；\n]{0,10}')
DATE_RE = re.compile(r'(20[12]\d)\s?[-/.年]\s?(1[0-2]|0?[1-9])\s?[-/.月]\s?(3[01]|[12]\d|0?[1-9])')
COPY_RE = re.compile(r'(?:©|&copy;|copyright)\D{0,25}(?:20\d\d\s?[-–~]\s?)?(20\d\d)', re.I)
FORM_RE = re.compile(r'<form\b.*?</form>', re.S | re.I)
NAME_LAWYER_RE = re.compile(r'([一-鿿]{2,3})\s?(?:律師|主持律師|合夥律師|所長)')
SURNAMES = set('陳林黃張李王吳劉蔡楊許鄭謝洪郭邱曾廖賴徐周葉蘇莊呂江何蕭羅高潘簡朱鍾游彭詹胡施沈余盧梁趙顏柯翁魏孫戴范方宋鄧杜傅侯曹薛丁卓阮馬董温溫唐藍石蔣古紀姚連馮歐程湯黎康田姜白汪鄒尤巫鐘涂龔嚴韓袁金童陸夏柳凃邵錢伍倪駱熊任甘秦顧毛章史官萬俞雷粘饒闕凌崔尹孔辛武辜陶易段龍韋葛池孟褚殷麥賀賈莫文管關向包丘梅華利裴樊房全佘左花魯安鮑郝穆塗邢蒲成谷常閻練盛鄔耿聶符申祝繆陽解曲岳齊籃應單舒畢喬龎翟牛鄞留季')
NAME_STOP = re.compile(r'民國|全國|全台|全臺|各地|當地|在地|執業|實習|外國|專業|推薦|事務|諮詢|團隊|顧問|主持|合夥|資深|受僱|本所|我們|委任|聘請|指定|公會|離婚|刑事|民事|家事|車禍|'
                       r'法律|訴訟|辯護|名律|大律|找律|請律|任律|為律|位律|的律|與律|和律|及律|或律|是律|由律|向律|讓律')


def log_(m):
    log(m)


def area_scores(pages_html):
    """回 (總分 dict, 標題選單層分數 dict)"""
    total, top = Counter(), Counter()
    for i, html in enumerate(pages_html):
        title = ' '.join(m for m in TITLE_RE.findall(html))
        desc = ' '.join((a or b) for a, b in META_DESC_RE.findall(html))
        heads = ' '.join(INNER_TAG.sub('', h) for h in HEAD_RE.findall(html))
        nav = ' '.join(INNER_TAG.sub(' ', n) for n in NAV_RE.findall(html))
        hi = WS_RE.sub('', html_mod.unescape(title + ' ' + desc))
        mid = WS_RE.sub('', html_mod.unescape(heads + ' ' + nav))
        body = page_text(html)
        for area, (_, kws) in AREAS.items():
            for kw in kws:
                # 首頁的標題／描述權重最高；子頁的標題只算選單層
                if kw in hi:
                    pts = 5 if i == 0 else 3
                    total[area] += pts
                    top[area] += pts
                if kw in mid:
                    total[area] += 3
                    top[area] += 3
                total[area] += min(3, body.count(kw))
    return total, top


def extract(firm, url, lawyers):
    st, html, final = fetch_page(url)
    if not html or st == 0 or st >= 400:
        return None
    host = urlparse(final).netloc.lower().removeprefix('www.')
    pages = [(final, html)]
    seen = set()
    for href, inner in LINK_RE.findall(html):
        p = urlparse(urljoin(final, href.strip()))
        if p.scheme not in ('http', 'https') or p.netloc.lower().removeprefix('www.') != host:
            continue
        if re.search(r'\.(jpg|jpeg|png|gif|pdf|zip|docx?|xlsx?|mp4)$', p.path, re.I):
            continue
        k = (p.path.rstrip('/'), p.query)
        if k in seen or k == ('', ''):
            continue
        seen.add(k)
        txt = html_mod.unescape(INNER_TAG.sub('', inner))
        if SUBPAGE_HINT.search(txt) or SUBPAGE_HINT.search(p.path):
            s2, h2, _ = fetch_page(p.geturl(), timeout=15)
            if h2 and 0 < s2 < 400:
                pages.append((p.geturl(), h2))
            if len(pages) > MAX_SUBPAGES:
                break

    htmls = [h for _, h in pages]
    raw = '\n'.join(htmls)
    low = raw.lower()
    texts = [page_text(h) for h in htmls]
    text = ''.join(texts)
    # 帶標點的版本（page_text 會去空白，句界靠全形標點；這裡另留空白版給片段擷取）
    loose = WS_RE.sub(' ', html_mod.unescape(re.sub(r'<script[^>]*>.*?</script>|<style[^>]*>.*?</style>|<[^>]+>', '\n', raw, flags=re.S | re.I)))

    # ---- 定位 ----
    total, top = area_scores(htmls)
    focus = [a for a, _ in sorted(top.items(), key=lambda x: -total[x[0]]) if top[a] >= 3][:6]
    focus_basis = '標題選單'
    if not focus:
        # 沒有選單／小標結構的站（Google Sites、單頁式）：退而取內文反覆出現的前 4 個領域
        focus = [a for a, s in total.most_common(4) if s >= 4]
        focus_basis = '內文' if focus else None
    mentioned = [a for a, s in total.most_common() if s >= 2]
    b = sum(total[a] for a in focus if AREAS[a][0] == 'B')
    c = sum(total[a] for a in focus if AREAS[a][0] == 'C')
    if b + c == 0:
        client = '不明'
    elif b >= 2 * c:
        client = '企業'
    elif c >= 2 * b:
        client = '個人'
    else:
        client = '綜合'
    descs = [(a or b_) for a, b_ in META_DESC_RE.findall(htmls[0])]
    t0 = TITLE_RE.search(htmls[0])
    tagline = WS_RE.sub(' ', html_mod.unescape((descs[0] if descs and descs[0].strip() else (t0.group(1) if t0 else '')))).strip()[:300] or None

    # ---- 團隊 ----
    names = sorted({(l.get('name') or '').strip() for l in lawyers
                    if len((l.get('name') or '').strip()) >= 2 and '?' not in (l.get('name') or '')})
    listed = [n for n in names if n in text]
    unlisted = [n for n in names if n not in text]
    extra = Counter()
    for m in NAME_LAWYER_RE.finditer(text):
        n = m.group(1)
        # 三字抓到的可能前面多黏一個字（「與王小明律師」），取後兩三字且首字為常見姓
        for cand in (n, n[1:]):
            if 2 <= len(cand) <= 3 and cand[0] in SURNAMES and not NAME_STOP.search(cand + '律'):
                if cand not in names:
                    extra[cand] += 1
                break
    extra_names = [n for n, k in extra.most_common(40) if k >= 2 and not any(n in x or x in n for x in names)][:25]
    exj = EXJ_RE.search(loose)

    # ---- 進線 ----
    lines = LINE_RE.findall(raw)
    forms = [f for f in FORM_RE.findall(raw) if not re.search(r'role=["\']search|name=["\']s["\']|type=["\']search', f, re.I)]
    contact_form = any(re.search(r'<textarea|type=["\']email|type=["\']tel|姓名|電話|諮詢|留言', f, re.I) for f in forms)
    phones = []
    for a_, b2, c2 in PHONE_RE.findall(loose):
        p = f'{a_}-{b2}{c2}'
        if p not in phones and len(b2 + c2) >= 7:
            phones.append(p)
    fee = FEE_RE.search(loose)
    fb, ig, yt = FB_RE.search(raw), IG_RE.search(raw), YT_RE.search(raw)

    # ---- 網站本身 ----
    plat = ('WordPress' if 'wp-content' in low else 'Wix' if 'wixstatic' in low or 'wix.com' in low else
            'Webnode' if 'webnode' in low else 'Weebly' if 'weebly' in low else
            'Google Sites' if 'sites.google' in low else 'Squarespace' if 'squarespace' in low else
            'Joomla' if 'joomla' in low else 'Strikingly' if 'strikingly' in low else '其他')
    today = date.today()
    yrs = [int(y) for y in COPY_RE.findall(raw) if int(y) <= today.year]
    latest = None
    for y, mo, d in DATE_RE.findall(loose):
        try:
            dt = date(int(y), int(mo), int(d))
        except ValueError:
            continue
        if dt <= today and (latest is None or dt > latest):
            latest = dt
    langs = []
    if re.search(r'href="[^"]*/(en|english|en-us)(/|"|\?)|>\s*(English|EN)\s*<', raw, re.I):
        langs.append('英文')
    if re.search(r'href="[^"]*/(jp|ja|japanese)(/|"|\?)|>\s*日本語\s*<', raw, re.I):
        langs.append('日文')

    facts = {
        'firm_name': firm, 'website_url': final, 'page_count': len(pages), 'text_chars': len(text),
        'focus_areas': focus, 'focus_basis': focus_basis, 'mentioned_areas': mentioned,
        'area_scores': dict(total.most_common()),
        'client_type': client, 'tagline': tagline,
        'roster_total': len(names), 'roster_listed': len(listed), 'listed_names': listed,
        'unlisted_names': unlisted, 'extra_names': extra_names,
        'has_bio': bool(re.search(r'學歷|經歷|畢業|法律系|法學碩士|法律學系|LL\.?M|律師高考', text)),
        'ex_judicial': bool(exj), 'ex_judicial_snippet': exj.group(0).strip()[:120] if exj else None,
        'has_line': bool(lines) or bool(re.search(r'LINE\s?(?:ID|＠|@)', loose, re.I)),
        'line_url': lines[0][:300] if lines else None,
        'has_form': contact_form,
        'has_booking': bool(re.search(r'線上預約|預約諮詢|立即預約|預約時間|我要預約', text)),
        'phones': phones[:5],
        'fb_url': fb.group(0)[:300] if fb else None, 'ig_url': ig.group(0)[:300] if ig else None,
        'yt_url': yt.group(0)[:300] if yt else None,
        'free_consult': bool(re.search(r'免費(?:法律)?諮詢|免費線上諮詢|首次諮詢免費|諮詢免費', text)),
        'fee_disclosed': bool(fee), 'fee_snippet': fee.group(0).strip()[:160] if fee else None,
        'platform': plat, 'copyright_year': max(yrs) if yrs else None,
        'latest_content_date': latest.isoformat() if latest else None,
        'langs': langs, 'has_branches': bool(re.search(r'分所|[台臺]北所|[台臺]中所|高雄所|桃園所|新竹所|[台臺]南所', text)),
    }
    snap = {'firm_name': firm, 'website_url': final, 'page_count': len(pages), 'text_chars': len(text),
            'pages': [{'url': u[:500],
                       'title': (WS_RE.sub(' ', html_mod.unescape(TITLE_RE.search(h).group(1))).strip()[:200]
                                 if TITLE_RE.search(h) else None),
                       # jsonb 不收 NUL 字元（少數站的 HTML 夾帶，會讓整筆寫入回 400）
                       'text': t[:PAGE_TEXT_CAP].replace('\x00', '')} for (u, h), t in zip(pages, texts)]}
    for k in ('tagline', 'fee_snippet', 'ex_judicial_snippet'):
        if facts[k]:
            facts[k] = facts[k].replace('\x00', '')
    return facts, snap


def upsert(table, body):
    h = dict(API_HEADERS)
    h['Content-Type'] = 'application/json'
    h['Prefer'] = 'resolution=merge-duplicates,return=minimal'
    _retry(lambda: requests.post(f'{BASE}/{table}', params={'on_conflict': 'firm_name'}, headers=h, json=body, timeout=60))


def main():
    roster = load_roster()
    rows = rest_get_all('firm_websites', {'select': 'id,firm_name,website_url',
                                          'verified': 'is.true', 'health_status': 'eq.ok'}, 'id.asc')
    # 人工補的官網（firm_profiles）優先：大所幾乎都在這裡，自動搜尋那邊沒有
    manual = {r['firm_name']: r['website_url'].strip() for r in
              rest_get_all('firm_profiles', {'select': 'id,firm_name,website_url', 'website_url': 'not.is.null'}, 'id.asc')
              if (r.get('website_url') or '').strip().lower().startswith('http')}
    by_name = {r['firm_name']: r for r in rows}
    for name, url in manual.items():
        by_name[name] = {'id': None, 'firm_name': name, 'website_url': url}
    rows = [r for r in by_name.values() if '法律事務所' in r['firm_name'] or '律師事務所' in r['firm_name']]
    done ={r['firm_name']: r['extracted_at'] for r in
            rest_get_all('firm_site_facts', {'select': 'firm_name,extracted_at'}, 'firm_name.asc')}
    if ONLY:
        rows = [r for r in rows if r['firm_name'] in ONLY]
    if os.environ.get('MISSING_ONLY', 'false').lower() == 'true':
        # 只補還沒有快照的（上次連不上或寫入失敗的）
        have = {r['firm_name'] for r in rest_get_all('firm_site_snapshots', {'select': 'firm_name'}, 'firm_name.asc')}
        rows = [r for r in rows if r['firm_name'] not in have]
    rows.sort(key=lambda r: done.get(r['firm_name']) or '')
    if LIMIT:
        rows = rows[:LIMIT]
    log_(f'待抽取 {len(rows)} 間（DRY_RUN={DRY_RUN}）')
    now = datetime.now(timezone.utc).isoformat()
    ok = fail = 0
    t0 = time.time()

    def run(r):
        try:
            return r, extract(r['firm_name'], r['website_url'], roster.get(r['firm_name'].replace(' ', ''), []))
        except Exception as e:  # 單一網站的怪格式不該讓整批中斷
            return r, e

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for i, (r, res) in enumerate(ex.map(run, rows), 1):
            if res is None or isinstance(res, Exception):
                fail += 1
                if isinstance(res, Exception):
                    log_(f'  ✗ {r["firm_name"]}：{type(res).__name__} {res}')
            else:
                facts, snap = res
                ok += 1
                if DRY_RUN:
                    log_(f'  {r["firm_name"]} | 主打 {facts["focus_areas"]} | {facts["client_type"]} | '
                         f'名冊 {facts["roster_listed"]}/{facts["roster_total"]} 另見 {facts["extra_names"][:5]} | '
                         f'LINE {facts["has_line"]} 表單 {facts["has_form"]} 預約 {facts["has_booking"]} | '
                         f'免費 {facts["free_consult"]} 收費 {facts["fee_snippet"]} | 前司法官 {facts["ex_judicial_snippet"]} | '
                         f'{facts["platform"]} ©{facts["copyright_year"]} 最新 {facts["latest_content_date"]} | {facts["page_count"]} 頁')
                else:
                    try:
                        upsert('firm_site_facts', dict(facts, extracted_at=now))
                        upsert('firm_site_snapshots', dict(snap, fetched_at=now))
                    except Exception as e:
                        fail += 1
                        ok -= 1
                        log_(f'  寫入失敗 {r["firm_name"]}：{e}')
            if i % 100 == 0:
                log_(f'  [{i}/{len(rows)}] 成功 {ok} 失敗 {fail}，{time.time() - t0:.0f}s')
    log_(f'完成：成功 {ok}、失敗 {fail}')
    if rows and fail > len(rows) * 0.3:
        sys.exit(1)


if __name__ == '__main__':
    if sys.platform == 'win32':
        sys.stdout.reconfigure(encoding='utf-8')
    main()
