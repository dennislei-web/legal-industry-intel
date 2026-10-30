"""
MOJ 律師證號正規化（純函數，無網路、無 DB）

moj_lawyers.lic_no 是舊 API「回傳什麼就存什麼」，格式不統一：台／臺、有無括號、補零位數、
「字」「第」「號」有無、甚至錯字（撿／自）都混在一起。比對兩邊證號不能字串直接比，
一律轉成三元組 (年, 類型, 編號)：
  年   ＝民國年 int；極早年無年份者為 None
  類型 ＝台→臺、撿→檢、去「字／自／第／年」後的字根，例：臺檢證、臺檢補證、外檢證、臺證、臺補給證
  編號 ＝int（去補零）

編號連續性（DB 實測 2026-10-30）：臺檢證、臺證、臺檢補證的編號跨年度連續遞增、全域不重複，
可用 (類型, 編號) 當備援鍵；外檢證每年重新起號，必須帶年份比對。
"""
import re

_RE_TRIPLE = re.compile(r'^[\(（]?(\d{2,3})?[\)）]?(.*?)(\d+)號*$')
_RE_SERIES = re.compile(r'^(.*第)(\d+)號$')

# (類型, 編號) 全域唯一、可省略年份比對的類型
GLOBAL_NUM_KINDS = {'臺檢證', '臺證', '臺檢補證'}


def _norm_kind(kind):
    for a, b in (('台', '臺'), ('撿', '檢'), ('字', ''), ('自', ''), ('第', ''), ('年', '')):
        kind = kind.replace(a, b)
    if kind == '臺檢補':  # 錯字「臺檢補字」
        kind = '臺檢補證'
    return kind


def lic_triple(lic_no):
    """'(80)台檢證1654' → (80, '臺檢證', 1654)；解析不了回 None"""
    if not lic_no:
        return None
    s = re.sub(r'[\s　]+', '', str(lic_no))
    m = _RE_TRIPLE.match(s)
    if not m:
        return None
    kind = _norm_kind(m.group(2))
    if not kind:
        return None
    year = int(m.group(1)) if m.group(1) else None
    return (year, kind, int(m.group(3)))


def num_key(triple):
    """全域唯一類型的備援鍵 (類型, 編號)；其他類型回 None"""
    if triple and triple[1] in GLOBAL_NUM_KINDS:
        return (triple[1], triple[2])
    return None


def split_series(lic_no):
    """'115臺檢證字第19000號' → ('115臺檢證字第', '19000')；格式異常（無「第」或無「號」）回 None。
    保留原字串的編號（含補零），給查詢字串用——官網查詢比對的是它自己存的字串。"""
    m = _RE_SERIES.match(lic_no or '')
    return (m.group(1), m.group(2)) if m else None


def suggest_query(lic_no):
    """格式異常證號 → 建議在官網查詢的寫法（依 2026-07 舊 API 怪癖整理，官網實際格式為準）"""
    t = lic_triple(lic_no)
    if not t:
        return ''
    year, kind, num = t
    num_s = f'{num:04d}' if kind == '臺檢補證' and (year or 0) >= 92 else str(num)
    if year is None:
        return f'{kind}字第{num_s}號'
    year_s = f'({year})' if year <= 89 else str(year)
    return f'{year_s}{kind}字第{num_s}號'


if __name__ == '__main__':
    import sys
    for s in sys.argv[1:]:
        print(s, '→', lic_triple(s), split_series(s), suggest_query(s))
