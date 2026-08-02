"""
司法院法官名冊爬蟲（PDF + HTML 雙模式）
來源: 各法院官網的法官名錄
產出: jy_judges 表

兩種模式:
  A) PDF 模式 — 台北地院、高等法院等（表格 PDF）
  B) HTML 模式 — 新北地院等（按庭別分頁 HTML 列表，格式: 職稱_姓名）

WAF 注意（2026-07 起）:
  法院網群掛 F5 TSPD 反機器人。首頁放行，但深層頁 page.goto 直連常被
  net::ERR_CONNECTION_RESET；需先載入首頁等 challenge 過，再從選單
  hover 展開後點擊連結導航（safe_goto 內建 fallback 階梯）。
  curl / requests 直打頁面會拿到 TSPD JS challenge（16KB 假頁）。

用法:
  pip install pdfplumber playwright
  python scrape_jy_judges.py                          # 爬全部法院
  python scrape_jy_judges.py --court 臺灣臺北地方法院  # 指定法院
  python scrape_jy_judges.py --limit 3                # 只爬前 3 個法院（測試）
"""
import re
import os
import time
import argparse
import tempfile
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

try:
    import pdfplumber
except ImportError:
    print("請先安裝 pdfplumber: pip install pdfplumber")
    exit(1)

from utils import get_supabase, log, scrape_start, scrape_end, polite_delay

SCRAPER_NAME = 'jy_judges'

# ============================================================
# 各法院法官名錄頁面 URL
# 格式: 法院名稱 → (子域名, 模式, 頁面列表)
# 模式: 'pdf' = 找 PDF 下載, 'html' = 擷取 HTML 法官列表
# ============================================================
COURT_PAGES = {
    # ===== PDF 模式 =====
    '臺灣高等法院': ('tph', 'pdf', ['/tw/np-1639-051.html']),
    # 2026-07: 臺中分院網域 tchb 已廢（NXDOMAIN），改 tch；名錄在 np-1419-101
    '臺灣高等法院臺中分院': ('tch', 'pdf', ['/tw/np-1419-101.html', '/tw/np-1418-101.html']),
    # 2026-07: 臺南分院改版，名錄移到 np-2330-111（關於法官→法官名錄）
    '臺灣高等法院臺南分院': ('tnh', 'pdf', ['/tw/np-2330-111.html']),
    # 2026-07: 高雄分院名錄改 lp-2525-121（各庭 cp- 子頁）
    '臺灣高等法院高雄分院': ('ksh', 'pdf', ['/tw/lp-2525-121.html']),
    # 2026-07: 花蓮分院名錄在 cp-2680-209722-34a23-131 內容頁
    '臺灣高等法院花蓮分院': ('hlh', 'pdf', ['/tw/cp-2680-209722-34a23-131.html']),
    '臺灣臺北地方法院': ('tpd', 'pdf', ['/tw/lp-2927-151.html']),

    # ===== HTML 模式（各庭別分頁，格式: 職稱_姓名；連結從首頁選單自動發現） =====
    '臺灣新北地方法院': ('pcd', 'html', []),
    '臺灣士林地方法院': ('sld', 'html', []),
    '臺灣桃園地方法院': ('tyd', 'html', []),
    '臺灣新竹地方法院': ('scd', 'html', []),
    '臺灣苗栗地方法院': ('mld', 'html', []),
    '臺灣臺中地方法院': ('tcd', 'html', []),
    '臺灣彰化地方法院': ('chd', 'html', []),
    '臺灣臺南地方法院': ('tnd', 'html', []),
    '臺灣高雄地方法院': ('ksd', 'html', []),
    '臺灣屏東地方法院': ('ptd', 'html', []),
    '臺灣花蓮地方法院': ('hld', 'html', []),
    '臺灣宜蘭地方法院': ('ild', 'html', []),
    '臺灣基隆地方法院': ('kld', 'html', []),
}

RANK_PATTERN = r'(院長|庭長|法官兼庭長|法官兼審判長|審判長|候補法官|試署法官|法官)'

