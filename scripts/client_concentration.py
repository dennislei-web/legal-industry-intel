# -*- coding: utf-8 -*-
"""律師「訴訟客戶集中度」管線（lawyer_client_concentration，mig 071）

口徑：近 12 個月公開裁判書當事人欄；當事人=法人（公司/組織/機關）per 案去重；
top1_share 分母含個人當事人案件；姓名為 key（同名合併，前端沿用 name_ambiguous 旗標）。
2026-07-17 起涵蓋「全體有出庭之律師」（原 mig 071 首發僅人名事務所律師 1,609 位）。

分級（同 2026-07-09 人名事務所分析報告）：
  A 高度集中：12 個月 ≥5 件且 Top1 法人 ≥60%
  B 中度集中：≥3 件且 Top1 ≥50%
  C 分散（一般執業）：≥3 件、未達 B
  D 樣本不足：<3 件

用法（月份由新到舊皆可）:
  python client_concentration.py collect 202604 202505   # 逐月下載+抽當事人 → {ym}_clients.jsonl.gz（有快取即跳過）
  python client_concentration.py aggregate 202505 202604 # 讀快取彙總 → 全量重建上傳 lawyer_client_concentration
  python client_concentration.py run 202505 202604       # collect + aggregate 一條龍

每月處理完即刪 RAR 與解壓目錄，只留 ~30MB 的 jsonl.gz（調整法人判定/分級只需重跑 aggregate）。
"""
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import defaultdict, Counter

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judgment_stats as js  # 重用 download/7z/normalize_court/classify/律師抽取 regex 與 SB 連線

if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

# ── 當事人欄解析（沿用 2026-07-09 phase_b 驗證過的 block parser）──
RE_ANNOT = re.compile(r'[（(][^）)]*[）)]?')
# 非當事人的其他欄位標籤：結束公司名續行，但不清空當事人清單
RE_OTHER_FIELD = re.compile(
    r'^(法定代理人|代表人|代表法定代理人|送達代收|特別代理人|輔佐人|管理人|清算人|'
    r'破產管理人|遺產管理人|監護人|輔助人|兼|住|居[一-鿿]{0,4}[縣市]|統一編號|身分證)')
# 「上二人共同」「上列當事人」等 block 前綴行：結束續行
RE_STOPLINE = re.compile(r'^(上|前)?[一二三四五六七八九十兩]*人?(共同|均|等)|^上列|^共同')
# 住居所地址黏在姓名後：住/居/設 + 短接縣市 才切（避免誤切「建設股份」）
RE_ADDR_CUT = re.compile(r'[住居設](?=[一-鿿]{0,4}[縣市])')
# 公司名跨行斷尾：上行以這些片段結尾表示還沒寫完
RE_DANGLING = re.compile(r'(股份有限?|有限|股份|商業|財團法人|社團法人|工業|保險)$')

# ── 法人判定（沿用 phase_c）──
CORP_RE = re.compile(r'公司|商行|企業社|商號|工作室|有限合夥|銀行|農會|漁會|合作社')
ORG_RE = re.compile(r'基金會|協會|工會|公會|寺$|宮$|廟$|教會|學校|大學|醫院|管理委員會|社區|促進會|聯誼會')
GOV_RE = re.compile(r'政府|公所|檢察署|國稅局|地政|監理|健保|勞保|勞動部|警察局|'
                    r'行政院|立法院|司法院|考試院|監察院|[一-鿿]{2,}(部|署|局|處)$')
MASK_RE = re.compile(r'[○●Ｏｏx X甲乙丙丁]')


def clean_party(seg):
    seg = RE_ANNOT.sub('', seg)
    return RE_ADDR_CUT.split(seg)[0]


def names_in(seg):
    out = []
    for m in js.RE_NAME_LAWYER.finditer(seg):
        n = re.sub(r'[\s　]', '', m.group(1))
        if 2 <= len(n) <= 4 and not js.RE_BAD_NAME.search(n) and n not in out:
            out.append(n)
    return out


