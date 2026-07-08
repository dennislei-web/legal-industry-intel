"""
裁判書開放資料 → 法官統計管線

資料來源：司法院資料開放平臺（opendata.judicial.gov.tw），每月一個 RAR 打包
（每份裁判書一個 JSON，欄位：ID/JYEAR/JCASE/JNO/JDATE/JTITLE/JFULL/JPDF），
發布晚兩個月（例：2026-06 發布 2025-04 的包）。不需帳號、不需爬網頁。

產出：judge_month_stats 表（每法官×法院×月的聚合），再由 DB 端 RPC
refresh_judge_judgment_stats() 彙總成 judge_judgment_stats 供前端 view 使用。

用法:
  python judgment_stats.py download 202504          # 下載該月 RAR 到 work dir
  python judgment_stats.py parse 202504             # 解析 RAR → 聚合 JSON
  python judgment_stats.py upload 202504            # 聚合 JSON → Supabase
  python judgment_stats.py run 202504               # download + parse + upload 一條龍
  python judgment_stats.py backfill 202001 202504   # 依序跑一段區間（跳過已上傳的月份）
  python judgment_stats.py pairfill 202005 202504   # Phase 2 配對回填（強制重解、跳過已上傳 pair 的月）

需要 7z 可執行檔（本機 scoop 已裝；GitHub Actions 需 apt install p7zip-full p7zip-rar）。
"""
import io
import os
import re
import sys
import json
import time
import subprocess
from collections import defaultdict
from datetime import date
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}
OPENDATA = 'https://opendata.judicial.gov.tw'
# 裁判書資料集是「會員限定」，下載需先登入取 token（效期約 24h，不需 Turnstile）
OD_USER = os.environ.get('JUDICIAL_OPENDATA_USER', '').strip()
OD_PWD = os.environ.get('JUDICIAL_OPENDATA_PWD', '').strip()
_od_token = None


def get_od_token():
    global _od_token
    if _od_token:
        return _od_token
    if not OD_USER:
        raise RuntimeError('缺 JUDICIAL_OPENDATA_USER/PWD（opendata.judicial.gov.tw 會員帳號）')
    r = requests.post(f'{OPENDATA}/api/MemberTokens', json={
        'memberAccount': OD_USER, 'pwd': OD_PWD,
    }, timeout=60, verify=False)
    r.raise_for_status()
    _od_token = r.json()['token']
    return _od_token
WORK_DIR = os.environ.get('JUDGMENT_WORK_DIR') or os.path.join(os.path.dirname(__file__), '.judgment_work')
SEVENZ = os.environ.get('SEVENZ_PATH', '7z')

os.makedirs(WORK_DIR, exist_ok=True)


# ============================================================
# 下載
# ============================================================

def find_fileset(yyyymm):
    """用關鍵字搜尋該月資料集，回傳 fileSetId"""
    r = requests.get(f'{OPENDATA}/api/Datasets', params={
        'Keyword': f'{yyyymm}裁判書', 'ItemsPerPage': 10, 'Page': 1,
    }, timeout=60, verify=False)
    r.raise_for_status()
    for it in r.json()['pagedList']['items']:
        # 標題格式：202504裁判書 或 202504裁判書--(20260615Update)
        if it['title'].startswith(f'{yyyymm}裁判書'):
            fs = it.get('filesetLists') or []
            if fs:
                return fs[0]['fileSetId'], it['title']
    return None, None


def download(yyyymm):
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    if os.path.exists(rar_path) and os.path.getsize(rar_path) > 1024 * 1024:
        print(f'  {yyyymm}.rar 已存在（{os.path.getsize(rar_path)/1e6:.0f} MB），跳過下載')
        return rar_path
    fileset_id, title = find_fileset(yyyymm)
    if not fileset_id:
        raise RuntimeError(f'找不到 {yyyymm} 的裁判書資料集（可能尚未發布）')
    print(f'  下載 {title}（fileSetId={fileset_id}）...')
    t0 = time.time()
    with requests.get(f'{OPENDATA}/api/FilesetLists/{fileset_id}/file',
                      headers={'Authorization': f'Bearer {get_od_token()}'},
                      stream=True, timeout=7200, verify=False) as r:
        r.raise_for_status()
        with open(rar_path + '.part', 'wb') as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
    os.replace(rar_path + '.part', rar_path)
    print(f'  完成：{os.path.getsize(rar_path)/1e6:.0f} MB，{(time.time()-t0)/60:.1f} 分鐘')
    return rar_path


# ============================================================
# 解析
# ============================================================