# 姓名偵測黑名單：cell 含任一詞就不當姓名（職稱/職務/欄位/案件類別詞）。
# 用「詞」而非單字比對，避免擋掉正常名字用字（如「明」「志」）。
NAME_BLACKLIST = [
    '庭別', '股別', '姓名', '職稱', '職務', '現辦', '承辦', '案件', '類別', '其他',
    '學歷', '曾任', '備註', '調辦', '兼辦', '事務', '專業', '事件', '審判長', '庭長',
    '院長', '法官', '候補', '試署', '充任', '主任', '秘書', '促轉', '醫療', '勞動',
    '民事', '刑事', '家事', '少年', '選舉', '原住民', '金融', '海商', '國安', '軍事',
    '性侵', '一般', '智慧', '財產', '公職', '交通', '毒品', '公司', '保險', '證券',
    # mig 122 清洗後補（結構詞，真名不含這些子字串）
    '代理', '次序', '戳記', '親送', '路線', '證書', '演講', '交接',
]

# 完整比對黑名單：這些詞是雜訊，但可能是真名的子字串（如「許可欣」含「許可」），
# 只在整格＝該詞時排除（mig 122 清洗來源）
NAME_EXACT_BAD = {
    '許可', '潮州', '核定', '登錄', '編號', '組別', '順序', '號數', '法院',
    '依下列', '依前點', '參與審', '平常日', '楠梓站', '專題演', '銘洋訪',
    '卸新任', '無戳記', '臺北地院', '最高法院',
}
RANK_WORDS = ['院長', '法官兼庭長', '法官兼審判長', '庭長', '審判長', '充任審判長',
              '候補法官', '試署法官', '法官']

import re as _re
_WS = _re.compile(r'[\s　\xa0]')
_CJK_NAME = _re.compile(r'^[一-鿿]{2,4}$')

# 整張表跳過的關鍵詞：職務「代理次序」表的內容是股別代字（仁/公/安/瑾…），
# 逐格看全像 2-4 字姓名，黑名單擋不住（新竹曾整批寫入「仁公安瑾」等假名）
TABLE_SKIP_WORDS = ('代理次序', '代理順序', '職務代理')


def _skip_table(rows):
    """表內任一格含代理次序類關鍵詞 → 整張表不是名冊，跳過"""
    joined = ''.join(''.join(str(c) for c in r if c) for r in rows)
    return any(w in joined for w in TABLE_SKIP_WORDS)


def _clean_name(cell):
    """去掉所有空白後回傳；非 2-4 中文字或命中黑名單則回 None"""
    if not cell:
        return None
    s = _WS.sub('', cell)
    if not _CJK_NAME.match(s):
        return None
    # 庭別/單位/場站詞（以庭、處、室、股、科、站結尾）不是姓名
    if s[-1] in '庭處室股科組站':
        return None
    # 股別＋序數（碩二/軒三）不是姓名
    if len(s) == 2 and s[1] in '一二三四五六七八九十':
        return None
    if s in NAME_EXACT_BAD:
        return None
    if any(bad in cell or bad in s for bad in NAME_BLACKLIST):
        return None
    return s


def _row_rank(cells):
    """從整列 cell 找職稱（取最完整匹配），預設『法官』"""
    joined = ' '.join(cells)
    for w in RANK_WORDS:  # RANK_WORDS 已由完整→簡單排序
        if w in joined:
            return w
    return '法官'


def parse_roster_rows(rows, court_name, default_division=None):
    """通用名錄列解析：不假設固定欄位順序，逐列偵測姓名（黑名單排除職務/類別）。
    同時吃三種版型：高院『庭別/職稱/姓名』、tch『姓名在首欄』、ksh『庭別/股別/姓名/類別』。
    rows: List[List[str]]（PDF extract_tables 或 HTML table tr 的 cells）
    """
    judges = []
    current_division = default_division

    for row in rows:
        if not row:
            continue
        cells = [(_WS.sub(' ', c).strip() if c else '') for c in row]
        joined = ''.join(cells)
        if not joined:
            continue
        # 表頭列
        if ('姓名' in joined and ('職稱' in joined or '庭別' in joined or '股別' in joined
                                  or '現辦' in joined or '承辦' in joined)):
            continue

        # 更新庭別（cell 以『庭』『處』『股』結尾且短）
        for c in cells:
            cc = _WS.sub('', c)
            if 2 <= len(cc) <= 5 and (cc.endswith('庭') or cc.endswith('處')) \
                    and not any(b in cc for b in ['名', '別']):
                current_division = cc
                break

        # 找姓名（取第一個通過的 cell）
        name = None
        for c in cells:
            nm = _clean_name(c)
            if nm:
                name = nm
                break
        if not name:
            continue

        judges.append({
            'name': name,
            'court_name': normalize_court(court_name),
            'division': current_division,
            'rank': _row_rank(cells),
            'status': '現任',
            'raw_data': {'row': [c for c in cells if c][:6]},
            'scraped_at': datetime.now(timezone.utc).isoformat(),
        })

    return judges


