"""
MOJ 新站律師詳細頁 /lawyer/{資料雜湊值}：抓取＋解析（moj_detail_sweep.py、moj_harvest_ingest.py 共用）

頁面是公開資源（免驗證碼、免 cookie；2026-10-30 實測）。全頁約 1.4 MB，絕大部分是內嵌的
大頭照 base64（offset ≈ 19.9 KB 起），所有欄位都在前 20 KB → 串流讀到 32 KB 或遇到 `data:image`
就關連線，大頭照不下載、不存。Range 不支援。假雜湊回 404、0 byte。

DOM（2026-10-30 抓頁確認）：每個欄位是一對 el-col：
  <div class="el-col …"><div><span>標籤</span></div></div>
  <div class="el-col …"> …值（可能多層 span／div）… </div>
值一律以 HTML entity 編碼（&#x6B63;&#x5E38;），由 BeautifulSoup 解碼。

個資：頁面有 email／電話／地址。解析會回傳（moj_lawyers 本來就有這三欄），但任何診斷輸出都不印。
"""
import re
import time

import requests
from bs4 import BeautifulSoup

BASE = 'https://lawyerbc.moj.gov.tw'
USER_AGENT = 'LegalIndustryIntel/1.0'
READ_LIMIT = 32 * 1024
HASH_RE = re.compile(r'^0x[0-9a-fA-F]{64}$')

LABELS = {
    '律師執業狀態': 'state_desc',
    '姓名': 'name',
    '英文姓名': 'english_name',
    '性別': 'sex',
    '出生年份': 'birth',
    '證書字號': 'lic_no',
    '所屬公會': 'guild',
    '事務所名稱': 'office',
    '電子郵件': 'email',
    '電話': 'tel',
    '地址': 'address',
    '懲戒記錄': 'discipline',
    '備註': 'remark',
    '發布日期': 'mk_date',
    '更新日期': 'ut_date',
}
PRIVATE_FIELDS = ('email', 'tel', 'address')
NONE_TEXT = {'', '無', '-', '－'}


def new_session():
    s = requests.Session()
    s.headers.update({'User-Agent': USER_AGENT, 'Accept': 'text/html'})
    return s


def _read_head(resp):
    """串流讀到 READ_LIMIT 或看到大頭照開頭就停"""
    buf = bytearray()
    for chunk in resp.iter_content(4096):
        if not chunk:
            continue
        buf.extend(chunk)
        if len(buf) >= READ_LIMIT or b'data:image' in buf[-(len(chunk) + 16):]:
            break
    return bytes(buf)


def fetch_detail(page_hash, session=None, timeout=(10, 30)):
    """回傳 (status, fields, note)：
      'ok'      → fields 為解析結果 dict
      'missing' → HTTP 404 且 0 byte（官網對不存在雜湊的回應）
      'flaky'   → 連線錯誤／逾時／5xx／非預期回應／解析不到證號（無法斷定，呼叫端不可當異動）
    """
    if not HASH_RE.match(page_hash or ''):
        return 'flaky', None, '雜湊格式不符'
    sess = session or new_session()
    url = f'{BASE}/lawyer/{page_hash}'
    try:
        with sess.get(url, stream=True, timeout=timeout, allow_redirects=False) as r:
            if r.status_code == 404:
                peek = r.raw.read(512, decode_content=True) or b''
                # 0 byte＝官網「查無此雜湊」；有內容（IIS 錯誤頁等）＝路由本身變了，不能當查無
                return ('missing', None, '') if not peek.strip() else ('flaky', None, 'HTTP 404 附錯誤頁')
            if r.status_code != 200:
                return 'flaky', None, f'HTTP {r.status_code}'
            if 'html' not in (r.headers.get('Content-Type') or '').lower():
                return 'flaky', None, '非 HTML 回應'
            head = _read_head(r)
    except (requests.exceptions.Timeout, requests.exceptions.ConnectionError,
            requests.exceptions.ChunkedEncodingError) as e:
        return 'flaky', None, type(e).__name__
    except requests.exceptions.RequestException as e:
        return 'flaky', None, type(e).__name__
    text = head.decode('utf-8', errors='ignore')
    fields = parse_detail(text)
    if not fields.get('lic_no'):
        # 診斷：只印大小與 <title>（錯誤頁／攔截頁的標題不含個資），不印內容
        m = re.search(r'<title>(.*?)</title>', text, re.S | re.I)
        title = re.sub(r'\s+', ' ', BeautifulSoup(m.group(1), 'html.parser').get_text()).strip()[:60] if m else '-'
        return 'flaky', None, f'解析不到證書字號（{len(head)} bytes，title={title}）'
    return 'ok', fields, ''


def parse_detail(html):
    """詳細頁 HTML（前段即可）→ 欄位 dict（值為字串；缺的欄位不放）"""
    cut = html.find('data:image')
    if cut > 0:
        html = html[:cut]
    soup = BeautifulSoup(html, 'html.parser')
    out = {}
    for span in soup.find_all('span'):
        label = span.get_text(strip=True)
        key = LABELS.get(label)
        if not key or key in out:
            continue
        label_col = _enclosing_col(span)
        if label_col is None:
            continue
        val_col = label_col.find_next_sibling('div')
        if val_col is None or 'el-col' not in (val_col.get('class') or []):
            continue
        parts = [s.strip() for s in val_col.stripped_strings]
        out[key] = ' '.join(p for p in parts if p)
    return out


def _enclosing_col(tag):
    p = tag.parent
    for _ in range(3):
        if p is None:
            return None
        if 'el-col' in (p.get('class') or []):
            return p
        p = p.parent
    return None


def clean_text(v):
    v = re.sub(r'\s+', ' ', v or '').strip()
    return None if v in NONE_TEXT else v


def page_office(fields):
    """事務所原文：官網以空值或「@」開頭表示無事務所（查詢結果表顯示「無」）"""
    v = clean_text(fields.get('office'))
    return None if (v is None or v.startswith('@')) else v


def page_guilds(fields):
    v = clean_text(fields.get('guild'))
    if not v:
        return None
    return [g for g in re.split(r'[、,，\s]+', v) if g] or None


def page_birth_year(fields):
    m = re.search(r'(\d{2,3})', fields.get('birth') or '')
    return int(m.group(1)) if m else None


def page_date(fields, key):
    """'2026/10/29' → '2026-10-29'"""
    m = re.match(r'^(\d{4})/(\d{1,2})/(\d{1,2})$', (fields.get(key) or '').strip())
    return f'{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}' if m else None


def redacted(fields):
    """診斷輸出用：email／電話／地址只標有無"""
    return {k: (('(有)' if v else '(無)') if k in PRIVATE_FIELDS else v) for k, v in fields.items()}


class Throttle:
    """兩次請求開始時間至少相隔 interval 秒（禮貌速率 ≤1 req/s）"""

    def __init__(self, interval=1.0):
        self.interval = interval
        self._last = 0.0

    def wait(self):
        gap = time.monotonic() - self._last
        if gap < self.interval:
            time.sleep(self.interval - gap)
        self._last = time.monotonic()
