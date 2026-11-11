"""
官網驗證共用模組 — scrape_firm_websites.py（寫入前驗證）與
verify_firm_websites.py（既有資料重驗）共用。

驗證原則：官網 = 該網域「首頁」看得到事務所主名。
- 新聞報導/名錄/公會頁的首頁不會有特定事務所名 → 自然淘汰
- 掛在別家事務所網站上的個人介紹頁：該站首頁沒有本所名 → 淘汰
- 通過者一律把 URL 正規化為首頁（deep link 不當官網存）
"""
import html as html_mod
import re
import subprocess
import requests
import urllib3
from urllib.parse import urlparse

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VERIFY_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
}

# 台灣事務所的官網不會掛在這些國家 TLD（日本/中國同名律所是實測過的錯配源）
FOREIGN_TLD_RE = re.compile(r'\.(jp|cn|kr|hk|mo|br|ru|in|vn|th|my)$')

TAG_RE = re.compile(r'<script[^>]*>.*?</script>|<style[^>]*>.*?</style>|<[^>]+>', re.S | re.I)
WS_RE = re.compile(r'\s+')

COMPANY_SUFFIX_RE = re.compile(r'(股份有限公司|有限公司|臺灣分公司|台灣分公司|分公司|\(股\)公司|公司)$')
FIRM_SUFFIX_RE = re.compile(r'(國際|聯合|商務)*(法律|律師|法律專利|專利法律|法律地政士|工商法務|外國法事務律師|外國法律)*(事務所|法務所).*$')


def load_blocklist(sb):
    """從 firm_website_blocklist 表載入黑名單網域"""
    rows = sb.table('firm_website_blocklist').select('domain').execute().data or []
    return {r['domain'] for r in rows}


def host_blocked(host, blocklist):
    host = (host or '').lower()
    if FOREIGN_TLD_RE.search(host):
        return True
    return any(host == d or host.endswith('.' + d) for d in blocklist)


def homepage_of(url):
    """URL 正規化為該網域首頁"""
    p = urlparse(url)
    if not p.scheme or not p.netloc:
        return None
    return f'{p.scheme}://{p.netloc}/'


def name_keys(firm_name):
    """取事務所/公司主名片段（去型態尾綴、拆多人名）"""
    n = re.sub(r'[（(].*?[)）]', '', firm_name).replace(' ', '').strip()
    is_company = bool(COMPANY_SUFFIX_RE.search(n)) and '事務所' not in n and '法務所' not in n
    if is_company:
        main = COMPANY_SUFFIX_RE.sub('', n)
    else:
        main = FIRM_SUFFIX_RE.sub('', n)
    # 「施登煌.施裕琛.施宜昕」類多人名拆開，任一命中即可
    parts = [p for p in re.split(r'[.．、‧]', main) if len(p) >= 2]
    if not parts and len(main) >= 2:
        parts = [main]
    return {'full': n, 'parts': parts, 'is_company': is_company}


def page_text(html):
    """去 tag、解 entity、去空白，供名稱比對
    （處理「理 律」排版空隔與 &#26126;&#31237; 這種 entity 編碼的中文 title）"""
    return WS_RE.sub('', html_mod.unescape(TAG_RE.sub(' ', html)))


def name_in_text(keys, text):
    if keys['full'] and keys['full'] in text:
        return True
    hit = any(p in text for p in keys['parts'])
    if not hit:
        return False
    if keys['is_company']:
        return True
    # 事務所：主名之外還要求頁面看得到法律業態字，避免通用詞誤中
    return any(k in text for k in ('律師', '事務所', '法律'))


_CURL_META_SEP = b'\n===CURLMETA==='


def _decode_html(raw):
    """依 meta/嘗試順序解碼（台灣老站不少 Big5）"""
    head = raw[:2048].lower()
    if b'big5' in head:
        try:
            return raw.decode('big5', 'replace')
        except Exception:
            pass
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError:
        for enc in ('big5', 'gb18030'):
            try:
                return raw.decode(enc)
            except Exception:
                continue
        return raw.decode('utf-8', 'replace')