def normalize_court(name):
    """法院名稱正規化"""
    if not name:
        return name
    return name.replace('台灣', '臺灣').replace('　', '').strip()


# ============================================================
# WAF 繞行導航
# ============================================================

def wait_page_ready(page, timeout_s=25):
    """等 TSPD challenge 跑完（challenge 假頁沒有正常連結）"""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            n = page.evaluate("document.querySelectorAll('a[href]').length")
            has_tspd = page.evaluate(
                "!!document.querySelector('script') && document.documentElement.innerHTML.includes('bobcmn')")
            if n and n > 10 and not has_tspd:
                return True
        except Exception:
            pass  # challenge 重載中 execution context 會被毀掉，重試即可
        try:
            page.wait_for_timeout(1200)
        except Exception:
            time.sleep(1.2)
    return False


def dump_page_hint(page, label=''):
    """診斷用：dump 目前頁面的關鍵資訊（CI log 當探針看站方結構）"""
    try:
        info = page.evaluate('''() => {
            const as = Array.from(document.querySelectorAll('a[href]')).slice(0, 400);
            const dl = as.filter(a => (a.getAttribute('href')||'').includes('dl-'))
                        .map(a => ({h: a.href.slice(-70), t: a.textContent.trim().slice(0, 30)}));
            const roster = as.filter(a => a.textContent.includes('法官'))
                        .map(a => ({h: a.href.slice(-70), t: a.textContent.trim().slice(0, 30)}));
            return {url: location.href.slice(-80), title: document.title.slice(0, 40),
                    nA: document.querySelectorAll('a[href]').length,
                    dl: dl.slice(0, 10), roster: roster.slice(0, 15)};
        }''')
        log(f'  [診斷{label}] url=...{info["url"]} title={info["title"]} anchors={info["nA"]}')
        for d in info['dl']:
            log(f'    dl連結: {d["t"]} → ...{d["h"]}')
        for r in info['roster']:
            log(f'    法官連結: {r["t"]} → ...{r["h"]}')
    except Exception as e:
        log(f'  [診斷{label}] dump 失敗: {e}')


def _js_nav(page, href):
    """在頁內用 location.assign 導航（帶 referer 與 TSPD cookie，最不易被 WAF reset）。
    不觸碰 DOM 元素，避開 headful chromium 點擊選單時整個 renderer crash 的雷。
    """
    try:
        if page.is_closed():
            return False
    except Exception:
        return False
    try:
        with page.expect_navigation(wait_until='domcontentloaded', timeout=25000):
            page.evaluate('h => location.assign(h)', href)
        return True
    except Exception:
        return False


def _on_site(page, base_url):
    try:
        return (not page.is_closed()) and page.url.startswith(base_url)
    except Exception:
        return False


def goto_home_with_retry(page, base_url, waits=(0, 45, 90, 150)):
    """載入首頁並過 challenge；被 WAF 暫時封鎖（CONNECTION_REFUSED/RESET）時長退避重試。
    連續存取多院後司法院 WAF 會短時封整個來源 IP，退避等封鎖窗口過去即可恢復。
    """
    for i, w in enumerate(waits):
        if w:
            log(f'  首頁被拒，退避 {w}s 後重試（{i}/{len(waits) - 1}）')
            time.sleep(w)
        try:
            page.goto(base_url, wait_until='domcontentloaded', timeout=30000)
            if wait_page_ready(page):
                return True
        except Exception:
            continue
    return False


def safe_goto(page, url, base_url):
    """深層頁導航：直連帶 referer 為主；被 WAF reset 就先回首頁（過 challenge）
    再用 location.assign 頁內導航。站方對「短時間多次直連」會 reset，故重試前先歇。
    """
    # 嘗試 1: 直連（帶站內 referer）
    try:
        page.goto(url, wait_until='domcontentloaded', timeout=25000, referer=base_url + '/tw/')
        if wait_page_ready(page, timeout_s=15):
            return True
    except Exception:
        pass

    # 嘗試 2: 回首頁（被 WAF 封鎖時短退避重試）過 challenge → 頁內 location.assign
    try:
        if page.is_closed():
            return False
        if not goto_home_with_retry(page, base_url, waits=(2.5, 20, 45)):
            return False
        if _js_nav(page, url):
            return wait_page_ready(page, timeout_s=15)
        return False
    except Exception:
        return False


