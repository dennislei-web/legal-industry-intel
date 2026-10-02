"""
裁判書開放資料 → 法官統計管線

資料來源：司法院資料開放平臺（opendata.judicial.gov.tw），每月一個 RAR 打包
（每份裁判書一個 JSON，欄位：ID/JYEAR/JCASE/JNO/JDATE/JTITLE/JFULL/JPDF），
發布晚兩個月（例：2026-06 發布 2025-04 的包）。下載需會員帳號（見 get_od_token）、不需爬網頁。

產出：judge_month_stats 表（每法官×法院×月的聚合），再由 DB 端 RPC
refresh_judge_judgment_stats() 彙總成 judge_judgment_stats 供前端 view 使用。

用法:
  python judgment_stats.py download 202504          # 下載該月 RAR 到 work dir
  python judgment_stats.py parse 202504             # 解析 RAR → 聚合 JSON
  python judgment_stats.py upload 202504            # 聚合 JSON → Supabase
  python judgment_stats.py run 202504               # download + parse + upload 一條龍
  python judgment_stats.py refresh                  # 只重跑 refresh 鏈＋prune（不下載不上傳；refresh 沒跑完時補跑用）
  python judgment_stats.py backfill 202001 202504   # 依序跑一段區間（跳過已上傳的月份）
  python judgment_stats.py pairfill 202005 202504   # Phase 2 配對回填（強制重解、跳過已上傳 pair 的月）
  python judgment_stats.py causefill 202105 202604  # Phase B 案由回填（強制重解、跳過已帶 causes 的月）
  python judgment_stats.py pairamtfill 202101 202606 # 逐案層回填（mig 170：同方共同列名 pair＋民事標的金額；只傳兩張新表）
  python judgment_stats.py groupfill 202101 202504  # 所級去重素材回填（mig 186：同判決律師集合；只傳 lawyer_group_month_stats）
  python judgment_stats.py doctypefill 199601 202605 # 判決/裁定回填（強制重解、只傳 judge/lawyer 月表）

需要 7z 可執行檔（本機 scoop 已裝；GitHub Actions 需 apt install p7zip-full p7zip-rar）。
"""
import io
import os
import re
import sys
import json
import time
import shutil
import subprocess
from collections import defaultdict
from datetime import date
import requests
from dotenv import load_dotenv

from cause_map import norm_cause, map_judgment

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
    # 登入失敗時平臺回 HTTP 400＋JSON {"succeeded":false,"message":"…"}，原因在 message
    # （raise_for_status() 只會印「400 Client Error」）。會員約每 3 個月要到註冊信箱點確認
    # 連結重新啟用，未啟用回「請您先啟動會員帳號完成認證，謝謝。」；密碼錯回「帳號或密碼錯誤!」。
    # 只取 message 欄：帳號、密碼、token 一律不進例外訊息／log。
    try:
        body = r.json()
    except ValueError:
        body = None
    if not isinstance(body, dict):
        body = {}
    if r.status_code != 200 or not body.get('token'):
        msg = str(body.get('message') or '（回應沒有 message）')[:200]
        for secret in (OD_USER, OD_PWD):
            if secret:
                msg = msg.replace(secret, '***')
        hint = ('（會員約每 3 個月要到註冊信箱點確認連結重新啟用，啟用後重跑即可）'
                if '啟動會員帳號' in msg else '')
        raise RuntimeError(f'司法院資料開放平臺登入失敗（HTTP {r.status_code}）：{msg}{hint}')
    _od_token = body['token']
    return _od_token
WORK_DIR = os.environ.get('JUDGMENT_WORK_DIR') or os.path.join(os.path.dirname(__file__), '.judgment_work')
SEVENZ = os.environ.get('SEVENZ_PATH', '7z')

os.makedirs(WORK_DIR, exist_ok=True)


# ============================================================
# 下載
# ============================================================

class NotPublishedYet(RuntimeError):
    """平臺上還查不到該月的裁判書資料集（官方尚未上架）。
    與真正的失敗分開：`run` 模式以 EXIT_NOT_PUBLISHED 結束，月更 workflow 據此
    決定「之後的排程再試」或「本月最後一次了，紅燈」。"""


EXIT_NOT_PUBLISHED = 75  # sysexits.h 的 EX_TEMPFAIL（暫時性失敗，稍後再試）


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
        raise NotPublishedYet(f'找不到 {yyyymm} 的裁判書資料集（可能尚未發布）')
    print(f'  下載 {title}（fileSetId={fileset_id}）...')
    t0 = time.time()
    # 檔案端點偶發 connect timeout（Actions 曾整包掛在第一次連線），連線層重試 3 次
    for attempt in range(3):
        try:
            with requests.get(f'{OPENDATA}/api/FilesetLists/{fileset_id}/file',
                              headers={'Authorization': f'Bearer {get_od_token()}'},
                              stream=True, timeout=(30, 7200), verify=False) as r:
                r.raise_for_status()
                with open(rar_path + '.part', 'wb') as f:
                    for chunk in r.iter_content(chunk_size=1 << 20):
                        f.write(chunk)
            break
        except (requests.ConnectionError, requests.Timeout) as e:
            if attempt == 2:
                raise
            print(f'  下載連線失敗（第 {attempt+1} 次）：{e}，60 秒後重試')
            time.sleep(60)
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
# 折行孤字：少數裁判書署名排版壞掉，姓名末字被排到下一行行首（如新北 114 侵附民 49
# 「法 官 俞秀／美 …… 法 官 吳丁／偉」），RE_JUDGE 只捕到前 2 字。孤字判定＝
# 行首單一漢字，後面接行尾或（隔一段空白後）下一位的「(審判長)法 官／書 記 官」label。
# 名冊真兩字名（張議/方荳…）簽名正常時下一行以 label 開頭、非孤字，不受此規則誤傷。
RE_WRAP_ORPHAN = re.compile(
    r'^[ \t　]*([一-鿿])'
    r'(?:[ \t　]*(?:\r|\n|$)|[ \t　]+(?=(?:審判長)?法\s*官|書\s*記\s*官))')
# 署名區錨點：結尾日期列（全形空白墊排的「中 華 民 國 114 年…」；數字前必有空白，
# 內文行內日期「中華民國114年5月3日」無空白墊排不會誤中；1996-2001 OCR 老件用
# 國字年「八十五年」不會中 → fallback 舊的尾窗行為）。
# 為什麼要錨定：上訴審判決常在結尾附「原審判決全文」（附件），附件超過 3000 字時
# 舊版「取最後 3000 字」會抓到附件裡的原審署名（原審地院法官被記到上訴審法院、
# 本判決合議庭反而漏抓）→ 推定轉調誤判整排「地院→高院 異動」。本判決署名必在
# 附件之前，故取「第一個日期列＋緊接署名」的區塊。
RE_SIG_DATE = re.compile(r'中\s*華\s*民\s*國\s+\d{1,3}\s*年')
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
# 姓名級停用字：署名列黏到的程序用語（「不得上訴」「得抗告」「附錄法條」「鄭瑋附表」等）
# 與 migration 081 的 refresh_judge_changes 濾網同步，改一邊要同步另一邊
RE_JUDGE_NAME_NOISE = re.compile(r'上訴|抗告|附表|附錄|主文|原告|被告|聲請|宣示|以上')

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


