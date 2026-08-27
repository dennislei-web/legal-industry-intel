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