def fetch_homepage(homepage, timeout=15):
    """抓首頁 HTML；死站/4xx/5xx 回 None。-k：憑證壞掉的所仍算有官網。
    走系統 curl 而非 requests：requests 的 timeout 管不到 DNS 解析，
    這台機器 getaddrinfo 會整個卡死（2026-08-27 卡住 30 分鐘實測）；
    subprocess timeout 是硬殺，不受影響。"""
    try:
        cmd = ['curl', '-s', '-L', '-k', '-m', str(timeout), '--max-redirs', '5', homepage,
               '-w', _CURL_META_SEP.decode() + '%{url_effective} %{http_code}']
        for k, v in VERIFY_HEADERS.items():
            cmd += ['-H', f'{k}: {v}']
        r = subprocess.run(cmd, capture_output=True, timeout=timeout + 10)
        raw = r.stdout
        idx = raw.rfind(_CURL_META_SEP)
        if idx == -1:
            return None, None
        # utf-8：url_effective 可能是中文 IDN 網域，ascii 會把它毀成 �
        meta = raw[idx + len(_CURL_META_SEP):].decode('utf-8', 'replace').strip()
        body_raw = raw[:idx]
        final_url, _, code = meta.rpartition(' ')
        status = int(code) if code.isdigit() else 0
        if status >= 400 or status == 0 or not body_raw:
            return None, None
        final_home = homepage_of(final_url) or homepage
        return _decode_html(body_raw), final_home
    except Exception:
        return None, None


def verify_firm_website(url, firm_name, blocklist, timeout=15):
    """
    驗證候選官網。回傳 (ok, normalized_homepage, title)
    ok=False 時 homepage 為 None。
    """
    home = homepage_of(url)
    if not home:
        return False, None, None
    host = urlparse(home).netloc.lower()
    if host_blocked(host, blocklist):
        return False, None, None
    html, final_home = fetch_homepage(home, timeout=timeout)
    if html is None:
        return False, None, None
    # redirect 後的最終網域也要過黑名單
    if host_blocked(urlparse(final_home).netloc.lower(), blocklist):
        return False, None, None
    if not name_in_text(name_keys(firm_name), page_text(html)):
        return False, None, None
    m = re.search(r'<title[^>]*>(.*?)</title>', html, re.S | re.I)
    title = WS_RE.sub(' ', html_mod.unescape(m.group(1))).strip()[:200] if m else None
    return True, final_home, title


# ============================================================
# 名冊佐證（2026-11-11）
# ============================================================
# 「首頁有所名」擋不住同名機構：首輪審核 264 間只有所名命中的事務所，118 間其實是
# 同名的會計師／專利商標／地政士事務所、日本與中國的同名律所、出版社、平台。
# 所以官網要成立，除了所名還要有下列任一佐證：
#   lawyer_name  站上（首頁＋團隊／聯絡類子頁）找得到法務部名冊上該所律師姓名
#   contact      站上有名冊登記的地址／電話／信箱，或名冊信箱網域＝官網網域
#   title        首頁 <title> 就是「主名＋法律／律師」且全站沒有日文假名、簡體律所字樣
# 都沒有 → 不算驗證通過，留給人工審（review_status='pending'）。

FIRM_KEY_RE = re.compile(r'^(.+?(?:法律|律師)事務所).*$')   # 與 moj_firm_statistics() 的 firm_key 同規則
LINK_RE = re.compile(r'<a\b[^>]*?href\s*=\s*["\']([^"\'#]+)["\'][^>]*>(.*?)</a>', re.S | re.I)
_INNER_TAG_RE = re.compile(r'<[^>]+>')
SUBPAGE_HINT_RE = re.compile(
    r'團隊|律師|成員|關於|簡介|介紹|顧問|主持|聯絡|聯繫|據點|交通|位置'
    r'|about|team|lawyer|attorney|member|people|profile|staff|contact', re.I)
# 日文假名、簡體律所用字＝日本／中國的同名事務所
FOREIGN_MARK_RE = re.compile(r'[ぁ-ゖァ-ヺ]|律师|事务所|弁護士|司法書士|行政書士')
FREE_MAIL_RE = re.compile(
    r'gmail\.|yahoo\.|hotmail\.|outlook\.|hinet\.net|msn\.|icloud\.|seed\.net|pchome\.|kimo\.|live\.'
    r'|ms\d+\.|so-net|giga\.net|me\.com|qq\.com|163\.com|126\.com|protonmail|aol\.|url\.com\.tw')