def extract_lawyer_blocks(jfull):
    """同一標籤 block（一個訴訟代理人/辯護人 label 帶多位律師含續行）的律師名清單。
    邏輯貼齊 extract_lawyers 的 block parser（含 RE_BAD_NAME 假名過濾），僅多了
    block 邊界：每個 label 行開新 block、續行歸入當前 block、遇其他欄位收 block。
    回傳 [[names...], ...]，僅含 >=2 人的 block（mig 170 同案共同列名 pair 用；
    block 間＝不同當事人方或不同代理團，不算 pair）。"""
    blocks = []
    cur = []

    def add(seg):
        for m in RE_NAME_LAWYER.finditer(seg):
            n = re.sub(r'[\s　]', '', m.group(1))
            if 2 <= len(n) <= 4 and not RE_BAD_NAME.search(n) and n not in cur:
                cur.append(n)

    in_block = False
    for line in jfull[:4000].splitlines():
        flat = re.sub(r'[\s　]', '', line)
        if not flat:
            continue
        has_role = any(k in flat for k in LAWYER_ROLES)
        bare_agent = (not has_role and '代理人' in flat
                      and '法定代理人' not in flat and '送達代收' not in flat)
        if has_role or bare_agent:
            cur = []
            blocks.append(cur)
            last = None
            for m in RE_ROLE_TOKEN.finditer(line):
                last = m
            add(line[last.end():] if last else line)
            in_block = True
        elif in_block:
            stripped = re.sub(r'[（(][^）)]*[）)]?', '', line)
            leftover = re.sub(r'[\s　]', '', RE_NAME_LAWYER.sub('', stripped))
            if RE_NAME_LAWYER.search(stripped) and not leftover:
                add(stripped)
            else:
                in_block = False
    return [b for b in blocks if len(b) >= 2]


# ── 民事訴訟標的金額（mig 170）──
# 常見寫法：「本件訴訟標的金額為新臺幣X元」「訴訟標的價額核定為新臺幣X元」
# 「訴訟標的金（價）額」…金額限阿拉伯數字（含千分位逗號），國字金額（96萬元）
# 不收；抽不到跳過（部分覆蓋，覆蓋率在 parse 輸出統計）。
# 七桶口徑複製自 closed_case_stats.py 的 AMOUNT_BUCKETS/amount_bucket
# （不 import 避免模組副作用；改一邊要同步另一邊）。
AMOUNT_BUCKETS = [
    ('0', 0),
    ('1-10萬', 100_000),
    ('10-50萬', 500_000),
    ('50-100萬', 1_000_000),
    ('100-500萬', 5_000_000),
    ('500-1000萬', 10_000_000),
    ('1000萬+', None),
]


def amount_bucket(amt):
    """標的金額（元）落入級距桶 label；amt<=0 → '0'，超過 1000 萬 → '1000萬+'"""
    if amt <= 0:
        return '0'
    for label, hi in AMOUNT_BUCKETS[1:-1]:
        if amt <= hi:
            return label
    return '1000萬+'


RE_AMOUNT = re.compile(
    r'訴\s*訟\s*標\s*的\s*之?\s*(?:金|價|金\s*[（(]\s*或?\s*價\s*[）)])\s*額'
    r'[^。；：\r\n]{0,30}?(?:新\s*[臺台]\s*幣)?'
    r'[^。；0-9\r\n]{0,12}?([0-9][0-9,]{0,14})\s*元')
# 門檻/級距句（「未逾50萬元」「10萬元以下之小額…」）不是本案核定金額，跳過取下一個
RE_AMOUNT_SKIP = re.compile(r'[逾越]|以[上下]|超過|未滿|未達')


def extract_claim_amount(jfull):
    """從民事（含家事財產）裁判全文抽訴訟標的金額/價額（元）；抽不到回 None"""
    for m in RE_AMOUNT.finditer(jfull):
        if RE_AMOUNT_SKIP.search(m.group(0)):
            continue
        try:
            return int(m.group(1).replace(',', ''))
        except ValueError:
            continue
    return None


# ── 檢察官（刑事裁判書）──
# 檢察署名稱；2018-05 改制前叫「地方法院檢察署」，一併相容（normalize_office 正規化為新名）
RE_PROS_OFFICE = re.compile(
    r'((?:臺灣|福建)[一-鿿]{2,4}地方(?:法院)?檢察署'
    r'|(?:臺灣|福建)高等(?:法院)?檢察署(?:[一-鿿]{2,4}(?:檢察)?分署)?'
    r'|最高(?:法院)?檢察署)')
# 動作式：「本案經檢察官○○○提起公訴/聲請簡易判決」「檢察官○○○到庭執行職務」
# 姓名前後只容許全形/半形空白（不可跨行）：舊版用 \s 會吃掉換行，
# 「…檢察署檢察官\n被　告　○○」把下一行被告名抓成檢察官，359 月累積上萬假名
RE_PROS_ACT = re.compile(
    r'檢\s*察\s*官[ 　]*([一-鿿][一-鿿 　]{0,6}[一-鿿])[ 　]*'
    r'(?:提\s*起\s*公\s*訴|聲\s*請\s*(?:以\s*)?簡\s*易\s*判\s*決|到\s*庭\s*執\s*行\s*職\s*務)')
# 署名式：附錄起訴書/聲請書結尾的「檢　察　官　○○○」列
RE_PROS_SIG = re.compile(
    r'檢\s*察\s*官[ 　]+([一-鿿][一-鿿 　]{0,8}[一-鿿])[ 　]*(?:\r|\n|$)')
# 當事人欄：「公訴人/聲請人 ○○檢察署檢察官○○○」（多數無姓名，有寫才抓）
RE_PROS_HEAD = re.compile(
    r'檢察署檢\s*察\s*官[ 　]*([一-鿿][一-鿿 　]{0,6}[一-鿿])[ 　]*(?:\r|\n|$)')
# 動作式會把「經檢察官偵查後提起公訴」的「偵查後」當名字，用停用字過濾
# （與 migration 066 的歷史清洗 pattern 同步，改一邊要同步另一邊）
RE_PROS_BAD = re.compile(
    r'偵|查|訴|聲請|後|依法|職務|到庭|執行|命令|指揮|書記'
    r'|被告|蒞|法官|檢察|抗告|判決|裁定|通知|傳喚|移送|解送|線報|同上|前揭|中華|口|○|◯')


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
    """從裁判書署名區抽出法官姓名（去重、排除書記官等）。
    先錨定「第一個結尾日期列＋緊接法官署名」的區塊（見 RE_SIG_DATE 註解，
    防上訴審附件原審署名誤抓）；錨不到（老 OCR 件等）fallback 舊的尾窗。"""
    tail = None
    for dm in RE_SIG_DATE.finditer(jfull):
        win = jfull[dm.end(): dm.end() + 1500]
        jm = RE_JUDGE.search(win[:300])
        if jm:
            tail = win
            break
    if tail is None:
        tail = jfull[-3000:]
    names = []
    for m in RE_JUDGE.finditer(tail):
        # 該列若同時含書記官等字樣則跳過
        line_start = tail.rfind('\n', 0, m.start()) + 1
        line = tail[line_start: m.end()]
        if RE_NOT_JUDGE_LINE.search(line):
            continue
        name = re.sub(r'[\s　]', '', m.group(1))
        # 「以上正本證明…」折行黏字：「以」落在署名行尾 → 「○○○以」。現任名冊
        # 4 字名無「以」結尾者，去尾不誤傷（migration 082 清歷史資料同規則）
        if len(name) == 4 and name.endswith('以'):
            name = name[:3]
        # 下一位法官的「法 官」label 折行、「法」黏到前一位名字尾（如「楊佳祥法」）。
        # 現任名冊 0 個「法」結尾名，去尾不誤傷（migration 135 清歷史資料同規則）
        if len(name) == 4 and name.endswith('法'):
            name = name[:3]
        # 折行截斷：兩字名＋下一行以孤字開頭 → 接回末字（migration 134 清歷史資料同規則）
        if len(name) == 2:
            om = RE_WRAP_ORPHAN.match(tail[m.end():])
            if om:
                name += om.group(1)
        if 2 <= len(name) <= 4 and name not in names and not RE_JUDGE_NAME_NOISE.search(name):
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