def click_goto(page, href, base_url):
    """站內頁導航：優先從當前熱頁用 location.assign 頁內跳（cookie 熱、最像真人），
    失敗才 safe_goto（直連＋首頁 fallback）。不用 DOM 點擊（headful 會 crash renderer）。
    """
    if _on_site(page, base_url) and _js_nav(page, href):
        if wait_page_ready(page, timeout_s=15):
            return True
    return safe_goto(page, href, base_url)


# ============================================================
# PDF 模式
# ============================================================

def find_pdf_on_page(page, base_url):
    """只在「當前頁」找同域名 PDF 下載連結（無導航副作用）。優先文字含『法官名錄』者。"""
    subdomain = base_url.replace('https://', '').split('.')[0]
    links = page.evaluate('''() => {
        const results = [];
        document.querySelectorAll('a').forEach(a => {
            const href = a.getAttribute('href') || '';
            const text = a.textContent.trim().toLowerCase();
            if (href.includes('dl-') || href.includes('.pdf') || text.includes('pdf')) {
                results.push({ href: a.href, text: a.textContent.trim() });
            }
        });
        document.querySelectorAll('iframe').forEach(f => {
            if (f.src && f.src.includes('dl-')) results.push({ href: f.src, text: 'iframe-pdf' });
        });
        return results;
    }''')
    candidates = [l for l in links if 'dl-' in l['href'] and subdomain in l['href']]
    for link in candidates:
        if '法官' in link['text'] and '名錄' in link['text']:
            return link['href']
    return candidates[0]['href'] if candidates else None


def find_pdf_url(page, base_url):
    """在法院法官名錄頁面找 PDF 下載連結（當前頁→子頁）"""
    subdomain = base_url.replace('https://', '').split('.')[0]  # e.g. 'tpd'

    # 策略 1: 直接在頁面找 PDF 連結
    links = page.evaluate('''() => {
        const results = [];
        document.querySelectorAll('a').forEach(a => {
            const href = a.getAttribute('href') || '';
            const text = a.textContent.trim().toLowerCase();
            if (href.includes('dl-') || href.includes('.pdf') || text.includes('pdf')) {
                results.push({ href: a.href, text: a.textContent.trim() });
            }
        });
        // 也找 iframe（有些法院直接嵌入 PDF）
        document.querySelectorAll('iframe').forEach(f => {
            if (f.src && f.src.includes('dl-')) {
                results.push({ href: f.src, text: 'iframe-pdf' });
            }
        });
        return results;
    }''')

    # 只認同一法院子域名的連結——www.judicial.gov.tw 的 dl- 常是不相干文件
    # （實測 tnh 頁面曾抓到「律師酬金核定」PDF 當名錄，解析 0 人）
    # 優先挑連結文字含「法官名錄」者
    candidates = [l for l in links if 'dl-' in l['href'] and subdomain in l['href']]
    for link in candidates:
        if '法官' in link['text'] and '名錄' in link['text']:
            return link['href']
    if candidates:
        return candidates[0]['href']

    # 策略 2: 找頁面上的子連結（有些法院名錄放在 cp- 子頁面）
    sub_links = page.evaluate('''() => {
        const results = [];
        const seen = new Set();
        document.querySelectorAll('a').forEach(a => {
            const text = a.textContent.trim();
            const href = a.getAttribute('href') || '';
            if (seen.has(a.href)) return;
            seen.add(a.href);
            if ((text.includes('法官') && text.includes('名錄') && !text.includes('國民')) ||
                (href.includes('cp-') && !href.includes('javascript') && text.includes('法官'))) {
                results.push({ href: a.href, text });
            }
        });
        return results;
    }''')

    for link in sub_links[:6]:
        try:
            if subdomain not in link['href']:
                continue
            log(f'    搜尋子頁面: {link["text"][:30]} → ...{link["href"][-50:]}')
            if not click_goto(page, link['href'], base_url):
                continue
            inner_links = page.evaluate('''() => {
                const results = [];
                document.querySelectorAll('a, iframe').forEach(el => {
                    const href = el.getAttribute('href') || el.getAttribute('src') || '';
                    const fullHref = el.href || href;
                    if (href.includes('dl-')) {
                        const text = el.textContent ? el.textContent.trim().toLowerCase() : '';
                        results.push({ href: fullHref, text });
                    }
                });
                return results;
            }''')
            for il in inner_links:
                if subdomain in il['href']:
                    return il['href']
        except Exception:
            continue

    return None