# 只取判決書結尾的合議庭/獨任法官署名。抓最後 3000 字內的
# 「(審判長)法 官 姓名」列，姓名 2-4 個漢字（不含空白時）或全形空白分隔。
RE_JUDGE = re.compile(
    r'(?:審判長)?法\s*官\s+([一-鿿][一-鿿\s　]{0,8}[一-鿿])\s*(?:\r|\n|$)')
# 分院要一起捕（臺灣高等法院「高雄分院」），否則各分院判決全被歸到高本院
RE_COURT = re.compile(r'^([一-鿿]{2,15}法院(?:[一-鿿]{2,4}分院)?)')

# ── 法院名正規化 v3（與 migration 038 的 fix_court_name() 同構，改一邊要同步另一邊）──
# 早年（~2001 前）裁判書是 OCR 全文，法院名有三類雜質：前綴雜字（「號臺灣高等法院」
# 「公同共有賣房臺灣新北地方法院」）、缺字錯字（「臺灣桃園法院」「壹灣高等法院」
# 「慧財產法院」）、重複段（「板橋臺灣板橋地方法院」）。
# 策略：族群判斷（檢察署/行政/高等/最高/智財/懲戒/地院）＋地名白名單錨定，修不了歸未知
# （未知列可由月包 reprocess 重建，非不可逆）。
COURT_LOCS = ('臺北', '新北', '士林', '板橋', '桃園', '新竹', '苗栗', '臺中', '南投',
              '彰化', '雲林', '嘉義', '臺南', '高雄', '橋頭', '屏東', '臺東', '花蓮',
              '宜蘭', '基隆', '澎湖', '金門', '連江')
RE_LOC = re.compile('|'.join(COURT_LOCS))
RE_HIADM_FIX = re.compile(r'(臺北|臺中|高雄|北|中|雄)高等.{0,2}?[行政]')
RE_HI_BRANCH = re.compile(
    r'高等(?:法院)?(臺中|臺南|高雄|花蓮)|^(?:臺灣)?(臺中|臺南|高雄|花蓮)高等法院$')
RE_HI_PROS_BRANCH = re.compile(r'(臺中|臺南|高雄|花蓮|金門)檢?察?分署|(智慧財產)檢?察?分署')
RE_HIGH_TYPO = re.compile(r'^[一-鿿]{1,3}(?:高等?|等)法?法院$')
# OCR 常見錯字地名（僅收形近且無歧義者）
LOC_ALIAS = {'土林': '士林', '喜義': '嘉義', '彭湖': '澎湖', '扳橋': '板橋',
             '板僑': '板橋', '板穚': '板橋', '抬東': '臺東', '屏動': '屏東', '壹中': '臺中'}


def normalize_court(name):
    n = name.replace('台', '臺').replace('褔', '福')
    for a, b in LOC_ALIAS.items():
        n = n.replace(a, b)
    if n in ('未知法院', '未知檢察署', '行政法院'):
        return n  # 「行政法院」是 2000 年改制前唯一行政法院的官方名
    if '少年' in n and ('家事' in n or '高雄' in n):
        return '臺灣高雄少年及家事法院'
    if '檢察' in n:
        if '最高' in n:
            return '最高檢察署'
        if '高等' in n:
            m = RE_HI_PROS_BRANCH.search(n)
            if m:
                loc = m.group(1) or m.group(2)
                if loc == '金門':
                    return '福建高等檢察署金門檢察分署'
                return '臺灣高等檢察署' + loc + '檢察分署'
            return '福建高等檢察署' if ('福建' in n or '金門' in n) else '臺灣高等檢察署'
        m = RE_LOC.search(n)
        if m:
            pre = '福建' if m.group(0) in ('金門', '連江') else '臺灣'
            return pre + m.group(0) + '地方檢察署'
        return '未知檢察署'
    if '最高行政' in n:
        return '最高行政法院'
    m = RE_HIADM_FIX.search(n)
    if m:
        loc = {'北': '臺北', '中': '臺中', '雄': '高雄'}.get(m.group(1), m.group(1))
        return loc + '高等行政法院'
    if '行政' in n:
        return '未知法院'  # 光桿「高等行政法院」無從判定北/中/高
    if '高等' in n:
        m = RE_HI_BRANCH.search(n)
        if m:
            return '臺灣高等法院' + (m.group(1) or m.group(2)) + '分院'
        if '金門' in n:
            return '福建高等法院金門分院'
        if '福建' in n:
            return '福建高等法院'
        return '臺灣高等法院'
    if '最高法院' in n:
        return '最高法院'
    if '智慧' in n or '慧財產' in n:
        return '智慧財產及商業法院' if '商業' in n else '智慧財產法院'
    if '懲戒' in n:
        return '公務員懲戒委員會' if '委員會' in n else '懲戒法院'
    m = RE_LOC.search(n)
    if m:
        pre = '福建' if m.group(0) in ('金門', '連江') else '臺灣'
        return pre + m.group(0) + '地方法院'
    if RE_HIGH_TYPO.match(n) and re.search('[臺壹灣等]', n) and '最' not in n:
        return '臺灣高等法院'
    return '未知法院'