def doctype_of(jfull_head):
    """判決/裁定拆分：文件類型寫在首行法院名之後（「民事判決」「刑事裁定」…）。
    先驗「裁定」：更正判決之裁定等首行後段會提到「判決」，反之罕見。
    非判決/裁定者（支付命令、宣示筆錄外的處分命令等）歸「其他」。"""
    if '裁定' in jfull_head:
        return '裁定'
    if '判決' in jfull_head:
        return '判決'
    return '其他'


def extract_month(yyyymm):
    """把月包解壓到 WORK_DIR/<月份>/ 並回傳該目錄；目錄已在就直接用。吃裁判書月包的腳本共用同一個
    工作目錄，解壓一律走這裡、不要各自再寫一份（parse、jy_copanel、corp_party_stats、
    client_concentration、appeal_stats、jcasefill、jcase_probe、phase2_sample_pairs）。
    先解到 <月份>.extracting，7z 回 rc=0 才改名成 <月份>——解壓途中行程被砍（關機、CI 逾時）
    或 7z 解到一半報錯時，半套檔案只會留在暫存名底下，不會被下一次當成完整月包拿去解析。
    舊寫法是直接解到 <月份>/、目錄存在就跳過解壓，這種時候重跑會拿半套檔照常算出偏低的數字
    上傳、不報錯（2026-10-01 pairamtfill 被關機打斷後盤點出來的隱患）。"""
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    extract_dir = os.path.join(WORK_DIR, yyyymm)
    if os.path.isdir(extract_dir):
        return extract_dir
    tmp_dir = extract_dir + '.extracting'
    if os.path.isdir(tmp_dir):
        print(f'  清掉上次沒解完的 {yyyymm}.extracting')
        shutil.rmtree(tmp_dir)
    print(f'  解壓 {yyyymm}.rar ...')
    r = subprocess.run([SEVENZ, 'x', rar_path, f'-o{tmp_dir}', '-y', '-bso0', '-bsp0'],
                       capture_output=True, text=True, errors='replace')
    if r.returncode != 0:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        # p7zip 舊版部分錯誤只進 stdout 或兩者皆空（如不支援的 RAR 打包），rc 一併帶出
        raise RuntimeError(f'7z 解壓失敗 rc={r.returncode}: '
                           f'{(r.stderr or r.stdout or "")[:500]}')
    # Windows 上剛解完的檔案偶爾還被防毒／索引器開著，改名會被拒，稍等再試
    for attempt in range(5):
        try:
            os.rename(tmp_dir, extract_dir)
            break
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(3)
    return extract_dir