def download_pdf(page, pdf_url, court_name):
    """下載 PDF。先用瀏覽器 context 下載（帶 TSPD cookie），失敗再用 requests。"""
    tmp_path = os.path.join(tempfile.gettempdir(), f'judge_{court_name}.pdf')

    # 嘗試 1: 瀏覽器 context（帶 cookie / UA，最不會被 WAF 擋）
    try:
        resp = page.context.request.get(pdf_url, timeout=40000)
        body = resp.body()
        if resp.status == 200 and body[:4] == b'%PDF':
            with open(tmp_path, 'wb') as f:
                f.write(body)
            log(f'  PDF 下載成功(browser): {len(body):,} bytes')
            return tmp_path
        log(f'  browser 下載非 PDF: HTTP {resp.status}, head={body[:20]!r}')
    except Exception as e:
        log(f'  browser 下載錯誤: {e}')

    # 嘗試 2: requests 直接下載
    import requests
    import warnings
    warnings.filterwarnings('ignore', message='Unverified HTTPS')
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0'}
        resp = requests.get(pdf_url, headers=headers, timeout=30, verify=False)
        if resp.status_code == 200 and resp.content[:4] == b'%PDF':
            with open(tmp_path, 'wb') as f:
                f.write(resp.content)
            log(f'  PDF 下載成功(requests): {len(resp.content):,} bytes')
            return tmp_path
        log(f'  PDF 下載失敗: HTTP {resp.status_code}, content-type={resp.headers.get("content-type")}')
    except Exception as e:
        log(f'  PDF 下載錯誤: {e}')
    return None


def parse_judge_pdf(pdf_path, court_name):
    """用 pdfplumber 解析法官名錄 PDF（表格列丟給通用 parse_roster_rows）"""
    all_rows = []
    try:
        with pdfplumber.open(pdf_path) as pdf:
            log(f'  PDF 共 {len(pdf.pages)} 頁')
            for page in pdf.pages:
                for table in page.extract_tables():
                    if _skip_table(table):
                        continue
                    for row in table:
                        if row and not all(c is None or str(c).strip() == '' for c in row):
                            all_rows.append([str(c) if c is not None else '' for c in row])
    except Exception as e:
        log(f'  PDF 解析錯誤: {e}')

    return dedup_judges(parse_roster_rows(all_rows, court_name))


def dedup_judges(judges):
    """去重（同一法院同一法官可能出現多次）"""
    seen = set()
    unique = []
    for j in judges:
        key = f"{j['name']}_{j['court_name']}"
        if key not in seen:
            seen.add(key)
            unique.append(j)
    return unique


# ============================================================
# HTML 模式
# ============================================================

def collect_roster_links(page):
    """收集目前頁面上所有「○○法官名錄」連結（排除國民法官）"""
    return page.evaluate('''() => {
        const links = [];
        const seen = new Set();
        document.querySelectorAll('a[href]').forEach(a => {
            const text = a.textContent.trim();
            const href = a.href;
            // 名錄頁的連結文字各院不一：法官名錄 / 調辦事法官 / ○○法官事務分配表
            // （事務分配表頁內含股別+法官姓名表格；排除要點/規則/設置情形等無名單頁）
            const isRoster = text.includes('法官名錄') || text.includes('調辦事') ||
                (text.includes('事務分配表') && !text.includes('要點') &&
                 !text.includes('規則') && !text.includes('情形'));
            if (isRoster && !text.includes('國民') &&
                !href.includes('javascript') && !seen.has(href)) {
                seen.add(href);
                links.push({ href, text: text.substring(0, 30) });
            }
        });
        return links;
    }''')


def collect_division_links(page):
    """收集「以庭/處結尾」的庭別連結（如彰化名錄頁內的『少年及家事庭』『民事執行處』）。
    只在展開名錄內層時當退路用（首頁層走 collect_roster_links），避免誤收導覽選單。
    """
    return page.evaluate('''() => {
        const links = [];
        const seen = new Set();
        const bad = ['分案', '規則', '要點', '設置', '情形', '專業法庭', '國民', '要覽',
                     '名錄', '憲法', '最高', '行政法院', '懲戒', '智慧'];
        document.querySelectorAll('a[href]').forEach(a => {
            const text = a.textContent.trim();
            const href = a.href;
            if (!text || text.length > 20 || seen.has(href)) return;
            if (href.includes('javascript')) return;
            // 僅同院（same-origin），排除憲法法庭等外站連結
            try { if (new URL(href).origin !== location.origin) return; } catch (e) { return; }
            if (!/[庭處]$/.test(text.replace(/[（(].*$/, ''))) return;
            if (bad.some(b => text.includes(b))) return;
            seen.add(href);
            links.push({ href, text: text.substring(0, 30) });
        });
        return links;
    }''')


