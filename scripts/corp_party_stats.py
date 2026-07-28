# -*- coding: utf-8 -*-
"""企業當事人歸戶 — 從裁判書月包抽「公司/法人當事人 × 代理律師」

回答「哪些事務所手上有最多企業客戶」的訴訟端 proxy：
  - corp_litigant:   公司當事人 × 月 → 案件數、有無律師代理（無代理=滲透率缺口訊號）
  - corp_lawyer_pair: 公司 × 律師 × 月 → 件數（同案同對去重；律師歸戶事務所由前端 JOIN moj_lawyers）

複用 judgment_stats.py 的下載與解析基礎（token/檔案集/7z/當事人欄 parser 慣例）。
民事＋行政案件 only（刑事被告為自然人、公司告訴人抽取噪音大）。

用法：
  python corp_party_stats.py run 202504            # download + parse 單月（不刪 RAR）
  python corp_party_stats.py parse 202504          # 已有解壓目錄/RAR 時只解析
  python corp_party_stats.py stats 202504          # 印該月量體統計（設計容量用）
"""
import json
import os
import re
import sys
import time
from collections import defaultdict

# Avast/AVG 會把 SSLKEYLOGFILE 指到 \\.\aswMonFltProxy\... 裝置，Python 開不了
# → ssl context 建立即 PermissionError(13)、下載連線中斷。直接拔掉。
os.environ.pop('SSLKEYLOGFILE', None)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from judgment_stats import (  # noqa: E402
    WORK_DIR, SEVENZ, RE_COURT, normalize_court, classify,
    extract_lawyers_sided, download, LAWYER_ROLES, _party_label,
    PARTY_CAMP,
)
import subprocess  # noqa: E402
import shutil  # noqa: E402

# 公司/法人判定（kind: corp=營利企業, org=非營利法人）
RE_CORP = re.compile(r'公司|商業銀行|合作社|農會|漁會|證券|投信|票券|資產管理|保險')
RE_ORG = re.compile(r'財團法人|社團法人|基金會|協會|公會|工會|寺|宮|廟|醫院|大學|學校')
RE_SKIP_LINE = re.compile(r'法定代理人|送達代收|代表人|統一編號')
RE_PAREN = re.compile(r'[（(][^）)]*[）)]?')


# 複合標籤剝離：「聲請人即債權人○○」→ 依序剝掉所有前導身分詞與即/兼，歸營取交集
_LABEL_TOKENS = sorted(PARTY_CAMP.keys(), key=len, reverse=True)


def strip_party_labels(flat):
    """回傳 (剩餘名稱, camp)。camp：剝出的身分詞歸營一致→該營；混合/無→X。"""
    s = flat
    camps = set()
    while True:
        if s[:1] in ('即', '兼'):
            s = s[1:]
            continue
        for t in _LABEL_TOKENS:
            if s.startswith(t):
                camps.add(PARTY_CAMP.get(t, 'X'))
                s = s[len(t):]
                break
        else:
            break
    real = camps - {'X'}
    camp = next(iter(real)) if len(real) == 1 else 'X'
    return s, camp


def company_kind(name):
    if RE_ORG.search(name):
        return 'org'
    if RE_CORP.search(name):
        return 'corp'
    return None


def norm_company(name):
    n = re.sub(r'[\s　]', '', name)
    n = RE_PAREN.sub('', n)
    n = n.replace('臺', '台')
    # 去掉「即...」別名尾綴與標點
    n = re.sub(r'[。，、;；:：]+$', '', n)
    return n


def extract_corp_parties(jfull):
    """回傳 [(company_norm, kind, true_camp, assoc_camp)]（同案去重）。
    - true_camp：剝離複合標籤後的實際歸營（存 DB 用）
    - assoc_camp：extract_lawyers_sided 同邏輯下的標籤歸營（配律師用；複合標籤=X）"""
    out = {}
    cur_camp = None
    after_label = False
    for line in jfull[:4000].splitlines():
        flat = re.sub(r'[\s　]', '', line)
        if not flat:
            continue
        has_role = any(k in flat for k in LAWYER_ROLES)
        lbl, camp = _party_label(flat)
        if lbl and not has_role:
            cur_camp = camp
            after_label = True
            nm_raw, true_camp = strip_party_labels(flat)
            if nm_raw and not RE_SKIP_LINE.search(nm_raw):
                nm = norm_company(nm_raw)
                kind = company_kind(nm)
                if kind and 5 <= len(nm) <= 60 and nm not in out:
                    out[nm] = (kind, true_camp, cur_camp)
            continue
        if has_role or '代理人' in flat:
            after_label = False
            continue
        if RE_SKIP_LINE.search(flat):
            continue
        # 標籤後續行：無標籤、無角色的公司名（多當事人續列；「即債權人○○」等前綴也要剝）
        if after_label and cur_camp is not None:
            nm_raw, tc2 = strip_party_labels(flat)
            nm = norm_company(nm_raw)
            kind = company_kind(nm)
            if kind and 5 <= len(nm) <= 60 and nm not in out:
                tc = tc2 if tc2 in ('P', 'D') else (cur_camp if cur_camp in ('P', 'D') else 'X')
                out[nm] = (kind, tc, cur_camp)
    return [(nm, k, tc, ac) for nm, (k, tc, ac) in out.items()]


