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

# 早年（~2001 前）裁判書全文開頭有異體/缺字：「台灣」「褔建」「灣高等法院」
# 「臺臺灣」「高等法院」（光桿）等，正規化成官方名稱，避免同法院被拆成多列
RE_COURT_BARE = re.compile(r'^(?:高等法院|[一-鿿]{2,3}地方法院)$')


def normalize_court(name):
    n = name.replace('台', '臺').replace('褔', '福')
    n = re.sub(r'^臺臺灣', '臺灣', n)
    n = re.sub(r'^灣', '臺灣', n)
    if RE_COURT_BARE.match(n):
        n = '臺灣' + n
    return n
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
            for lname in extract_lawyers(jfull):
                la = lagg[(lname, court)]
                la['n'] += 1
                la['cats'][cat] += 1
            if cat in ('刑事', '少年') or '檢察署' in jfull[:1500]:
                office, pnames = extract_prosecutors(jfull, court)
                for pname in pnames:
                    pa = pagg[(pname, office)]
                    pa['n'] += 1
                    pa['cats'][cat] += 1
            judges = extract_judges(jfull)
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
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump({'judges': rows, 'lawyers': lrows, 'prosecutors': prows}, f, ensure_ascii=False)
    print(f'  解析完成：{n_files} 份裁判書，{len(rows)} 個 (法官,法院) 組合，'
          f'{len(lrows)} 個 (律師,法院) 組合，{len(prows)} 個 (檢察官,檢察署) 組合，'
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
    # 先刪同月舊資料（冪等重跑）
    requests.delete(f'{SUPABASE_URL}/rest/v1/{table}',
                    params={'yyyymm': f'eq.{yyyymm}'},
                    headers=HEADERS_SB, timeout=120, verify=False)
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
    print('  上傳完成')


def refresh_stats():
    for rpc in ('refresh_judge_judgment_stats', 'refresh_prosecutor_stats'):
        print(f'  呼叫 {rpc}() ...')
        r = requests.post(f'{SUPABASE_URL}/rest/v1/rpc/{rpc}',
                          json={}, headers={**HEADERS_SB, 'Content-Type': 'application/json'},
                          timeout=300, verify=False)
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