def extract_judges_on_page(page, court_name, division):
    """擷取目前頁面上的法官（先認「職稱_姓名」連結格式，再退表格格式）"""
    # 格式 1: 連結文字 職稱_姓名（如 法官_吳昱農；新北等地院）
    page_judges = page.evaluate('''(rankPat) => {
        const judges = [];
        const re = new RegExp('^' + rankPat + '[_＿](.+)$');
        document.querySelectorAll('a').forEach(a => {
            const text = a.textContent.trim();
            const m = text.match(re);
            if (m) judges.push({ rank: m[1], name: m[2].trim() });
        });
        return judges;
    }''', RANK_PATTERN)

    results = []
    for j in page_judges:
        results.append({
            'name': j['name'],
            'court_name': normalize_court(court_name),
            'division': division,
            'rank': j['rank'],
            'status': '現任',
            'raw_data': {'source': 'html', 'division_page': division},
            'scraped_at': datetime.now(timezone.utc).isoformat(),
        })

    # 格式 2: HTML 表格（庭別/股別/姓名/類別 等，無固定職稱欄）→ 通用列解析
    # 按表分組回傳：職務代理次序表要整張跳過（內容是股別代字，逐列看全像姓名）
    if not results:
        tables = page.evaluate('''() => {
            const out = [];
            document.querySelectorAll('table').forEach(tb => {
                const rows = [];
                tb.querySelectorAll('tr').forEach(tr => {
                    if (tr.closest('table') !== tb) return;  // 巢狀表的列歸內層表
                    const cells = Array.from(tr.querySelectorAll('td,th'))
                        .filter(c => c.closest('table') === tb)
                        .map(c => c.textContent);
                    if (cells.length >= 2) rows.push(cells);
                });
                if (rows.length) out.push(rows);
            });
            return out;
        }''')
        rows = []
        for tb in tables:
            if _skip_table(tb):
                continue
            rows.extend(tb)
        results = parse_roster_rows(rows, court_name, default_division=division)

    return results


def scrape_html_judges(page, court_name, subdomain):
    """
    HTML 模式：擷取法官名錄（適用於新北等地院）
    首頁選單找「○○法官名錄」連結後，逐頁「點擊導航」擷取。
    （直接 page.goto 深層頁會被 TSPD WAF reset，必須走站內點擊）
    """
    base_url = f'https://{subdomain}.judicial.gov.tw'
    judges = []

    try:
        if not goto_home_with_retry(page, base_url):
            log(f'  首頁 challenge 未過（含退避重試），跳過')
            return []

        roster_links = collect_roster_links(page)

        if not roster_links:
            log(f'  首頁找不到法官名錄連結，嘗試「關於法官」頁面...')
            about = page.evaluate('''() => {
                const a = Array.from(document.querySelectorAll('a')).find(
                    a => a.textContent.trim().includes('關於法官') ||
                         a.textContent.trim().includes('法官名錄'));
                return a ? a.href : null;
            }''')
            if about and click_goto(page, about, base_url):
                roster_links = collect_roster_links(page)

        if not roster_links:
            log(f'  仍找不到法官名錄連結')
            dump_page_hint(page, ':無名錄連結')
            return []

        log(f'  找到 {len(roster_links)} 個法官名錄頁面')

        visited = set()

        def harvest(rl, depth):
            """導航到名錄頁擷取；抓不到時展開該頁子名錄連結（depth 層，處理專區/入口型如台中地院）"""
            href = rl['href']
            if href in visited:
                return
            visited.add(href)
            division = re.sub(r'^\d+', '', rl['text']
                              .replace('法官名錄', '').replace('法官事務分配表', '')
                              .replace('事務分配表', '')).strip() or '未分類'
            try:
                if not click_goto(page, href, base_url):
                    log(f'    {division}: 導航失敗，跳過')
                    return
                page_judges = extract_judges_on_page(page, court_name, division)
                if page_judges:
                    log(f'    {division}: {len(page_judges)} 位法官')
                    judges.extend(page_judges)
                    polite_delay(1.5)
                    return
                # 抓不到 → 可能是「專區/入口」頁，展開子名錄連結再往下抓
                if depth > 0:
                    subs = [s for s in collect_roster_links(page) if s['href'] not in visited]
                    # 內層退路：名錄頁下各庭連結是純庭名（如彰化『少年及家事庭』）
                    if not subs:
                        subs = [s for s in collect_division_links(page) if s['href'] not in visited]
                    if subs:
                        log(f'    {division}: 入口頁，展開 {len(subs)} 子名錄')
                        for s in subs:
                            harvest(s, depth - 1)
                        return
                # 該頁可能是 PDF 下載型名錄（如臺中地院）
                pdf_url = find_pdf_on_page(page, base_url)
                if pdf_url:
                    log(f'    {division}: PDF 名錄 {pdf_url[-40:]}')
                    pp = download_pdf(page, pdf_url, court_name)
                    if pp:
                        got = parse_judge_pdf(pp, court_name)
                        try:
                            os.remove(pp)
                        except Exception:
                            pass
                        if got:
                            log(f'    {division}: {len(got)} 位法官（PDF）')
                            judges.extend(got)
                            polite_delay(1.5)
                            return
                log(f'    {division}: 0 位')
                dump_page_hint(page, f':{division}')
                polite_delay(1.5)
            except Exception as e:
                log(f'    {division} 擷取失敗: {e}')

        for rl in roster_links:
            harvest(rl, depth=3)

    except Exception as e:
        log(f'  HTML 擷取錯誤: {e}')

    return dedup_judges(judges)