def parse_corp(yyyymm):
    """解析該月已解壓目錄（無則先解壓 RAR）→ {ym}_corp.json"""
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_corp.json')
    if os.path.exists(out_path):
        print(f'  {yyyymm}_corp.json 已存在，跳過')
        return out_path
    extract_dir = os.path.join(WORK_DIR, yyyymm)
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    if not os.path.isdir(extract_dir):
        if not os.path.exists(rar_path):
            raise RuntimeError(f'{yyyymm}: 無解壓目錄也無 RAR，請先 download')
        print(f'  解壓 {yyyymm}.rar ...')
        r = subprocess.run([SEVENZ, 'x', rar_path, f'-o{extract_dir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 解壓失敗: {r.stderr[:500]}')

    litigant = defaultdict(lambda: {'n': 0, 'repr': 0})     # (company,kind) → 案件數/有代理數
    pairs = defaultdict(int)                                 # (company,lawyer,camp) → n
    n_files = n_civil = n_corp_cases = 0
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
            cat = classify(jfull[:60], doc.get('JCASE') or '')
            if cat not in ('民事', '行政'):
                continue
            n_civil += 1
            corps = extract_corp_parties(jfull)
            if not corps:
                continue
            n_corp_cases += 1
            sided = extract_lawyers_sided(jfull)
            by_camp = defaultdict(list)
            for lname, lcamp in sided.items():
                by_camp[lcamp].append(lname)
            for nm, kind, true_camp, assoc_camp in corps:
                li = litigant[(nm, kind)]
                li['n'] += 1
                lws = by_camp.get(assoc_camp, [])
                if lws:
                    li['repr'] += 1
                for lname in lws:
                    pairs[(nm, lname, true_camp)] += 1
    out = {
        'yyyymm': yyyymm, 'n_files': n_files, 'n_civil': n_civil,
        'n_corp_cases': n_corp_cases,
        'litigant': [[nm, k, v['n'], v['repr']] for (nm, k), v in litigant.items()],
        'pairs': [[nm, ln, c, n] for (nm, ln, c), n in pairs.items()],
    }
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False)
    print(f'  {yyyymm}: 檔案 {n_files:,}、民/行 {n_civil:,}、含公司當事人 {n_corp_cases:,}；'
          f'公司 {len(litigant):,}、pair {len(pairs):,}（{time.time()-t0:.0f}s）')
    return out_path


def purge_month(yyyymm):
    """刪 RAR 與解壓目錄（保留 _corp.json 與其他腳本的 _agg.json）"""
    p = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    if os.path.exists(p):
        os.remove(p)
    d = os.path.join(WORK_DIR, yyyymm)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)


def month_range(a, b):
    y, m = int(a[:4]), int(a[4:])
    out = []
    while y * 100 + m <= int(b):
        out.append(f'{y}{m:02d}')
        m += 1
        if m > 12:
            y, m = y + 1, 1
    return out


def backfill(a, b):
    """逐月 download→parse→purge；已有 _corp.json 的月份跳過（可中斷續跑）"""
    months = month_range(a, b)
    t0 = time.time()
    failed = []
    for i, ym in enumerate(months, 1):
        if os.path.exists(os.path.join(WORK_DIR, f'{ym}_corp.json')):
            print(f'[{i}/{len(months)}] {ym} 已完成，跳過', flush=True)
            continue
        for attempt in range(1, 4):
            try:
                print(f'[{i}/{len(months)}] {ym} (try {attempt}) ...', flush=True)
                download(ym)
                parse_corp(ym)
                purge_month(ym)
                break
            except Exception as e:
                print(f'[{i}/{len(months)}] {ym} 失敗：{e}', flush=True)
                purge_month(ym)
                if attempt == 3:
                    failed.append(ym)
                else:
                    time.sleep(90)
        time.sleep(5)
    print(f'backfill 完成：{len(months)-len(failed)}/{len(months)} 成功，'
          f'{(time.time()-t0)/60:.0f} 分鐘；失敗：{failed}', flush=True)
    if failed:
        sys.exit(1)  # 部分失敗 → 不觸發後續 chained upload