RE_NOT_JUDGE_LINE = re.compile(r'書\s*記\s*官|檢\s*察\s*官|辯\s*護\s*人|司法事務官|法官助理')

# 字別 → 案類（粗分）。JID 內含裁判類別碼，但月包檔名/ID 較可靠的是全文首行。
CAT_BY_DOCNAME = [('刑事', '刑事'), ('民事', '民事'), ('行政', '行政'),
                  ('家事', '家事'), ('少年', '少年'), ('懲戒', '懲戒')]

# 家事案件的全文開頭一律寫「民事判決/裁定」（含少家法院），只能靠字別（JCASE）辨識。
# 實測 2020-10：字別含婚/家/繼/親/監宣等 = 1,757/87,563 件（全文開頭只抓得到 13 件）。
FAM_JCASE_KEYS = ('婚', '家', '繼', '親', '收養', '監宣', '輔宣', '死宣')

# 律師（訴訟代理人/辯護人）抽取。當事人欄一個標籤常帶多位律師（同行或續行縮排）：
#   訴訟代理人　雷皓明律師
#   　　　　　　張○○律師（兼送達代收人）   ← 續行沒有標籤，舊版會漏
# 標籤行抓行內全部「X律師」，之後的續行若整行只剩姓名+律師（括號附註忽略）也收，
# 遇到其他欄位（原告/法定代理人/送達代收人…）即結束 block。
# (?!\s*事\s*務\s*所) 避免把「可道律師事務所」的「可道」誤當人名。
# 中段 {0,6}? 非貪婪：同行多位律師「張三律師　李四律師」才不會被一個 match 吞掉。
RE_NAME_LAWYER = re.compile(r'([一-鿿][一-鿿\s　]{0,6}?[一-鿿])\s*律\s*師(?!\s*事\s*務\s*所)')
LAWYER_ROLES = ('訴訟代理人', '複代理人', '上訴代理人', '再抗告代理人', '非訟代理人', '辯護人')
# 標籤 regex：抽名字前先把行內標籤（含其前所有字）切掉，
# 否則姓名字元類會把「訴訟代理人」吞進姓名、長度檢查後整段作廢
RE_ROLE_TOKEN = re.compile(
    r'(?:訴\s*訟|複|上\s*訴|再\s*抗\s*告|非\s*訟)\s*代\s*理\s*人'
    r'|(?:選\s*任|指\s*定)?\s*辯\s*護\s*人|代\s*理\s*人')
# 非人名停用詞：「法扶律師」「法律扶助基金會指派之律師」「義務辯護律師」等片語
# 會被姓名 pattern 抓成假名字（實測 202503：法扶 1,876 次），一律排除
RE_BAD_NAME = re.compile(
    r'扶助|法扶|義務|指定|指派|辯護|送達|代收|基金會|具有|條及|本院|到庭|職務|事務|律師')


def extract_lawyers(jfull):
    """從裁判書當事人欄抽出律師姓名（去重；含同標籤多律師與續行）"""
    names = []

    def add(seg):
        for m in RE_NAME_LAWYER.finditer(seg):
            n = re.sub(r'[\s　]', '', m.group(1))
            if 2 <= len(n) <= 4 and not RE_BAD_NAME.search(n) and n not in names:
                names.append(n)

    in_block = False
    for line in jfull[:4000].splitlines():
        flat = re.sub(r'[\s　]', '', line)
        if not flat:
            continue
        has_role = any(k in flat for k in LAWYER_ROLES)
        # 行政訴訟用光桿「代理人」欄；排除法定代理人/送達代收人
        bare_agent = (not has_role and '代理人' in flat
                      and '法定代理人' not in flat and '送達代收' not in flat)
        if has_role or bare_agent:
            last = None
            for m in RE_ROLE_TOKEN.finditer(line):
                last = m
            add(line[last.end():] if last else line)
            in_block = True
        elif in_block:
            # 續行：去掉括號附註後整行只剩「姓名+律師」才視為同 block
            stripped = re.sub(r'[（(][^）)]*[）)]?', '', line)
            leftover = re.sub(r'[\s　]', '', RE_NAME_LAWYER.sub('', stripped))
            if RE_NAME_LAWYER.search(stripped) and not leftover:
                add(stripped)
            else:
                in_block = False
    return names