# ============================================================
# 主流程
# ============================================================

def scrape_pdf_court(page, court_name, subdomain, paths):
    """PDF 模式單一法院：找 PDF → 下載解析；找不到 PDF 退回 HTML 擷取"""
    base_url = f'https://{subdomain}.judicial.gov.tw'
    pdf_url = None
    landed = False
    landing_url = None

    for path in paths:
        url = base_url + path
        log(f'  載入: {url}')
        if not safe_goto(page, url, base_url):
            log(f'  載入失敗，跳過此頁面')
            continue
        landed = True
        landing_url = url
        pdf_url = find_pdf_url(page, base_url)  # 可能導航到子頁探 PDF
        if pdf_url:
            break

    if pdf_url:
        log(f'  PDF URL: {pdf_url}')
        pdf_path = download_pdf(page, pdf_url, court_name)
        if pdf_path:
            judges = parse_judge_pdf(pdf_path, court_name)
            try:
                os.remove(pdf_path)
            except Exception:
                pass
            if judges:
                return judges
            log(f'  PDF 解析 0 人，退回 HTML 擷取')

    if not landed:
        return []

    # 退路: 頁面本身（或其名錄子頁）是 HTML 名錄
    log(f'  找不到可用 PDF，嘗試 HTML 擷取')
    # find_pdf_url 可能已把 page 導航到子頁，先回 landing 頁才拿得到完整名錄選單
    if landing_url:
        safe_goto(page, landing_url, base_url)
    all_judges = extract_judges_on_page(page, court_name, None)
    if all_judges:
        log(f'    當前頁: {len(all_judges)} 位')

    # 名錄子頁（如 ksh lp 頁下的各庭 cp- 頁）——逐頁累加，勿因當前頁有料就早退
    roster = collect_roster_links(page)
    for rl in roster[:15]:
        # 跳過指向名錄列表頁本身（無庭別前綴的「法官名錄」）
        division = re.sub(r'^\d+', '', rl['text'].replace('法官名錄', '')).strip() or None
        if not click_goto(page, rl['href'], base_url):
            continue
        got = extract_judges_on_page(page, court_name, division)
        if got:
            log(f'    {division or "?"}: {len(got)} 位（HTML 退路）')
            all_judges.extend(got)
        polite_delay(1.5)

    if not all_judges:
        dump_page_hint(page, ':PDF退路無料')
    return dedup_judges(all_judges)


def resolve_court_ids(sb, judges):
    """查詢 courts 表取得 court_id"""
    court_names = list(set(j['court_name'] for j in judges if j.get('court_name')))
    if not court_names:
        return {}
    mapping = {}
    for i in range(0, len(court_names), 50):
        batch = court_names[i:i+50]
        result = sb.table('courts').select('id, name').in_('name', batch).execute()
        for row in result.data:
            mapping[row['name']] = row['id']
    return mapping