_FW_TRANS = str.maketrans('０１２３４５６７８９－臺', '0123456789-台')
_CN_NUM_TRANS = str.maketrans('一二三四五六七八九', '123456789')
_ADDR_RE = re.compile(r'([一-鿿]{1,5}(?:路|街|大道))([1-9一二三四五六七八九]段)?(\d+巷)?(\d+弄)?(\d+)(?:之\d+)?號')
_CURL_SEP2 = b'\n===CURLMETA2==='


def firm_key(office_normalized):
    """名冊 office_normalized → 事務所鍵（去空白），與 firm_websites.firm_name 對得上"""
    o = (office_normalized or '').strip()
    m = FIRM_KEY_RE.match(o)
    return (m.group(1) if m else o).replace(' ', '')


def fetch_page(url, timeout=20):
    """回 (status, html, final_url)；status=0＝DNS／連線／逾時。
    走系統 curl（requests 管不到 DNS 逾時）；-k：憑證過期的站仍算活著。"""
    try:
        cmd = ['curl', '-s', '-L', '-k', '--compressed', '-m', str(timeout), '--max-redirs', '5', url,
               '-w', _CURL_SEP2.decode() + '%{url_effective} %{http_code}']
        for k, v in VERIFY_HEADERS.items():
            cmd += ['-H', f'{k}: {v}']
        r = subprocess.run(cmd, capture_output=True, timeout=timeout + 10)
        raw = r.stdout
        idx = raw.rfind(_CURL_SEP2)
        if idx == -1:
            return 0, None, url
        meta = raw[idx + len(_CURL_SEP2):].decode('utf-8', 'replace').strip()
        final_url, _, code = meta.rpartition(' ')
        status = int(code) if code.isdigit() else 0
        body = raw[:idx]
        return status, (_decode_html(body) if body else None), (final_url or url)
    except Exception:
        return 0, None, url


def subpage_links(html, base_url, limit=6):
    """站內連結中像「團隊／律師介紹／關於／聯絡」的頁，去重後回前 limit 個"""
    from urllib.parse import urljoin
    host = urlparse(base_url).netloc.lower().removeprefix('www.')
    seen, out = set(), []
    for href, inner in LINK_RE.findall(html):
        href = href.strip()
        if href.lower().startswith(('mailto:', 'tel:', 'javascript:', 'line:')):
            continue
        p = urlparse(urljoin(base_url, href))
        if p.scheme not in ('http', 'https') or p.netloc.lower().removeprefix('www.') != host:
            continue
        if re.search(r'\.(jpg|jpeg|png|gif|pdf|zip|docx?|xlsx?|mp4)$', p.path, re.I):
            continue
        key = (p.path.rstrip('/'), p.query)
        if key in seen or key == ('', ''):
            continue
        seen.add(key)
        text = html_mod.unescape(_INNER_TAG_RE.sub('', inner))
        if SUBPAGE_HINT_RE.search(text) or SUBPAGE_HINT_RE.search(p.path):
            out.append(p.geturl())
            if len(out) >= limit:
                break
    return out


def _norm_contact(text):
    """全形數字轉半形、臺→台、數字之間的空白與連字號拿掉（電話／門牌比對用）"""
    return re.sub(r'(?<=\d)[\s\-\(\)（）]+(?=\d)', '', text.translate(_FW_TRANS))