# ── 當事人方歸屬（協同/對造律師用，Phase 2）──
# 追蹤每個律師 block 之前最近的「當事人標籤」行，把律師歸到攻方 P / 守方 D / 無法歸類 X。
# 只影響協同/對造 pair；lawyer_month_stats 與律師×法官 pair 仍走上面的 extract_lawyers（不動）。
# 長標籤在前（startswith 比對）；「上訴人即被告」等複合標籤無法單純歸營 → X。
PARTY_TOKENS = (
    '被上訴人即', '上訴人即', '抗告人即', '再抗告人', '聲請人即', '相對人即',
    '反訴原告', '反訴被告', '被上訴人兼', '上訴人兼', '被上訴人', '再審原告',
    '再審被告', '聲明異議人', '被付懲戒人', '移送機關',
    '上訴人', '抗告人', '被告', '原告', '聲請人', '相對人', '自訴人',
    '債權人', '債務人', '參加人', '告訴人', '被害人', '受刑人', '異議人',
    '公訴人', '被繼承人',
)
# 攻方 P（原告/上訴/聲請一方）、守方 D（被告/被上訴/相對一方）、X 不歸營
PARTY_CAMP = {
    '原告': 'P', '反訴被告': 'P', '上訴人': 'P', '抗告人': 'P', '再抗告人': 'P',
    '聲請人': 'P', '債權人': 'P', '自訴人': 'P', '再審原告': 'P', '異議人': 'P',
    '聲明異議人': 'P', '移送機關': 'P', '公訴人': 'P', '告訴人': 'P',
    '被告': 'D', '反訴原告': 'D', '被上訴人': 'D', '相對人': 'D', '債務人': 'D',
    '再審被告': 'D', '受刑人': 'D', '被付懲戒人': 'D',
    '被害人': 'X', '參加人': 'X', '被繼承人': 'X',
}


def _party_label(flat):
    for t in PARTY_TOKENS:
        if flat.startswith(t):
            if t.endswith('即') or t.endswith('兼'):
                return t.rstrip('即兼'), 'X'  # 複合身分無法單純歸營
            return t, PARTY_CAMP.get(t, 'X')
    return None, None


def extract_lawyers_sided(jfull):
    """回傳 {name: camp}，camp ∈ P/D/X（同案同人保留第一次出現的營）。
    邏輯貼齊 extract_lawyers 的 block parser，另追蹤最近一個當事人標籤。"""
    seen = {}
    cur_camp = None
    in_block = False

    def add(seg, camp):
        for m in RE_NAME_LAWYER.finditer(seg):
            n = re.sub(r'[\s　]', '', m.group(1))
            if 2 <= len(n) <= 4 and not RE_BAD_NAME.search(n) and n not in seen:
                seen[n] = camp or 'X'

    for line in jfull[:4000].splitlines():
        flat = re.sub(r'[\s　]', '', line)
        if not flat:
            continue
        has_role = any(k in flat for k in LAWYER_ROLES)
        lbl, camp = _party_label(flat)
        if lbl and not has_role:
            cur_camp = camp
            in_block = False
            continue
        bare_agent = (not has_role and '代理人' in flat
                      and '法定代理人' not in flat and '送達代收' not in flat)
        if has_role or bare_agent:
            # 純辯護人欄（刑事）無前置當事人標籤時，歸被告方 D
            camp_here = 'D' if ('辯護人' in flat and cur_camp is None) else cur_camp
            last = None
            for m in RE_ROLE_TOKEN.finditer(line):
                last = m
            add(line[last.end():] if last else line, camp_here)
            in_block = True
        elif in_block:
            stripped = re.sub(r'[（(][^）)]*[）)]?', '', line)
            leftover = re.sub(r'[\s　]', '', RE_NAME_LAWYER.sub('', stripped))
            if RE_NAME_LAWYER.search(stripped) and not leftover:
                add(stripped, 'D' if cur_camp is None else cur_camp)
            else:
                in_block = False
    return seen


# 協同/對造 pair：單造律師數超過此上限即跳過該案該造，防大案兩兩組合平方爆炸
PAIR_MAX_PER_SIDE = 10
# 對造只在有原被告方的案類產生（刑事辯護人無對造方）
OPP_CATS = ('民事', '家事', '行政')


# ── 檢察官（刑事裁判書）──
# 檢察署名稱；2018-05 改制前叫「地方法院檢察署」，一併相容（normalize_office 正規化為新名）
RE_PROS_OFFICE = re.compile(
    r'((?:臺灣|福建)[一-鿿]{2,4}地方(?:法院)?檢察署'
    r'|(?:臺灣|福建)高等(?:法院)?檢察署(?:[一-鿿]{2,4}(?:檢察)?分署)?'
    r'|最高(?:法院)?檢察署)')