def parse(yyyymm):
    """解壓並逐檔解析，聚合成 (法官, 法院) × 月 的統計 JSON"""
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_agg.json')
    if os.path.exists(out_path):
        print(f'  {yyyymm}_agg.json 已存在，跳過解析')
        return out_path

    # 7z 列出檔名，逐檔用 7z e -so 串流讀出（避免全部解壓佔磁碟）
    # 實測月包內為多層目錄，JSON 檔數十萬個 → 全解壓到暫存目錄較快
    extract_dir = extract_month(yyyymm)

    # 聚合鍵：(name, court) → {n, sum_days, cats{}, causes{}, doctypes{}}
    agg = defaultdict(lambda: {'n': 0, 'sum_days': 0, 'n_days': 0,
                               'cats': defaultdict(int), 'causes': defaultdict(int),
                               'doctypes': defaultdict(int)})
    # 律師聚合：(name, court) → {n, cats{}, causes{}, doctypes{}}
    # causes 鍵 = 「案類|正規化JTITLE」複合鍵（Phase B，migration 069）
    lagg = defaultdict(lambda: {'n': 0, 'cats': defaultdict(int),
                                'causes': defaultdict(int),
                                'doctypes': defaultdict(int)})
    cause_keys = set()  # 本月出現過的複合鍵（上傳時同步 cause_group_map）
    # 檢察官聚合：(name, office) → {n, cats{}}
    pagg = defaultdict(lambda: {'n': 0, 'cats': defaultdict(int)})
    # Phase 2 配對聚合
    ljagg = defaultdict(lambda: {'n': 0, 'cats': defaultdict(int)})  # (律師,法官,法院)
    coagg = defaultdict(int)   # (律師A,律師B,法院) 協同（canonical A<B）
    opagg = defaultdict(int)   # (律師A,律師B,法院) 對造（canonical A<B）
    # 逐案層（mig 170）：同 block 共同列名 pair（無法院維度、永久保存）＋ 民事金額桶
    pmagg = defaultdict(int)   # (律師A,律師B) canonical A<B → 案件數（同案去重）
    amagg = defaultdict(int)   # (律師,金額桶) → 案件數
    # 所級去重素材（mig 186）：同一裁判書的律師全集合（>=2 人；跨當事人方合併，
    # 全案類＋判決裁定都收——同所律師代理不同共同被告仍屬同一判決）
    ggagg = defaultdict(int)   # (court, cat, tuple(sorted 律師名)) → 判決數（mig 189 帶維度）
    n_civil = 0                # 民事裁判總數（金額覆蓋率分母）
    n_civil_amt = 0            # 其中抽得到訴訟標的金額者
    # 細分專庭字別（mig 131）：法官人次與案件數兩口徑；backfill 端在 jcasefill.py，
    # 這裡是月更常態輸出（兩邊聚合邏輯需一致）
    jcagg = defaultdict(int)   # (法官,法院,字別) 人次 → judge_month_jcase
    ccagg = defaultdict(int)   # (法院,字別) 案件數（含未抽到法官）→ court_month_jcase
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
            jcase = (doc.get('JCASE') or '').strip()
            cat = classify(head, jcase)
            dt = doctype_of(head)
            if jcase:
                ccagg[(court, jcase)] += 1
            ck = f'{cat}|{norm_cause(doc.get("JTITLE") or "")}'
            cause_keys.add(ck)
            lawyers = extract_lawyers(jfull)
            for lname in lawyers:
                la = lagg[(lname, court)]
                la['n'] += 1
                la['cats'][cat] += 1
                la['causes'][ck] += 1
                la['doctypes'][dt] += 1
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
            # ── 逐案層（mig 170）：同 block 共同列名 pair ＋ 民事標的金額 ──
            if len(lawyers) >= 2:
                ggagg[(court, cat, tuple(sorted(lawyers)))] += 1  # 去重素材（mig 186/189）
                pset = set()
                for blk in extract_lawyer_blocks(jfull):
                    if len(blk) > PAIR_MAX_PER_SIDE:
                        continue
                    for i in range(len(blk)):
                        for j in range(i + 1, len(blk)):
                            a, b = blk[i], blk[j]
                            pset.add((a, b) if a <= b else (b, a))
                for p in pset:
                    pmagg[p] += 1
            if cat in ('民事', '家事'):
                amt = extract_claim_amount(jfull)
                if cat == '民事':
                    n_civil += 1
                    if amt is not None:
                        n_civil_amt += 1
                if amt is not None and lawyers:
                    ab = amount_bucket(amt)
                    for lname in lawyers:
                        amagg[(lname, ab)] += 1
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
                a['causes'][ck] += 1
                a['doctypes'][dt] += 1
                if days is not None:
                    a['sum_days'] += days
                    a['n_days'] += 1
                if jcase:
                    jcagg[(name, court, jcase)] += 1
            if n_files % 50000 == 0:
                print(f'  ...{n_files} 檔，{(time.time()-t0)/60:.1f} 分', flush=True)

    rows = [{'name': k[0], 'court_name': k[1], 'yyyymm': yyyymm,
             'case_count': v['n'], 'sum_days': v['sum_days'], 'n_days': v['n_days'],
             'cats': dict(v['cats']), 'causes': dict(v['causes']),
             'doctypes': dict(v['doctypes'])} for k, v in agg.items()]
    lrows = [{'name': k[0], 'court_name': k[1], 'yyyymm': yyyymm,
              'case_count': v['n'], 'cats': dict(v['cats']),
              'causes': dict(v['causes']),
              'doctypes': dict(v['doctypes'])} for k, v in lagg.items()]
    prows = [{'name': k[0], 'office_name': k[1], 'yyyymm': yyyymm,
              'case_count': v['n'], 'cats': dict(v['cats'])} for k, v in pagg.items()]
    ljrows = [{'lawyer_name': k[0], 'judge_name': k[1], 'court_name': k[2],
               'yyyymm': yyyymm, 'case_count': v['n'], 'cats': dict(v['cats'])}
              for k, v in ljagg.items()]
    corows = [{'lawyer_a': k[0], 'lawyer_b': k[1], 'court_name': k[2],
               'yyyymm': yyyymm, 'case_count': v} for k, v in coagg.items()]
    oprows = [{'lawyer_a': k[0], 'lawyer_b': k[1], 'court_name': k[2],
               'yyyymm': yyyymm, 'case_count': v} for k, v in opagg.items()]
    pmrows = [{'ym': yyyymm, 'name_a': k[0], 'name_b': k[1], 'cases': v}
              for k, v in pmagg.items()]
    amrows = [{'ym': yyyymm, 'name': k[0], 'bucket': k[1], 'cases': v}
              for k, v in amagg.items()]
    # mig 189：帶法院×案類維度的新表列；舊表列＝聚合掉維度（一份判決只屬一個
    # 法院＋案類，拆列不拆判決，兩表恆一致）
    ggcrows = [{'ym': yyyymm, 'court_name': c, 'cat': t, 'lawyers': list(k), 'cases': v}
               for (c, t, k), v in ggagg.items()]
    gg_old = defaultdict(int)
    for (_c, _t, k), v in ggagg.items():
        gg_old[k] += v
    ggrows = [{'ym': yyyymm, 'lawyers': list(k), 'cases': v}
              for k, v in gg_old.items()]
    jcrows = [{'name': k[0], 'court_name': k[1], 'yyyymm': yyyymm, 'jcase': k[2], 'n': v}
              for k, v in jcagg.items()]
    ccrows = [{'court_name': k[0], 'yyyymm': yyyymm, 'jcase': k[1], 'n': v}
              for k, v in ccagg.items()]
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump({'judges': rows, 'lawyers': lrows, 'prosecutors': prows,
                   'lawyer_judge': ljrows, 'cocounsel': corows, 'opposing': oprows,
                   'judge_jcase': jcrows, 'court_jcase': ccrows,
                   'pair_month': pmrows, 'amount_month': amrows,
                   'lawyer_group': ggrows,
                   'lawyer_group_court': ggcrows,
                   'amount_meta': {'civil_total': n_civil,
                                   'civil_with_amount': n_civil_amt},
                   'cause_keys': sorted(cause_keys)},
                  f, ensure_ascii=False)
    print(f'  解析完成：{n_files} 份裁判書，{len(rows)} 個 (法官,法院) 組合，'
          f'{len(lrows)} 個 (律師,法院) 組合，{len(prows)} 個 (檢察官,檢察署) 組合，'
          f'{len(ljrows)} 律師×法官／{len(corows)} 協同／{len(oprows)} 對造 pair，'
          f'{len(pmrows)} 同方共列 pair，{len(ggrows)} 同案律師組合，'
          f'民事金額覆蓋 {n_civil_amt}/{n_civil}，'
          f'{n_no_judge} 份未抽到法官，{(time.time()-t0)/60:.1f} 分鐘')
    return out_path


# ============================================================
# 上傳
# ============================================================