def main():
    parser = argparse.ArgumentParser(description='司法院法官名冊爬蟲（PDF+HTML 雙模式）')
    parser.add_argument('--limit', type=int, default=None, help='限制爬取法院數量（測試用）')
    parser.add_argument('--court', type=str, default=None, help='指定法院名稱')
    args = parser.parse_args()

    sb = get_supabase()
    log_id = scrape_start(sb, SCRAPER_NAME)

    playwright_inst = None
    browser = None
    all_judges = []
    failed_courts = []

    try:
        log('=== 司法院法官名冊爬蟲啟動（PDF+HTML 雙模式）===')

        playwright_inst = sync_playwright().start()
        # 用真實瀏覽器（非 headless）避免司法院網站擋 bot
        browser = playwright_inst.chromium.launch(headless=False, slow_mo=300)
        context = browser.new_context(
            user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
            locale='zh-TW',
        )
        page = context.new_page()

        # 篩選法院
        courts_to_scrape = dict(COURT_PAGES)
        if args.court:
            target = normalize_court(args.court)
            courts_to_scrape = {k: v for k, v in courts_to_scrape.items() if target in k}
            if not courts_to_scrape:
                log(f'找不到法院: {args.court}')
                log(f'可用法院: {", ".join(COURT_PAGES.keys())}')
                return

        if args.limit:
            courts_to_scrape = dict(list(courts_to_scrape.items())[:args.limit])

        # 高密度的 HTML 地院（每院 10+ 次導航）排前面，趁來源 IP 未被 WAF 累積封鎖先跑；
        # 低密度 PDF 院（1 頁+1 PDF）放後面，較耐封鎖。
        ordered = sorted(courts_to_scrape.items(),
                         key=lambda kv: 0 if kv[1][1] == 'html' else 1)

        log(f'將爬取 {len(ordered)} 個法院（HTML 地院優先）')

        def scrape_one(court_name, subdomain, mode, paths):
            if mode == 'html':
                return scrape_html_judges(page, court_name, subdomain)
            return scrape_pdf_court(page, court_name, subdomain, paths)

        for court_name, (subdomain, mode, paths) in ordered:
            log(f'\n--- {court_name} ({mode} 模式) ---')
            try:
                judges = scrape_one(court_name, subdomain, mode, paths)
                log(f'  解析出 {len(judges)} 位法官')
                if judges:
                    all_judges.extend(judges)
                else:
                    failed_courts.append(court_name)
                polite_delay(15)  # 院間冷卻，降低 WAF 累積封鎖

            except PlaywrightTimeout:
                log(f'  ⚠ 超時，跳過')
                failed_courts.append(court_name)
            except Exception as e:
                log(f'  ⚠ 錯誤: {e}')
                failed_courts.append(court_name)
                continue

        # 第二輪：對失敗法院冷卻後重試一次（封鎖窗口通常數分鐘會恢復）
        if failed_courts:
            retry_list = list(failed_courts)
            log(f'\n=== 冷卻 90s 後重試 {len(retry_list)} 個失敗法院 ===')
            time.sleep(90)
            for court_name in retry_list:
                subdomain, mode, paths = COURT_PAGES[court_name]
                log(f'\n--- [重試] {court_name} ({mode} 模式) ---')
                try:
                    judges = scrape_one(court_name, subdomain, mode, paths)
                    log(f'  解析出 {len(judges)} 位法官')
                    if judges:
                        all_judges.extend(judges)
                        failed_courts.remove(court_name)
                    polite_delay(15)
                except Exception as e:
                    log(f'  ⚠ 重試仍失敗: {e}')
                    continue

        # 儲存到 DB
        log(f'\n=== 共 {len(all_judges)} 位法官，開始儲存 ===')
        if failed_courts:
            log(f'⚠ 失敗法院 ({len(failed_courts)}): {"、".join(failed_courts)}')

        if all_judges:
            # 解析 court_id
            court_map = resolve_court_ids(sb, all_judges)
            for j in all_judges:
                j['court_id'] = court_map.get(j['court_name'])

            # 批次 upsert
            inserted = 0
            batch_size = 200
            for i in range(0, len(all_judges), batch_size):
                batch = all_judges[i:i+batch_size]
                result = sb.table('jy_judges').upsert(
                    batch, on_conflict='name,court_name'
                ).execute()
                inserted += len(result.data) if result.data else 0
                polite_delay(0.5)

            log(f'儲存完成: {inserted} 筆')
        else:
            inserted = 0

        err_note = None
        if failed_courts:
            err_note = f'部分法院失敗({len(failed_courts)}): {"、".join(failed_courts)}'[:500]
        scrape_end(sb, log_id,
                   status='success' if all_judges else 'error',
                   records_found=len(all_judges),
                   records_inserted=inserted,
                   error_message=err_note)

        log('=== 爬蟲完成 ===')

    except Exception as e:
        log(f'錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise

    finally:
        if browser:
            browser.close()
        if playwright_inst:
            playwright_inst.stop()


if __name__ == '__main__':
    main()