# 動作式：「本案經檢察官○○○提起公訴/聲請簡易判決」「檢察官○○○到庭執行職務」
RE_PROS_ACT = re.compile(
    r'檢\s*察\s*官\s*([一-鿿][一-鿿\s　]{0,6}[一-鿿])\s*'
    r'(?:提\s*起\s*公\s*訴|聲\s*請\s*(?:以\s*)?簡\s*易\s*判\s*決|到\s*庭\s*執\s*行\s*職\s*務)')
# 署名式：附錄起訴書/聲請書結尾的「檢　察　官　○○○」列
RE_PROS_SIG = re.compile(
    r'檢\s*察\s*官\s+([一-鿿][一-鿿\s　]{0,8}[一-鿿])\s*(?:\r|\n|$)')
# 當事人欄：「公訴人/聲請人 ○○檢察署檢察官○○○」（多數無姓名，有寫才抓）
RE_PROS_HEAD = re.compile(
    r'檢察署檢\s*察\s*官\s*([一-鿿][一-鿿\s　]{0,6}[一-鿿])\s*(?:\r|\n|$)')
# 動作式會把「經檢察官偵查後提起公訴」的「偵查後」當名字，用停用字過濾
RE_PROS_BAD = re.compile(r'偵|查|訴|聲請|後|依法|職務|到庭|執行|命令|指揮|書記')


def _pros_name(raw):
    n = re.sub(r'[\s　]', '', raw)
    return n if 2 <= len(n) <= 4 and not RE_PROS_BAD.search(n) else None


def normalize_office(name):
    return name.replace('地方法院檢察署', '地方檢察署') \
               .replace('高等法院檢察署', '高等檢察署') \
               .replace('最高法院檢察署', '最高檢察署')


def court_to_office(court):
    """裁判書內找不到檢察署名時，用法院名推對應檢察署"""
    if '地方法院' in court:
        return court.replace('地方法院', '地方檢察署')
    if '高等法院' in court:
        return re.sub(r'高等法院.*', '高等檢察署', court)
    if court == '最高法院':
        return '最高檢察署'
    return '未知檢察署'


def extract_prosecutors(jfull, court):
    """從刑事裁判書抽出 (檢察署, [檢察官姓名])；抽不到姓名時回傳空 list
    （約半數刑事判決全文只寫「經檢察官提起公訴」不具名，無從抽取）"""
    head = jfull[:1500]
    tail = jfull[-3000:]
    mo = RE_PROS_OFFICE.search(head) or RE_PROS_OFFICE.search(tail)
    office = normalize_office(mo.group(1)) if mo else court_to_office(court)
    names = []
    for m in RE_PROS_ACT.finditer(tail):
        n = _pros_name(m.group(1))
        if n and n not in names:
            names.append(n)
    if not names:
        for m in RE_PROS_SIG.finditer(tail):
            n = _pros_name(m.group(1))
            if n and n not in names:
                names.append(n)
    if not names:
        for m in RE_PROS_HEAD.finditer(head):
            if m.group(1):
                n = _pros_name(m.group(1))
                if n and n not in names:
                    names.append(n)
    return office, names


def extract_judges(jfull):
    """從裁判書全文結尾抽出法官姓名（去重、排除書記官等）"""
    tail = jfull[-3000:]
    names = []
    for m in RE_JUDGE.finditer(tail):
        # 該列若同時含書記官等字樣則跳過
        line_start = tail.rfind('\n', 0, m.start()) + 1
        line = tail[line_start: m.end()]
        if RE_NOT_JUDGE_LINE.search(line):
            continue
        name = re.sub(r'[\s　]', '', m.group(1))
        if 2 <= len(name) <= 4 and name not in names:
            names.append(name)
    return names


def classify(jfull_head, jcase):
    jc = jcase or ''
    if any(k in jc for k in FAM_JCASE_KEYS):
        return '家事'
    if '少' in jc:
        return '少年'
    for kw, cat in CAT_BY_DOCNAME:
        if kw in jfull_head:
            return cat
    return '其他'