def _month_has_rows(table, ym_col, yyyymm):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/{table}',
                     params={ym_col: f'eq.{yyyymm}', 'select': ym_col, 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    # 查詢失敗要 raise、不能回 False：這個結果決定要不要整月刪後重插，
    # 連線抖一下就被當成「沒上傳」會誤觸重傳
    r.raise_for_status()
    return len(r.json()) > 0


def month_uploaded(yyyymm, full=False):
    """該月是否已上傳。
    full=False：只看 judge_month_stats（歷史 backfill 用——2021 前的老月份本來就沒有
      後來才加的表，套完整判定會把老月份整批重傳、還會把已 prune 的 pair 列灌回去）。
    full=True：月更排程「已上傳就跳過」用，三張都要有該月——judge_month_stats
      （upload() 第一張）、lawyer_month_stats、lawyer_group_court_month_stats（upload()
      最後一張）。upload() 逐表依序刪後插、任何一張失敗就中止，所以最後一張有列 ⇒ 前面
      各表都跑完；只看第一張的話，中途失敗的半殘月會被當成已上傳。
      抓不到的半殘：剛好在最後一張插到一半失敗、或強制重跑中途失敗（後面的表舊列還在）。
      ⚠️ upload() 尾端再加表時，這裡的最後一張要跟著換。"""
    if not _month_has_rows('judge_month_stats', 'yyyymm', yyyymm):
        return False
    if not full:
        return True
    missing = [t for t, col in (('lawyer_month_stats', 'yyyymm'),
                                ('lawyer_group_court_month_stats', 'ym'))
               if not _month_has_rows(t, col, yyyymm)]
    if missing:
        print(f'  {yyyymm}: judge_month_stats 有列但缺 {"、".join(missing)}（半殘月），視為未上傳')
    return not missing


def _upload_rows(table, yyyymm, rows, ym_col='yyyymm'):
    print(f'  上傳 {len(rows)} 列到 {table} ...')
    # 先刪同月舊資料（冪等重跑）。必須確認刪成功才 INSERT，否則殘留列會撞 unique
    # 約束（judge/lawyer/prosecutor 月表都有 (name,court,yyyymm) 唯一鍵）→ 整月半殘。
    # DELETE 偶發逾時/連線失敗時重試，仍失敗就 raise（讓該月標記失敗、可重跑）。
    # ym_col：mig 170 兩表月欄叫 ym（其餘表 yyyymm）。
    for attempt in range(3):
        dr = requests.delete(f'{SUPABASE_URL}/rest/v1/{table}',
                             params={ym_col: f'eq.{yyyymm}'},
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


def sync_cause_map(cause_keys):
    """把本月出現的「案類|案由」複合鍵 mapping 後 upsert 進 cause_group_map。
    mapping 單一真實源在 cause_map.map_judgment()；規則改版後重跑本函式即可
    remap（配合 refresh rollup），不必重解析月包。"""
    rows = []
    for ck in cause_keys:
        cat, _, cause = ck.partition('|')
        rows.append({'ck': ck, 'cat': cat, 'cause': cause,
                     'cause_group': map_judgment(cat, cause)})
    for i in range(0, len(rows), 500):
        r = requests.post(f'{SUPABASE_URL}/rest/v1/cause_group_map?on_conflict=ck',
                          json=rows[i:i + 500],
                          headers={**HEADERS_SB, 'Content-Type': 'application/json',
                                   'Prefer': 'resolution=merge-duplicates,return=minimal'},
                          timeout=120, verify=False)
        if r.status_code not in (200, 201, 204):
            raise RuntimeError(f'cause_group_map 上傳失敗 {r.status_code}: {r.text[:200]}')
    print(f'  cause_group_map 同步 {len(rows)} 鍵')


def upload(yyyymm, tables=None):
    """tables=None 上傳全部；給 tuple 時只傳指定月表（doctypefill 用：
    pair 三表是近 60 月滾動視窗，老月份重傳會把已 prune 的列灌回去）"""
    def want(t):
        return tables is None or t in tables
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_agg.json')
    with open(out_path, encoding='utf-8') as f:
        data = json.load(f)
    if isinstance(data, list):  # 舊格式（只有法官）
        data = {'judges': data, 'lawyers': []}
    if data.get('cause_keys'):
        sync_cause_map(data['cause_keys'])
    if want('judge_month_stats'):
        _upload_rows('judge_month_stats', yyyymm, data['judges'])
    if data['lawyers'] and want('lawyer_month_stats'):
        _upload_rows('lawyer_month_stats', yyyymm, data['lawyers'])
    if data.get('prosecutors') and want('prosecutor_month_stats'):
        _upload_rows('prosecutor_month_stats', yyyymm, data['prosecutors'])
    # 細分專庭字別（mig 131；舊 agg.json 無此二 key 時略過，該月由 jcasefill.py 覆蓋）
    if data.get('judge_jcase') and want('judge_month_jcase'):
        _upload_rows('judge_month_jcase', yyyymm, data['judge_jcase'])
    if data.get('court_jcase') and want('court_month_jcase'):
        _upload_rows('court_month_jcase', yyyymm, data['court_jcase'])
    # Phase 2 配對表（舊 agg.json 無此三 key 時略過）
    if data.get('lawyer_judge') and want('lawyer_judge_pairs'):
        _upload_rows('lawyer_judge_pairs', yyyymm, data['lawyer_judge'])
    if data.get('cocounsel') and want('lawyer_cocounsel_pairs'):
        _upload_rows('lawyer_cocounsel_pairs', yyyymm, data['cocounsel'])
    if data.get('opposing') and want('lawyer_opposing_pairs'):
        _upload_rows('lawyer_opposing_pairs', yyyymm, data['opposing'])
    # 逐案層兩表（mig 170；舊 agg.json 無此二 key 時略過，該月由 pairamtfill 覆蓋）
    if data.get('pair_month') and want('lawyer_pair_month_stats'):
        _upload_rows('lawyer_pair_month_stats', yyyymm, data['pair_month'], ym_col='ym')
    if data.get('amount_month') and want('lawyer_amount_month_stats'):
        _upload_rows('lawyer_amount_month_stats', yyyymm, data['amount_month'], ym_col='ym')
    # 所級去重素材（mig 186；舊 agg.json 無此 key 時略過，該月由 groupfill 覆蓋）
    if data.get('lawyer_group') and want('lawyer_group_month_stats'):
        _upload_rows('lawyer_group_month_stats', yyyymm, data['lawyer_group'], ym_col='ym')
    # 法院×案類維度版（mig 189；舊 agg.json 無此 key 時略過，該月由 groupfill 覆蓋）
    # ⚠️ 這是最後一張：month_uploaded(full=True) 拿它當「整月傳完」的標記，後面再加表要同步改
    if data.get('lawyer_group_court') and want('lawyer_group_court_month_stats'):
        _upload_rows('lawyer_group_court_month_stats', yyyymm, data['lawyer_group_court'], ym_col='ym')
    print('  上傳完成')


def pairs_uploaded(yyyymm):
    """該月律師×法官 pair 是否已上傳（pairfill 冪等跳過用）"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_judge_pairs',
                     params={'yyyymm': f'eq.{yyyymm}', 'select': 'yyyymm', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def pairamt_uploaded(yyyymm):
    """該月同方共同列名 pair 是否已上傳（pairamtfill 冪等跳過用）"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_pair_month_stats',
                     params={'ym': f'eq.{yyyymm}', 'select': 'ym', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def group_uploaded(yyyymm):
    """該月同案律師組合是否已上傳（groupfill 冪等跳過用）。
    mig 189 起改看帶維度的新表——舊表已回填、新表沒有的月份要重跑
    （parse 同趟重灌兩表，維持一致）"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_group_court_month_stats',
                     params={'ym': f'eq.{yyyymm}', 'select': 'ym', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def doctypes_uploaded(yyyymm):
    """該月 judge_month_stats 是否已帶判決/裁定拆分（doctypefill 冪等跳過用）"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/judge_month_stats',
                     params={'yyyymm': f'eq.{yyyymm}', 'doctypes': 'not.is.null',
                             'select': 'yyyymm', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def causes_uploaded(yyyymm):
    """該月 lawyer_month_stats 是否已帶案由（causefill 冪等跳過用）"""
    r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_month_stats',
                     params={'yyyymm': f'eq.{yyyymm}', 'causes': 'not.is.null',
                             'select': 'yyyymm', 'limit': 1},
                     headers=HEADERS_SB, timeout=30, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


# ============================================================
# refresh 鏈（月表落地後重建各彙總）
# ============================================================
# 這一段的函數都不丟例外：各自回傳結果列 [(名稱, 'ok'｜'fail'｜'skip', 說明, 秒數)]，
# 由 refresh_and_report() 印摘要，有沒完成的項目就讓行程以 EXIT_REFRESH_FAILED 結束。

EXIT_REFRESH_FAILED = 76  # 月表已落地，但 refresh 鏈有項目失敗或被略過（自訂值，接在 75 後面）

# refresh 鏈，依序執行。每項＝(RPC, 完成標記 (表, 欄) 或 None, 該函數在 DB 端的 statement_timeout 秒數)
# 完成標記：函數 TRUNCATE＋INSERT 重建的那張表上的時間戳欄。同一個交易寫入，讀得到新值就代表
#   整支函數已 commit。重的 rollup 走 RPC 會被閘道先回 504、函數其實還在伺服器端跑（2026-10-01
#   三支律師 rollup 都是），靠它確認跑完才打下一支，不然幾支重的會在伺服器端疊在一起跑。
#   沒有標記的都是冪等的短函數，結果不明時直接重打。
# statement_timeout：要與 migration 裡各函數的 SET 一致（mig 238 起全鏈都有）——等超過這個秒數
#   標記還沒換新，就代表函數已經被砍掉。
REFRESH_CHAIN = (
    # 折行截斷清洗：先清 judge_month_stats 源頭再重算各彙總（migration 134）
    ('clean_judge_name_truncations', None, 300),
    ('refresh_judge_judgment_stats', ('judge_judgment_stats', 'refreshed_at'), 600),
    ('refresh_prosecutor_stats', ('prosecutor_stats', 'refreshed_at'), 600),
    # refresh_family_lawyer_stats 已退役（mig 183；領域律師版圖改掛 refresh_lawyer_cause_stats 尾端）
    ('refresh_lawyer_judgment_stats', ('lawyer_judgment_stats', 'refreshed_at'), 600),
    ('refresh_lawyer_region_stats', ('lawyer_region_year_stats', 'refreshed_at'), 600),
    ('refresh_lawyer_cause_stats', ('lawyer_cause_stats', 'refreshed_at'), 900),
    ('refresh_judge_changes', ('judge_changes', 'detected_at'), 600),
    # judge_changes 是 TRUNCATE 重建，遷調配對欄要跟著補（migration 084）
    ('refresh_judge_change_transfers', None, 600),
    # 官方邊之外，用署名軌跡＋區間重疊防呆補推定轉調（migration 089）
    ('refresh_judge_change_inferred_transfers', None, 600),
    # 進退場信心旗標：標記另一側是否有跨院署名（migration 090）
    ('refresh_judge_change_confidence_flag', None, 600),
)
# 清洗沒成功就不算的：這幾支都讀 judge_month_stats，沒清就算等於把截斷名當成獨立法官寫進彙總
# 與異動事件。略過只是讓法官端彙總停在上一次的結果，排除原因後跑 `refresh` 就補得回來。
REFRESH_NEEDS_CLEAN = frozenset((
    'refresh_judge_judgment_stats', 'refresh_judge_changes', 'refresh_judge_change_transfers',
    'refresh_judge_change_inferred_transfers', 'refresh_judge_change_confidence_flag'))

# 結果不明的回應：閘道逾時／上游斷線，請求可能已送到 PostgREST、函數還在伺服器端跑
RPC_UNSURE_STATUS = (502, 503, 504, 520, 522, 524)
RPC_BACKOFF = (5, 15, 45)   # 重打前等幾秒（依第幾次失敗）
REFRESH_POLL_SEC = 15       # 等完成標記換新時的輪詢間隔
_UNKNOWN = object()         # 完成標記讀不到（和「表是空的」的 None 分開）


def _rpc_error(r):
    """非 2xx 回應的摘要：PostgREST 的錯誤 JSON 取 code＋message；閘道回的 HTML 頁不印"""
    try:
        j = r.json()
    except ValueError:
        j = None
    if isinstance(j, dict) and (j.get('code') or j.get('message')):
        return f"{j.get('code') or ''} {j.get('message') or ''}".strip()[:200]
    text = ' '.join((r.text or '').split())
    return '' if text.startswith('<') else text[:120]


def _read_marker(table, col, tries=1):
    """讀 rollup 表的完成標記（整表同一個交易寫入、每列同值，取一列即可）。
    表是空的回 None；讀不到回 _UNKNOWN。"""
    for attempt in range(tries):
        try:
            r = requests.get(f'{SUPABASE_URL}/rest/v1/{table}',
                             params={'select': col, 'limit': 1},
                             headers=HEADERS_SB, timeout=30, verify=False)
            if r.status_code == 200:
                rows = r.json()
                return rows[0][col] if rows else None
        except (requests.RequestException, ValueError):
            pass
        if attempt < tries - 1:
            time.sleep(3)
    return _UNKNOWN


def _wait_marker(table, col, before, deadline):
    """輪詢完成標記到換新為止，回新值；過了 deadline 還沒換新回 _UNKNOWN。
    refresh 進行中 TRUNCATE 握著表鎖，讀取會被擋到逾時（讀不到），繼續等就好。"""
    t0 = last_note = time.time()
    while True:
        cur = _read_marker(table, col)
        if cur is not _UNKNOWN and cur is not None and cur != before:
            return cur
        if time.time() >= deadline:
            return _UNKNOWN
        if time.time() - last_note >= 60:
            last_note = time.time()
            print(f'    ...還在等 {table}.{col} 換新（已等 {last_note - t0:.0f} 秒）')
        time.sleep(REFRESH_POLL_SEC)


def _call_rpc(rpc, payload=None, marker=None, wait_max=660, tries=3, http_timeout=600):
    """打一支 refresh RPC，回 (成功與否, 說明)。
    - 2xx：成功。
    - 結果不明（RPC_UNSURE_STATUS、連線中斷、讀取逾時）：有完成標記就不重打（函數多半還在
      伺服器端跑，重打只會疊在一起），輪詢標記到換新為止，最多等到這次呼叫後 wait_max 秒；
      沒有標記的短函數退避後重打。
    - PostgREST 明確回錯（交易已 rollback）：5xx／408／409／429 退避後重打，其餘 4xx 直接失敗。
      409 多半是前一次不明的呼叫其實還在跑、兩次撞鍵，等它結束再打就會過。"""
    tag = rpc + (f' {payload}' if payload else '')
    where = f'{marker[0]}.{marker[1]}' if marker else ''
    before = _read_marker(*marker, tries=3) if marker else None
    detail = ''
    for attempt in range(1, tries + 1):
        t0 = time.time()
        try:
            r = requests.post(f'{SUPABASE_URL}/rest/v1/rpc/{rpc}', json=payload or {},
                              headers={**HEADERS_SB, 'Content-Type': 'application/json'},
                              timeout=(30, http_timeout), verify=False)
        except (requests.ConnectionError, requests.Timeout) as e:
            unsure = retryable = True
            detail = f'{type(e).__name__}（{str(e)[:100]}）'
        else:
            if r.status_code in (200, 204):
                body = r.text.strip()
                return True, f'HTTP {r.status_code}' + (f'，回傳 {body[:40]}' if body else '')
            unsure = r.status_code in RPC_UNSURE_STATUS
            retryable = unsure or r.status_code >= 500 or r.status_code in (408, 409, 429)
            detail = f'HTTP {r.status_code} {_rpc_error(r)}'.strip()
        if unsure and marker:
            if before is _UNKNOWN:
                return False, f'{detail} → 呼叫前讀不到 {where}，無法確認有沒有跑完'
            print(f'    {tag}: {detail} → 函數可能還在伺服器端跑，等 {where} 換新 ...')
            if _wait_marker(marker[0], marker[1], before, t0 + wait_max) is _UNKNOWN:
                return False, f'{detail} → 等到呼叫後 {wait_max} 秒，{where} 仍未換新'
            return True, f'{detail} → {where} 已換新，確認跑完'
        if not retryable or attempt == tries:
            break
        delay = RPC_BACKOFF[min(attempt, len(RPC_BACKOFF)) - 1]
        print(f'    {tag}: {detail}（第 {attempt} 次），{delay} 秒後重試')
        time.sleep(delay)
    return False, f'{detail}（共試 {attempt} 次）'


def prune_pairs():
    """滾動視窗維護：刪掉配對三表中早於 (資料最新月 − 59 月) 的列。
    月更 run 後呼叫，讓配對表恆為近 60 月。回傳結果列；刪除條件是「早於門檻」，
    這次沒刪成的列下次月更會一併刪掉。"""
    name = 'prune 配對表'
    try:
        r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_judge_pairs',
                         params={'select': 'yyyymm', 'order': 'yyyymm.desc', 'limit': 1},
                         headers=HEADERS_SB, timeout=30, verify=False)
        r.raise_for_status()
        rows = r.json()
    except (requests.RequestException, ValueError) as e:
        return [(name, 'fail', f'讀不到 lawyer_judge_pairs 最新月：{type(e).__name__}（{str(e)[:100]}）', 0)]
    if not rows:
        return []
    maxym = rows[0]['yyyymm']
    y, m = int(maxym[:4]), int(maxym[4:])
    m -= 59
    while m <= 0:
        y -= 1
        m += 12
    cutoff = f'{y}{m:02d}'
    t0 = time.time()
    bad = []
    for table in ('lawyer_judge_pairs', 'lawyer_cocounsel_pairs', 'lawyer_opposing_pairs'):
        try:
            resp = requests.delete(f'{SUPABASE_URL}/rest/v1/{table}',
                                   params={'yyyymm': f'lt.{cutoff}'},
                                   headers=HEADERS_SB, timeout=300, verify=False)
            ok, status = resp.status_code in (200, 204), f'HTTP {resp.status_code}'
        except requests.RequestException as e:
            ok, status = False, f'{type(e).__name__}（{str(e)[:100]}）'
        print(f'  prune {table} < {cutoff}: {status}')
        if not ok:
            bad.append(f'{table}（{status}）')
    if bad:
        return [(name, 'fail', f'< {cutoff} 沒刪成：' + '、'.join(bad), time.time() - t0)]
    return [(name, 'ok', f'< {cutoff}', time.time() - t0)]


def refresh_stats():
    """依序跑 refresh 鏈，再逐月刷去重 cache。回傳結果列。"""
    results = []
    cleaned = True
    for rpc, marker, stmt_timeout in REFRESH_CHAIN:
        if not cleaned and rpc in REFRESH_NEEDS_CLEAN:
            print(f'  略過 {rpc}()：清洗沒成功')
            results.append((rpc, 'skip', '清洗沒成功，不拿沒清的 judge_month_stats 算', 0))
            continue
        print(f'  呼叫 {rpc}() ...')
        t0 = time.time()
        # 重的（有完成標記）頂多重打一次：每打一次都是整張表 TRUNCATE 重建
        ok, detail = _call_rpc(rpc, marker=marker, wait_max=stmt_timeout + 60,
                               tries=2 if marker else 3)
        secs = time.time() - t0
        print(f'  {"OK" if ok else "失敗"}（{secs:.0f}s）{detail}')
        results.append((rpc, 'ok' if ok else 'fail', detail, secs))
        if rpc == 'clean_judge_name_truncations' and not ok:
            cleaned = False
    results.extend(refresh_firm_dedup())
    return results


def refresh_firm_dedup():
    """所×月去重 cache（mig 186）＋版圖 dup cache（mig 189）逐月重刷，回傳結果列。
    逐月打單月版（每月 ~5s）而不是一次全量：全量版走 RPC 還沒重測過，逐月全刷也順便吸收
    名冊歸戶漂移（現任名冊回溯口徑）。範圍 = lawyer_group_month_stats 的 min~max ym。
    每支 RPC 遇到連線錯誤／5xx 會退避重試；單月最終失敗只記下來、繼續下一個月
    （以前一次連線重置就整支腳本結束，後面的月份和 prune_pairs 都沒跑到）。"""
    name = '去重 cache（逐月）'

    def _edge(order):
        r = requests.get(f'{SUPABASE_URL}/rest/v1/lawyer_group_month_stats',
                         params={'select': 'ym', 'order': f'ym.{order}', 'limit': 1},
                         headers=HEADERS_SB, timeout=30, verify=False)
        r.raise_for_status()
        rows = r.json()
        return rows[0]['ym'] if rows else None
    t0 = time.time()
    try:
        lo, hi = _edge('asc'), _edge('desc')
    except (requests.RequestException, ValueError) as e:
        # 讀不到範圍不能當成「沒有素材」跳過
        return [(name, 'fail',
                 f'讀不到 lawyer_group_month_stats 的月份範圍：{type(e).__name__}（{str(e)[:100]}）', 0)]
    if not lo:
        print('  refresh_firm_dedup_stats: 無 lawyer_group 素材，跳過')
        return []
    print(f'  逐月 refresh_firm_dedup_stats + refresh_firm_court_dup {lo}~{hi} ...')
    failed = []
    for ym in month_range(lo, hi):
        # mig 189 的版圖 dup cache 一起刷（同素材趟；素材月缺新表列時算出空集無害）
        for rpc in ('refresh_firm_dedup_stats', 'refresh_firm_court_dup'):
            ok, detail = _call_rpc(rpc, {'p_ym': ym}, tries=4, http_timeout=120)
            if not ok:
                failed.append(f'{ym} {rpc}')
                print(f'    {ym} {rpc}: 失敗 — {detail}')
    secs = time.time() - t0
    if failed:
        print(f'  去重 cache 刷新完成（{len(failed)} 次失敗）')
        return [(name, 'fail', f'{lo}~{hi} 有 {len(failed)} 次失敗：' + '、'.join(failed), secs)]
    print('  去重 cache 刷新完成')
    return [(name, 'ok', f'{lo}~{hi}', secs)]


def refresh_and_report(prune=False):
    """月表落地後的收尾：refresh 鏈（月更再加 prune_pairs）→ 印摘要 → 有沒完成的項目就以
    EXIT_REFRESH_FAILED 結束（CI 才會紅）。"""
    results = []
    try:
        results += refresh_stats()
    finally:
        if prune:
            results += prune_pairs()  # refresh 鏈出什麼事都要維護配對表滾動視窗
    label = {'ok': 'OK', 'fail': '失敗', 'skip': '略過'}
    print('=== refresh 摘要 ===')
    for name, status, detail, secs in results:
        took = '' if status == 'skip' else f'（{secs:.0f}s）'
        print(f'  [{label[status]}] {name}{took} {detail}')
    bad = [x for x in results if x[1] != 'ok']
    if not bad:
        print('  全部完成')
        return
    print(f'  {len(bad)} 項沒完成。月表已落地、不必重新上傳；排除原因後補跑：'
          'python judgment_stats.py refresh')
    sys.exit(EXIT_REFRESH_FAILED)


def cleanup(yyyymm, purge_rar=False):
    """刪掉解壓目錄（保留 agg.json）以省磁碟；purge_rar 時連 rar 一起刪
    （backfill 幾十個月會累積數十 GB；agg.json 留著即可冪等重傳）"""
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
        refresh_and_report()
    elif cmd == 'refresh':
        # 只重跑 refresh 鏈＋prune，不下載、不上傳：月表已落地但 refresh 沒跑完（exit 76）時補跑用
        refresh_and_report(prune=True)
    elif cmd == 'run':
        # 無條件重跑（刪後重插）。「已上傳就跳過」由月更 workflow 的 check 步驟決定，不在這裡。
        try:
            run_month(sys.argv[2])
        except NotPublishedYet as e:
            # 月包還沒上架不是真正的失敗：用專屬 exit code 回報，其他例外照舊 traceback＋exit 1
            print(f'{sys.argv[2]}: {e}')
            sys.exit(EXIT_NOT_PUBLISHED)
        # 月表到這裡已落地；refresh 鏈有項目沒完成時以 EXIT_REFRESH_FAILED 結束
        refresh_and_report(prune=True)  # prune：月更後維護配對表滾動視窗
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
        refresh_and_report()
    elif cmd == 'causefill':
        # Phase B 案由回填：強制重解（agg 快取沒存 JTITLE），冪等跳過已帶案由的月份。
        # 會一併冪等重傳全部月表與 pair 表（內容除 causes 外不變）。
        # 失敗（多為 Supabase 5xx）等 90 秒重傳一次：agg 快取還在，upload 先刪後插
        # 也順便修掉半殘月——半殘月 causes_uploaded 會誤判 true，不能留給下次跳過。
        # 有月份最終失敗時 exit 1（CI shard 才不會假綠燈）。
        failed = []
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                if causes_uploaded(ym):
                    print(f'{ym}: causes 已上傳，跳過')
                    continue
                old_agg = os.path.join(WORK_DIR, f'{ym}_agg.json')
                if os.path.exists(old_agg):
                    os.remove(old_agg)
                run_month(ym, skip_uploaded=False, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}，90 秒後重試上傳一次')
                time.sleep(90)
                try:
                    upload(ym)
                    cleanup(ym, purge_rar=True)
                    print(f'{ym}: 重試成功')
                except Exception as e2:
                    print(f'{ym}: 重試仍失敗 — {e2}（重 dispatch 可補跑）')
                    failed.append(ym)
        if failed:
            print(f'最終失敗月份: {failed}')
            sys.exit(1)
    elif cmd == 'doctypefill':
        # 判決/裁定回填：強制重解（舊 agg 快取沒存 doctype），冪等跳過已帶 doctypes 的月份。
        # 只重傳 judge/lawyer 月表：pair 三表與 prosecutor 表內容不受 doctype 影響，
        # 且 pair 三表是近 60 月滾動視窗，老月份重傳會把已 prune 的列灌回去。
        # 失敗處理同 causefill：等 90 秒重傳一次，最終失敗 exit 1（CI shard 不假綠燈）。
        DT_TABLES = ('judge_month_stats', 'lawyer_month_stats')
        failed = []
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                if doctypes_uploaded(ym):
                    print(f'{ym}: doctypes 已上傳，跳過')
                    continue
                old_agg = os.path.join(WORK_DIR, f'{ym}_agg.json')
                if os.path.exists(old_agg):
                    os.remove(old_agg)
                print(f'=== {ym} ===')
                download(ym)
                parse(ym)
                upload(ym, tables=DT_TABLES)
                cleanup(ym, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}，90 秒後重試上傳一次')
                time.sleep(90)
                try:
                    upload(ym, tables=DT_TABLES)
                    cleanup(ym, purge_rar=True)
                    print(f'{ym}: 重試成功')
                except Exception as e2:
                    print(f'{ym}: 重試仍失敗 — {e2}（重 dispatch 可補跑）')
                    failed.append(ym)
        if failed:
            print(f'最終失敗月份: {failed}')
            sys.exit(1)
    elif cmd == 'pairamtfill':
        # 逐案層回填（mig 170）：同 block 共同列名 pair ＋ 民事標的金額。
        # 強制重解（舊 agg 快取沒存 pair_month/amount_month key），冪等跳過已上傳的月份。
        # 只傳兩張新表：pair 三表是近 60 月滾動視窗，老月份重傳會把已 prune 的列灌回去
        # （同 doctypefill 的理由）；judge/lawyer/prosecutor 月表內容不變、不必重傳。
        # 失敗處理同 causefill：等 90 秒重傳一次，最終失敗 exit 1。
        PA_TABLES = ('lawyer_pair_month_stats', 'lawyer_amount_month_stats')
        failed = []
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                if pairamt_uploaded(ym):
                    print(f'{ym}: pair/amount 已上傳，跳過')
                    continue
                old_agg = os.path.join(WORK_DIR, f'{ym}_agg.json')
                if os.path.exists(old_agg):
                    os.remove(old_agg)
                print(f'=== {ym} ===')
                download(ym)
                parse(ym)
                upload(ym, tables=PA_TABLES)
                cleanup(ym, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}，90 秒後重試上傳一次')
                time.sleep(90)
                try:
                    upload(ym, tables=PA_TABLES)
                    cleanup(ym, purge_rar=True)
                    print(f'{ym}: 重試成功')
                except Exception as e2:
                    print(f'{ym}: 重試仍失敗 — {e2}（重跑可補）')
                    failed.append(ym)
        if failed:
            print(f'最終失敗月份: {failed}')
            sys.exit(1)
    elif cmd == 'groupfill':
        # 所級去重素材回填（mig 186）：同一裁判書律師集合 → lawyer_group_month_stats。
        # 強制重解（舊 agg 快取沒存 lawyer_group key），冪等跳過已上傳的月份。
        # 只傳一張新表（其餘月表內容不變、pair 三表滾動視窗不重灌，同 pairamtfill 理由）。
        # 失敗處理同 causefill：等 90 秒重傳一次，最終失敗 exit 1。
        GF_TABLES = ('lawyer_group_month_stats', 'lawyer_group_court_month_stats')
        failed = []
        for ym in month_range(sys.argv[2], sys.argv[3]):
            try:
                if group_uploaded(ym):
                    print(f'{ym}: lawyer_group 已上傳，跳過')
                    continue
                old_agg = os.path.join(WORK_DIR, f'{ym}_agg.json')
                if os.path.exists(old_agg):
                    os.remove(old_agg)
                print(f'=== {ym} ===')
                download(ym)
                parse(ym)
                upload(ym, tables=GF_TABLES)
                cleanup(ym, purge_rar=True)
            except Exception as e:
                print(f'{ym}: 失敗 — {e}，90 秒後重試上傳一次')
                time.sleep(90)
                try:
                    upload(ym, tables=GF_TABLES)
                    cleanup(ym, purge_rar=True)
                    print(f'{ym}: 重試成功')
                except Exception as e2:
                    print(f'{ym}: 重試仍失敗 — {e2}（重跑可補）')
                    failed.append(ym)
        if failed:
            print(f'最終失敗月份: {failed}')
            sys.exit(1)
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
        refresh_and_report()
    else:
        print(__doc__)