def extract_clients(jfull):
    """回傳 [(lawyer, [party...], camp)]；lawyer 去重（首見為準，貼齊 sided 口徑）"""
    res, seen = [], set()
    parties = []          # 目前 block 累積的當事人名
    cur_camp = None
    party_cont = False    # 允許公司名跨行續接
    in_role_block = False
    role_seen = False     # 上一個代理人 block 之後才清空當事人
    for line in jfull[:4000].splitlines():
        flat = re.sub(r'[\s　]', '', line)
        if not flat:
            continue
        has_role = any(k in flat for k in js.LAWYER_ROLES)
        lbl, camp = js._party_label(flat)
        if lbl and not has_role:
            # 代理人 block 結束後、或換造（camp 改變）時重新累積
            if role_seen or camp != cur_camp:
                parties, role_seen = [], False
            name = clean_party(flat[len(lbl):])
            if name:
                parties.append(name)
            cur_camp = camp
            party_cont = True
            in_role_block = False
            continue
        bare_agent = (not has_role and '代理人' in flat
                      and '法定代理人' not in flat and '送達代收' not in flat)
        if has_role or bare_agent:
            party_cont = False
            in_role_block = True
            role_seen = True
            last = None
            for m in js.RE_ROLE_TOKEN.finditer(line):
                last = m
            for n in names_in(line[last.end():] if last else line):
                if n not in seen:
                    seen.add(n)
                    res.append((n, list(parties), cur_camp))
            continue
        if in_role_block:
            stripped = RE_ANNOT.sub('', line)
            leftover = re.sub(r'[\s　]', '', js.RE_NAME_LAWYER.sub('', stripped))
            if js.RE_NAME_LAWYER.search(stripped) and not leftover:
                for n in names_in(stripped):
                    if n not in seen:
                        seen.add(n)
                        res.append((n, list(parties), cur_camp))
                continue
            in_role_block = False
        if party_cont and parties:
            if RE_OTHER_FIELD.match(flat) or RE_STOPLINE.match(flat) or '律師' in flat:
                party_cont = False
            elif flat == '公司' or RE_DANGLING.search(parties[-1]):
                parties[-1] += clean_party(flat)   # 公司名跨行續接
            elif 2 <= len(flat) <= 4:
                parties.append(clean_party(flat))  # 同標籤多當事人（人名續行）
            elif len(flat) <= 25:
                parties[-1] += clean_party(flat)
            else:
                party_cont = False
    return res


def clients_path(ym):
    return os.path.join(js.WORK_DIR, f'{ym}_clients.jsonl.gz')