def parse(yyyymm):
    """解壓並逐檔解析，聚合成 (法官, 法院) × 月 的統計 JSON"""
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_agg.json')
    if os.path.exists(out_path):
        print(f'  {yyyymm}_agg.json 已存在，跳過解析')
        return out_path

    # 7z 列出檔名，逐檔用 7z e -so 串流讀出（避免全部解壓佔磁碟）
    # 實測月包內為多層目錄，JSON 檔數十萬個 → 全解壓到暫存目錄較快
    extract_dir = os.path.join(WORK_DIR, yyyymm)
    if not os.path.isdir(extract_dir):
        print(f'  解壓 {yyyymm}.rar ...')
        r = subprocess.run([SEVENZ, 'x', rar_path, f'-o{extract_dir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 解壓失敗: {r.stderr[:500]}')

    # 聚合鍵：(name, court) → {n, sum_days, cats{}, years{}}
    agg = defaultdict(lambda: {'n': 0, 'sum_days': 0, 'n_days': 0,
                               'cats': defaultdict(int)})
    # 律師聚合：(name, court) → {n, cats{}}
    lagg = defaultdict(lambda: {'n': 0, 'cats': defaultdict(int)})
    # 檢察官聚合：(name, office) → {n, cats{}}
    pagg = defaultdict(lambda: {'n': 0, 'cats': defaultdict(int)})
    # Phase 2 配對聚合
    ljagg = defaultdict(lambda: {'n': 0, 'cats': defaultdict(int)})  # (律師,法官,法院)
    coagg = defaultdict(int)   # (律師A,律師B,法院) 協同（canonical A<B）
    opagg = defaultdict(int)   # (律師A,律師B,法院) 對造（canonical A<B）
    n_files = 0
    n_no_judge = 0
    t0 = time.time()
    for root, _dirs, files in os.walk(extract_dir):
        for fn in files:
            if not fn.endswith('.json'):
                continue
            n_files += 1
            try:
                with open(os.path.join(root, fn), encoding='utf-8-sig') as f:
                    doc = json.load(f)
            except (json.JSONDecodeError, OSError):
                continue
            jfull = doc.get('JFULL') or ''
            if not jfull:
                continue
            head = jfull[:60]
            mc = RE_COURT.search(head.strip())
            court = normalize_court(mc.group(1)) if mc else '未知法院'
            cat = classify(head, doc.get('JCASE') or '')
            lawyers = extract_lawyers(jfull)
            for lname in lawyers:
                la = lagg[(lname, court)]
                la['n'] += 1
                la['cats'][cat] += 1
            # ── 協同/對造 pair（不需法官，judge-less 案件也要算）──
            if lawyers:
                sided = extract_lawyers_sided(jfull)
                camp_p = sorted({n for n, c in sided.items() if c == 'P'})
                camp_d = sorted({n for n, c in sided.items() if c == 'D'})
                # 協同：同營兩兩（單造超過上限跳過防爆）
                for side in (camp_p, camp_d):
                    if len(side) > PAIR_MAX_PER_SIDE:
                        continue
                    for i in range(len(side)):
                        for j in range(i + 1, len(side)):
                            coagg[(side[i], side[j], court)] += 1
                # 對造：僅民/家/行政，攻方 × 守方
                if cat in OPP_CATS and camp_p and camp_d \
                        and len(camp_p) <= PAIR_MAX_PER_SIDE and len(camp_d) <= PAIR_MAX_PER_SIDE:
                    for a in camp_p:
                        for b in camp_d:
                            key = (a, b, court) if a <= b else (b, a, court)
                            opagg[key] += 1
            if cat in ('刑事', '少年') or '檢察署' in jfull[:1500]:
                office, pnames = extract_prosecutors(jfull, court)
                for pname in pnames:
                    pa = pagg[(pname, office)]
                    pa['n'] += 1
                    pa['cats'][cat] += 1
            judges = extract_judges(jfull)
            # ── 律師×法官 pair（律師來源＝上面同一份 extract_lawyers）──
            for lname in lawyers:
                for jname in judges:
                    lj = ljagg[(lname, jname, court)]
                    lj['n'] += 1
                    lj['cats'][cat] += 1
            if not judges:
                n_no_judge += 1
                continue
            # 審理天數估算：裁判日 - 案號年度起算日（民國年 1/1）。有一致性偏差，
            # 僅供法官間相對比較，前端標示「估算」。
            days = None
            try:
                jdate = str(doc.get('JDATE') or '')
                jyear = int(doc.get('JYEAR') or 0)
                if len(jdate) == 8 and jyear > 0:
                    d = date(int(jdate[:4]), int(jdate[4:6]), int(jdate[6:8]))
                    days = (d - date(1911 + jyear, 1, 1)).days
                    if days < 0 or days > 3650:
                        days = None
            except ValueError:
                days = None
            for name in judges:
                a = agg[(name, court)]
                a['n'] += 1
                a['cats'][cat] += 1
                if days is not None:
                    a['sum_days'] += days
                    a['n_days'] += 1
            if n_files % 50000 == 0:
                print(f'  ...{n_files} 檔，{(time.time()-t0)/60:.1f} 分', flush=True)

    rows = [{'name': k[0], 'court_name': k[1], 'yyyymm': yyyymm,
             'case_count': v['n'], 'sum_days': v['sum_days'], 'n_days': v['n_days'],
             'cats': dict(v['cats'])} for k, v in agg.items()]
    lrows = [{'name': k[0], 'court_name': k[1], 'yyyymm': yyyymm,
              'case_count': v['n'], 'cats': dict(v['cats'])} for k, v in lagg.items()]
    prows = [{'name': k[0], 'office_name': k[1], 'yyyymm': yyyymm,
              'case_count': v['n'], 'cats': dict(v['cats'])} for k, v in pagg.items()]
    ljrows = [{'lawyer_name': k[0], 'judge_name': k[1], 'court_name': k[2],
               'yyyymm': yyyymm, 'case_count': v['n'], 'cats': dict(v['cats'])}
              for k, v in ljagg.items()]
    corows = [{'lawyer_a': k[0], 'lawyer_b': k[1], 'court_name': k[2],
               'yyyymm': yyyymm, 'case_count': v} for k, v in coagg.items()]
    oprows = [{'lawyer_a': k[0], 'lawyer_b': k[1], 'court_name': k[2],
               'yyyymm': yyyymm, 'case_count': v} for k, v in opagg.items()]
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump({'judges': rows, 'lawyers': lrows, 'prosecutors': prows,
                   'lawyer_judge': ljrows, 'cocounsel': corows, 'opposing': oprows},
                  f, ensure_ascii=False)
    print(f'  解析完成：{n_files} 份裁判書，{len(rows)} 個 (法官,法院) 組合，'
          f'{len(lrows)} 個 (律師,法院) 組合，{len(prows)} 個 (檢察官,檢察署) 組合，'
          f'{len(ljrows)} 律師×法官／{len(corows)} 協同／{len(oprows)} 對造 pair，'
          f'{n_no_judge} 份未抽到法官，{(time.time()-t0)/60:.1f} 分鐘')
    return out_path


# ============================================================
# 上傳
# ============================================================

def month_uploaded(yyyymm):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/judge_month_stats',
                     params={'yyyymm': f'eq.{yyyymm}', 'select': 'yyyymm', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def _upload_rows(table, yyyymm, rows):
    print(f'  上傳 {len(rows)} 列到 {table} ...')
    # 先刪同月舊資料（冪等重跑）。必須確認刪成功才 INSERT，否則殘留列會撞 unique
    # 約束（judge/lawyer/prosecutor 月表都有 (name,court,yyyymm) 唯一鍵）→ 整月半殘。
    # DELETE 偶發逾時/連線失敗時重試，仍失敗就 raise（讓該月標記失敗、可重跑）。
    for attempt in range(3):
        dr = requests.delete(f'{SUPABASE_URL}/rest/v1/{table}',
                             params={'yyyymm': f'eq.{yyyymm}'},
                             headers=HEADERS_SB, timeout=120, verify=False)
        if dr.status_code in (200, 204):
            break
        print(f'  刪除 {table} {yyyymm} 失敗 {dr.status_code}（第 {attempt+1} 次），重試')
        time.sleep(3)
    else:
        raise RuntimeError(f'刪除 {table} {yyyymm} 連續失敗，中止上傳以免半殘')
    for i in range(0, len(rows), 500):
        batch = rows[i:i + 500]
        r = requests.post(f'{SUPABASE_URL}/rest/v1/{table}',
                          json=batch,
                          headers={**HEADERS_SB, 'Content-Type': 'application/json',
                                   'Prefer': 'return=minimal'},
                          timeout=120, verify=False)
        if r.status_code not in (200, 201, 204):
            raise RuntimeError(f'上傳失敗 {r.status_code}: {r.text[:300]}')
        time.sleep(1)


def upload(yyyymm):
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_agg.json')
    with open(out_path, encoding='utf-8') as f:
        data = json.load(f)
    if isinstance(data, list):  # 舊格式（只有法官）
        data = {'judges': data, 'lawyers': []}
    _upload_rows('judge_month_stats', yyyymm, data['judges'])
    if data['lawyers']:
        _upload_rows('lawyer_month_stats', yyyymm, data['lawyers'])
    if data.get('prosecutors'):
        _upload_rows('prosecutor_month_stats', yyyymm, data['prosecutors'])
    # Phase 2 配對表（舊 agg.json 無此三 key 時略過）
    if data.get('lawyer_judge'):
        _upload_rows('lawyer_judge_pairs', yyyymm, data['lawyer_judge'])
    if data.get('cocounsel'):
        _upload_rows('lawyer_cocounsel_pairs', yyyymm, data['cocounsel'])
    if data.get('opposing'):
        _upload_rows('lawyer_opposing_pairs', yyyymm, data['opposing'])
    print('  上傳完成')


def pairs_uploaded(yyyymm):
    """該月律師×法官 pair 是否已上傳（pairfill 冪等跳過用）"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_judge_pairs',
                     params={'yyyymm': f'eq.{yyyymm}', 'select': 'yyyymm', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def prune_pairs():
    """滾動視窗維護：刪掉配對三表中早於 (資料最新月 − 59 月) 的列。
    月更 run 後呼叫，讓配對表恆為近 60 月。"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_judge_pairs',
                     params={'select': 'yyyymm', 'order': 'yyyymm.desc', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    if r.status_code != 200 or not r.json():
        return
    maxym = r.json()[0]['yyyymm']
    y, m = int(maxym[:4]), int(maxym[4:])
    m -= 59
    while m <= 0:
        y -= 1
        m += 12
    cutoff = f'{y}{m:02d}'
    for table in ('lawyer_judge_pairs', 'lawyer_cocounsel_pairs', 'lawyer_opposing_pairs'):
        resp = requests.delete(f'{SUPABASE_URL}/rest/v1/{table}',
                               params={'yyyymm': f'lt.{cutoff}'},
                               headers=HEADERS_SB, timeout=300, verify=False)
        print(f'  prune {table} < {cutoff}: HTTP {resp.status_code}')


def refresh_stats():
    for rpc in ('refresh_judge_judgment_stats', 'refresh_prosecutor_stats',
                'refresh_lawyer_judgment_stats', 'refresh_family_lawyer_stats',
                'refresh_lawyer_region_stats'):
        print(f'  呼叫 {rpc}() ...')
        r = requests.post(f'{SUPABASE_URL}/rest/v1/rpc/{rpc}',
                          json={}, headers={**HEADERS_SB, 'Content-Type': 'application/json'},
                          timeout=600, verify=False)
        print(f'  HTTP {r.status_code}')


def cleanup(yyyymm, purge_rar=False):
    """刪掉解壓目錄（保留 agg.json）以省磁碟；purge_rar 時連 rar 一起刪
    （backfill 幾十個月會累積數十 GB；agg.json 留著即可冪等重傳）"""
    import shutil
    d = os.path.join(WORK_DIR, yyyymm)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    if purge_rar:
        rar = os.path.join(WORK_DIR, f'{yyyymm}.rar')
        if os.path.exists(rar):
            os.remove(rar)


def run_month(yyyymm, skip_uploaded=False, purge_rar=False):
    if skip_uploaded and month_uploaded(yyyymm):
        print(f'{yyyymm}: 已上傳過，跳過')
        return
    print(f'=== {yyyymm} ===')
    download(yyyymm)
    parse(yyyymm)
    upload(yyyymm)
    cleanup(yyyymm, purge_rar=purge_rar)


def month_range(start, end):
    y, m = int(start[:4]), int(start[4:])
    while f'{y}{m:02d}' <= end:
        yield f'{y}{m:02d}'
        m += 1
        if m > 12:
            y, m = y + 1, 1


if __name__ == '__main__':
    import urllib3
    urllib3.disable_warnings()
    cmd = sys.argv[1]
    if cmd == 'download':
        download(sys.argv[2])
    elif cmd == 'parse':
        parse(sys.argv[2])
    elif cmd == 'upload':
        upload(sys.argv[2])
        refresh_stats()
    elif cmd == 'run':
        run_month(sys.argv[2])
        refresh_stats()
        prune_pairs()  # 月更後維護配對表滾動視窗
    elif cmd == 'pairfill':
        # Phase 2 配對回填：強制重解（刪 agg 快取以帶出新 pair key），冪等跳過已上傳 pair 的月份。
        # 會一併冪等重傳 judge/lawyer/prosecutor 月表（內容不變），故不呼叫 refresh_stats。
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                if pairs_uploaded(ym):
                    print(f'{ym}: pairs 已上傳，跳過')
                    continue
                old_agg = os.path.join(WORK_DIR, f'{ym}_agg.json')
                if os.path.exists(old_agg):
                    os.remove(old_agg)
                run_month(ym, skip_uploaded=False, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}')
    elif cmd == 'backfill':
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                run_month(ym, skip_uploaded=True, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}')
        refresh_stats()
    elif cmd == 'reclassify':
        # 分類邏輯改版後強制重跑：刪 agg 快取、無視已上傳紀錄，逐月重新 download+parse+upload
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                old_agg = os.path.join(WORK_DIR, f'{ym}_agg.json')
                if os.path.exists(old_agg):
                    os.remove(old_agg)
                run_month(ym, skip_uploaded=False, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}')
        refresh_stats()
    else:
        print(__doc__)