def roster_signals(lawyers, html, host):
    """lawyers：名冊上該所律師 [{name,email,tel,address}]；回命中的訊號集合"""
    sig = set()
    if not lawyers or not html:
        return sig
    low = html.lower()
    text = _norm_contact(page_text(html))
    text_num = text.translate(_CN_NUM_TRANS)
    host = (host or '').lower().removeprefix('www.')
    for l in lawyers:
        name = (l.get('name') or '').strip()
        if len(name) >= 2 and '?' not in name and name in text:   # 名冊罕用字會匯出成 ?
            sig.add('lawyer_name')
        em = (l.get('email') or '').strip().lower()
        if '@' in em:
            dom = em.rsplit('@', 1)[-1]
            if not FREE_MAIL_RE.search(dom) and (dom == host or host.endswith('.' + dom) or dom.endswith('.' + host)):
                sig.add('email_domain')
            elif em in low:
                sig.add('email_on_page')
        tel = re.sub(r'\D', '', (l.get('tel') or '').translate(_FW_TRANS))
        if len(tel) >= 8 and tel[-8:] in text:
            sig.add('tel')
        addr = _norm_contact(re.sub(r'\s', '', l.get('address') or ''))
        for m in _ADDR_RE.finditer(addr):
            road, sec, no = m.group(1)[-4:], (m.group(2) or '').translate(_CN_NUM_TRANS), m.group(5)
            pat = re.escape(road) + r'.{0,3}' + ((re.escape(sec[0]) + r'.{0,2}') if sec else '') \
                + r'.{0,12}?' + no + r'(?:之\d+)?號'
            if re.search(pat, text_num):
                sig.add('addr')
    return sig


def title_names_firm(firm_name, title, all_text):
    """首頁 <title> 就是本所：主名前面不是中文字（排除「北京德和衡」「吳益群」這種包含），
    後面緊接（國際／聯合…）法律或律師；且全站沒有日文假名、簡體律所字樣"""
    if not title or FOREIGN_MARK_RE.search(title) or FOREIGN_MARK_RE.search(all_text or ''):
        return False
    t = WS_RE.sub('', title)
    for part in name_keys(firm_name)['parts']:
        if re.search(r'(?:^|[^一-鿿])' + re.escape(part) + r'(?:國際|聯合|商務|綜合|台灣)*(?:法律|律師)', t):
            return True
    return False


def assess_website(url, firm_name, lawyers, blocklist, max_subpages=6):
    """抓首頁＋必要時的子頁，回一個 dict：
      status       HTTP 狀態（0＝連不上）
      final_home   轉址後的首頁
      blocked_host 轉址落到黑名單／外國網域
      firm_ok      首頁有所名
      title        首頁標題
      signals      名冊訊號集合
      evidence     'lawyer_name' / 'contact' / 'title' / None（由強到弱取第一個）
      hit_url      找到名冊訊號的那一頁"""
    res = {'status': 0, 'final_home': None, 'blocked_host': False, 'firm_ok': False,
           'title': None, 'signals': set(), 'evidence': None, 'hit_url': None}
    home = homepage_of(url)
    if not home:
        return res
    status, html, final_url = fetch_page(home)
    res['status'] = status
    if status == 0 or status >= 400 or not html:
        return res
    final_home = homepage_of(final_url) or home
    res['final_home'] = final_home
    host = urlparse(final_home).netloc.lower()
    if host_blocked(host, blocklist):
        res['blocked_host'] = True
        return res
    text = page_text(html)
    res['firm_ok'] = name_in_text(name_keys(firm_name), text)
    m = re.search(r'<title[^>]*>(.*?)</title>', html, re.S | re.I)
    res['title'] = WS_RE.sub(' ', html_mod.unescape(m.group(1))).strip()[:200] if m else None

    sig = roster_signals(lawyers, html, host)
    hit_url = final_home if sig else None
    all_text = text
    if lawyers and 'lawyer_name' not in sig:
        for link in subpage_links(html, final_url, max_subpages):
            s2, h2, _ = fetch_page(link, timeout=15)
            if s2 == 0 or s2 >= 400 or not h2:
                continue
            all_text += page_text(h2)
            s = roster_signals(lawyers, h2, host)
            if s - sig and not hit_url:
                hit_url = link
            sig |= s
            if 'lawyer_name' in sig:
                hit_url = link
                break
    res['signals'] = sig
    res['hit_url'] = hit_url
    if 'lawyer_name' in sig:
        res['evidence'] = 'lawyer_name'
    elif sig:
        res['evidence'] = 'contact'
    elif res['firm_ok'] and title_names_firm(firm_name, res['title'], all_text):
        res['evidence'] = 'title'
    return res