def collect(ym):
    out_path = clients_path(ym)
    if os.path.exists(out_path):
        print(f'{ym} 已有 clients.jsonl.gz，跳過')
        return
    t0 = time.time()
    rar = js.download(ym)
    ext = os.path.join(js.WORK_DIR, ym)
    if not os.path.isdir(ext):
        print(f'  解壓 {ym}.rar ...')
        r = subprocess.run([js.SEVENZ, 'x', rar, f'-o{ext}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 失敗: {r.stderr[:300]}')
    n_files = n_hit = 0
    rows = []
    for root, _d, files in os.walk(ext):
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
            if not jfull or '律師' not in jfull[:4000]:
                continue
            head = jfull[:60]
            mc = js.RE_COURT.search(head.strip())
            court = js.normalize_court(mc.group(1)) if mc else '未知法院'
            cat = js.classify(head, doc.get('JCASE') or '')
            for lawyer, parts, camp in extract_clients(jfull):
                n_hit += 1
                rows.append({'ym': ym, 'lawyer': lawyer, 'parties': parts,
                             'camp': camp, 'court': court, 'cat': cat,
                             'jid': doc.get('JID') or '', 'title': doc.get('JTITLE') or ''})
    with gzip.open(out_path + '.tmp', 'wt', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    os.replace(out_path + '.tmp', out_path)
    shutil.rmtree(ext, ignore_errors=True)
    if os.path.exists(rar):
        os.remove(rar)
    print(f'{ym}: {n_files} 檔 / 命中 {n_hit} 律師案次，{(time.time()-t0)/60:.1f} 分')


def fold(s):
    return s.replace('臺', '台').strip('，,。;；:：')


def entity_type(p):
    if CORP_RE.search(p):
        return 'corp'
    if ORG_RE.search(p):
        return 'org'
    if GOV_RE.search(p):
        return 'gov'
    return None


def month_range(start, end):
    """由舊到新列出 [start, end] 的 YYYYMM"""
    out, ym = [], start
    while ym <= end:
        out.append(ym)
        y, m = int(ym[:4]), int(ym[4:])
        m += 1
        if m == 13:
            y, m = y + 1, 1
        ym = f'{y}{m:02d}'
    return out


def tier_of(n, top1_share):
    if n >= 5 and top1_share >= 0.6:
        return 'A'
    if n >= 3 and top1_share >= 0.5:
        return 'B'
    if n >= 3:
        return 'C'
    return 'D'


def aggregate(start, end):
    months = month_range(start, end)
    missing = [m for m in months if not os.path.exists(clients_path(m))]
    if missing:
        raise RuntimeError(f'缺月份快取: {missing}（先跑 collect）')
    law = defaultdict(lambda: {'n': 0, 'ent': Counter(), 'courts': Counter(), 'titles': Counter()})
    total = 0
    for ym in months:
        with gzip.open(clients_path(ym), 'rt', encoding='utf-8') as f:
            for line in f:
                r = json.loads(line)
                total += 1
                a = law[r['lawyer']]
                a['n'] += 1
                a['courts'][r['court']] += 1
                if r.get('title'):
                    a['titles'][r['title']] += 1
                ents = set()
                for p in r['parties']:
                    p = fold(p)
                    if len(p) < 4 or MASK_RE.search(p):
                        continue
                    if entity_type(p):
                        ents.add(p)
                for e in ents:
                    a['ent'][e] += 1
    print(f'{start}~{end}: {total} 律師案次 / {len(law)} 位律師')

    rows = []
    for name, a in law.items():
        top = a['ent'].most_common(3)
        top1, top1n = (top[0] if top else (None, 0))
        share = round(top1n / a['n'], 2) if a['n'] else 0
        rows.append({
            'name': name, 'window_start': start, 'window_end': end,
            'n_cases': a['n'], 'tier': tier_of(a['n'], share),
            'top1_name': top1, 'top1_n': top1n, 'top1_share': share,
            'top_entities': [[e, c] for e, c in top],
            'top_court': a['courts'].most_common(1)[0][0] if a['courts'] else None,
            'top_titles': [t for t, _ in a['titles'].most_common(3)],
        })
    dist = Counter(r['tier'] for r in rows)
    print('分級分布:', dict(sorted(dist.items())))

    # 全量重建（視窗滾動、涵蓋範圍變更都以最新一次為準）
    r = requests.delete(f'{js.SUPABASE_URL}/rest/v1/lawyer_client_concentration',
                        params={'name': 'not.is.null'}, headers=js.HEADERS_SB,
                        timeout=300, verify=False)
    if r.status_code not in (200, 204):
        raise RuntimeError(f'清空舊資料失敗 {r.status_code}: {r.text[:200]}')
    for i in range(0, len(rows), 500):
        batch = rows[i:i + 500]
        for attempt in range(3):
            r = requests.post(
                f'{js.SUPABASE_URL}/rest/v1/lawyer_client_concentration?on_conflict=name',
                json=batch,
                headers={**js.HEADERS_SB, 'Content-Type': 'application/json',
                         'Prefer': 'resolution=merge-duplicates,return=minimal'},
                timeout=180, verify=False)
            if r.status_code in (200, 201, 204):
                break
            print(f'  batch {i} HTTP {r.status_code}，重試 {attempt + 1}/3')
            time.sleep(15)
        else:
            raise RuntimeError(f'上傳失敗 batch {i}: {r.status_code} {r.text[:200]}')
    print(f'上傳完成: {len(rows)} 列')


if __name__ == '__main__':
    cmd, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    lo, hi = min(a, b), max(a, b)
    if cmd in ('collect', 'run'):
        ym = hi  # 從新到舊跑（新月包先到手，失敗月不擋後面）
        while ym >= lo:
            try:
                collect(ym)
            except Exception as e:
                print(f'{ym} 失敗: {e}')
            y, m = int(ym[:4]), int(ym[4:])
            m -= 1
            if m == 0:
                y, m = y - 1, 12
            ym = f'{y}{m:02d}'
    if cmd in ('aggregate', 'run'):
        aggregate(lo, hi)