def _sb():
    """回傳 (base_url, headers)；service key 讀 scripts/.env"""
    env = {}
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'), encoding='utf-8-sig') as f:
        for ln in f:
            if '=' in ln and not ln.strip().startswith('#'):
                k, v = ln.strip().split('=', 1)
                env[k] = v
    key = env['SUPABASE_SERVICE_KEY']
    url = env.get('SUPABASE_URL', 'https://zpbkeyhxyykbvownrngf.supabase.co')
    return url + '/rest/v1', {'apikey': key, 'Authorization': 'Bearer ' + key,
                              'Content-Type': 'application/json',
                              'Prefer': 'resolution=merge-duplicates'}


def upload(a, b, min_n=1, dry=False):
    """把 [a,b] 區間的 _corp.json 聚合成年列上傳（period='YYYY'）。
    min_n：公司年案件數門檻（pairs 不設門檻、有代理的公司一律保留）。"""
    import urllib.request
    import ssl
    lit = defaultdict(lambda: {'kind': 'corp', 'n': 0, 'repr': 0})
    pairs = defaultdict(int)
    for ym in month_range(a, b):
        p = os.path.join(WORK_DIR, f'{ym}_corp.json')
        if not os.path.exists(p):
            print(f'  缺 {ym}_corp.json，略過')
            continue
        d = json.load(open(p, encoding='utf-8'))
        yr = ym[:4]
        for nm, k, n, rp in d['litigant']:
            li = lit[(yr, nm)]
            li['kind'] = k
            li['n'] += n
            li['repr'] += rp
        for nm, ln, c, n in d['pairs']:
            pairs[(yr, nm, ln, c)] += n
    lit_rows = [{'period': yr, 'company': nm, 'kind': v['kind'], 'n': v['n'], 'n_repr': v['repr']}
                for (yr, nm), v in lit.items() if v['n'] >= min_n or v['repr'] > 0]
    pair_rows = [{'period': yr, 'company': nm, 'lawyer': ln, 'camp': c, 'n': n}
                 for (yr, nm, ln, c), n in pairs.items()]
    print(f'litigant 年列 {len(lit_rows):,}（min_n={min_n}）、pair 年列 {len(pair_rows):,}')
    if dry:
        return
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    base, hdr = _sb()
    for table, rows in (('corp_litigants', lit_rows), ('corp_lawyer_pairs', pair_rows)):
        for i in range(0, len(rows), 2000):
            body = json.dumps(rows[i:i + 2000]).encode()
            req = urllib.request.Request(f'{base}/{table}', data=body, headers=hdr, method='POST')
            urllib.request.urlopen(req, context=ctx, timeout=120).read()
            print(f'  {table}: {min(i+2000,len(rows)):,}/{len(rows):,}', flush=True)
    print('上傳完成')


def show_stats(yyyymm):
    p = os.path.join(WORK_DIR, f'{yyyymm}_corp.json')
    d = json.load(open(p, encoding='utf-8'))
    lit = d['litigant']
    print(f"{yyyymm}: 民/行 {d['n_civil']:,}、含公司 {d['n_corp_cases']:,} "
          f"({100*d['n_corp_cases']/max(d['n_civil'],1):.1f}%)")
    print(f"  公司當事人列 {len(lit):,}（corp {sum(1 for x in lit if x[1]=='corp'):,}）、"
          f"pair 列 {len(d['pairs']):,}")
    top = sorted(lit, key=lambda x: -x[2])[:15]
    for nm, k, n, rp in top:
        print(f'  {n:5,}件 代理{rp:4,} [{k}] {nm}')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'run':
        ym = sys.argv[2]
        download(ym)
        parse_corp(ym)
        show_stats(ym)
    elif cmd == 'parse':
        parse_corp(sys.argv[2])
        show_stats(sys.argv[2])
    elif cmd == 'stats':
        show_stats(sys.argv[2])
    elif cmd == 'backfill':
        backfill(sys.argv[2], sys.argv[3])
    elif cmd == 'upload':
        upload(sys.argv[2], sys.argv[3],
               min_n=int(sys.argv[4]) if len(sys.argv) > 4 else 1,
               dry='--dry' in sys.argv)
    else:
        print(__doc__)
