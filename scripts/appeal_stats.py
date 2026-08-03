# -*- coding: utf-8 -*-
"""上訴維持率管線：裁判書全文反算「法官被上級審維持/廢棄」統計 → judge_appeal_stats（mig 128）。

外部無任何公開來源提供法官層級撤銷率（司法統計只有法院層級）——本管線從
上級審判決抽「不服○○法院○年度○字第○號判決」原審引用＋主文結果，join 回
原審判決的署名法官。涵蓋：地院→高院（含分院）、高院→最高、簡易庭→地院合議
（本院引用）、行政法院體系；僅計「判決」（程序裁定不計）。

與 judgment_stats.py 共用下載/解析基礎（月包 RAR、法官署名 regex、法院名正規化）。
每月產出兩個快取（保留供 join 重跑，不必重下 RAR）：
  {ym}_jcase.jsonl.gz  — 判決索引：(法院,年度,字,號) → 署名法官
  {ym}_appeal.jsonl.gz — 上訴審列：原審引用＋主文結果＋上級審法官
join 需跨月（上訴審距原審判決可達 1-2 年），原審索引窗要比上訴審窗早。

用法：
  python appeal_stats.py month 202504         # 下載+解析單月 → 兩個快取（會清 RAR）
  python appeal_stats.py backfill 202001 202605   # 逐月補（跳過已有快取月份）
  python appeal_stats.py join                 # 全部快取 join → .judgment_work/appeal_agg.json
  python appeal_stats.py upload               # 重建 judge_appeal_stats 表
  python appeal_stats.py auto                 # 月增量：補到最新已發布月，有新才 join+upload
                                              # （Windows 排程每月 20 日 03:30 跑，見 appeal_monthly.bat）
"""
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import defaultdict

import requests

sys.stdout.reconfigure(encoding='utf-8')
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from judgment_stats import (  # noqa: E402
    WORK_DIR, SEVENZ, download, normalize_court, extract_judges, classify,
    doctype_of, RE_COURT)

for line in io.open(os.path.join(HERE, '.env'), encoding='utf-8'):
    if '=' in line and not line.strip().startswith('#'):
        k, v = line.split('=', 1)
        os.environ.setdefault(k.strip(), v.strip())
SB_URL = os.environ['SUPABASE_URL']
SB_KEY = os.environ['SUPABASE_SERVICE_KEY']
HEAD = {'apikey': SB_KEY, 'Authorization': f'Bearer {SB_KEY}'}

# ── 原審引用抽取（上級審判決首段固定句式）──
# 民事二審：「上訴人對於中華民國114年5月2日臺灣臺北地方法院114年度訴字第123號
#           第一審判決提起上訴」
# 刑事二審：「不服臺灣臺北地方法院113年度易字第456號中華民國114年1月1日第一審
#           判決，提起上訴」
# 三審：「對於中華民國…臺灣高等法院…年度…字第…號第二審判決提起上訴」
# 簡上：「對於本院臺北簡易庭…年度北簡字第…號第一審判決提起上訴」
RE_ORIG = re.compile(
    r'(?:不服|對於|就)[^。；]{0,60}?'
    r'(本院|(?:臺灣|福建)[一-鿿]{2,4}地方法院|臺灣高等法院(?:[一-鿿]{2}分院)?|'
    r'福建高等法院(?:金門分院)?|(?:臺北|臺中|高雄)高等行政法院|'
    r'智慧財產及商業法院|智慧財產法院|臺灣高雄少年及家事法院)'
    r'[^。；]{0,60}?(\d{2,3})\s*年度\s*([一-鿿A-Za-z]{1,8}?)\s*字\s*第\s*(\d+)\s*號')
# 上級審身分認定：本院自己的字別含上訴審字樣（含行政訴訟上字）
RE_APP_JCASE = re.compile(r'上|抗')

# 主文結果分類（取「主文」後至理由段前的文字）
RE_MAIN_SPAN = re.compile(r'主\s*文(.{0,600}?)(?:事\s*實|理\s*由|犯罪事實|$)', re.S)


def outcome_of(jfull):
    m = RE_MAIN_SPAN.search(jfull[:8000])
    if not m:
        return None
    main = re.sub(r'[\s　]', '', m.group(1))[:300]
    has_rev = ('廢棄' in main) or ('原判決' in main and '撤銷' in main) or ('原處分' in main and '撤銷' in main)
    has_dismiss = '上訴駁回' in main or '駁回上訴' in main
    if has_rev and has_dismiss:
        return 'rev_part'   # 部分廢棄、其餘上訴駁回
    if has_rev:
        return 'rev_full'
    if has_dismiss:
        return 'upheld'
    return 'other'          # 發回、移送、和解、免訴改判等非典型主文


def month(yyyymm, keep_rar=False):
    """下載+解析單月：判決索引 & 上訴審列 → jsonl.gz 快取"""
    jcase_path = os.path.join(WORK_DIR, f'{yyyymm}_jcase.jsonl.gz')
    appeal_path = os.path.join(WORK_DIR, f'{yyyymm}_appeal.jsonl.gz')
    if os.path.exists(jcase_path) and os.path.exists(appeal_path):
        print(f'  {yyyymm} 快取已存在，跳過')
        return
    download(yyyymm)
    extract_dir = os.path.join(WORK_DIR, yyyymm)
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    if not os.path.isdir(extract_dir):
        print(f'  解壓 {yyyymm}.rar ...')
        r = subprocess.run([SEVENZ, 'x', rar_path, f'-o{extract_dir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 解壓失敗: {r.stderr[:500]}')
    n = n_jc = n_ap = 0
    t0 = time.time()
    with gzip.open(jcase_path + '.part', 'wt', encoding='utf-8') as fj, \
         gzip.open(appeal_path + '.part', 'wt', encoding='utf-8') as fa:
        for root, _dirs, files in os.walk(extract_dir):
            for fn in files:
                if not fn.endswith('.json'):
                    continue
                n += 1
                try:
                    with open(os.path.join(root, fn), encoding='utf-8-sig') as f:
                        doc = json.load(f)
                except (json.JSONDecodeError, OSError):
                    continue
                jfull = doc.get('JFULL') or ''
                if not jfull:
                    continue
                head = jfull[:60]
                if doctype_of(head) != '判決':
                    continue
                mc = RE_COURT.search(head.strip())
                court = normalize_court(mc.group(1)) if mc else '未知法院'
                if court.startswith('未知'):
                    continue
                jyear = str(doc.get('JYEAR') or '')
                jcase = (doc.get('JCASE') or '').strip()
                jno = str(doc.get('JNO') or '')
                judges = extract_judges(jfull)
                cat = classify(head, jcase)
                if judges and jyear and jcase and jno:
                    fj.write(json.dumps({'k': f'{court}|{jyear}|{jcase}|{jno}',
                                         'j': judges, 'c': cat}, ensure_ascii=False) + '\n')
                    n_jc += 1
                # 上訴審：字別含上/抗 且首段引用原審判決（抗告裁定已被判決過濾擋掉）
                if not RE_APP_JCASE.search(jcase):
                    continue
                mo = RE_ORIG.search(jfull[:2500])
                if not mo:
                    continue
                oc = court if mo.group(1) == '本院' else normalize_court(mo.group(1))
                out = outcome_of(jfull)
                if not out:
                    continue
                fa.write(json.dumps({
                    'ym': yyyymm, 'ac': court, 'aj': judges, 'cat': cat, 'out': out,
                    'ok': f'{oc}|{int(mo.group(2))}|{mo.group(3)}|{int(mo.group(4))}',
                }, ensure_ascii=False) + '\n')
                n_ap += 1
                if n % 50000 == 0:
                    print(f'  ...{n} 檔，{(time.time()-t0)/60:.1f} 分', flush=True)
    os.replace(jcase_path + '.part', jcase_path)
    os.replace(appeal_path + '.part', appeal_path)
    print(f'  {yyyymm}: {n} 檔 → 索引 {n_jc} 判決、上訴審 {n_ap} 列，'
          f'{(time.time()-t0)/60:.1f} 分鐘', flush=True)
    shutil.rmtree(extract_dir, ignore_errors=True)
    if not keep_rar and os.path.exists(rar_path):
        os.remove(rar_path)


def _norm_key(k):
    """索引鍵字別去空白正規化（JCASE 與引用字別偶有全形空白差）"""
    return re.sub(r'[\s　]', '', k)


def join():
    """全部月份快取 join → 兩視角聚合"""
    jc_files = sorted(f for f in os.listdir(WORK_DIR) if f.endswith('_jcase.jsonl.gz'))
    ap_files = sorted(f for f in os.listdir(WORK_DIR) if f.endswith('_appeal.jsonl.gz'))
    print(f'索引月份 {len(jc_files)}、上訴月份 {len(ap_files)}')
    # pass 1：收集所有被引用的原審 key
    cited = set()
    appeals = []
    for f in ap_files:
        with gzip.open(os.path.join(WORK_DIR, f), 'rt', encoding='utf-8') as fh:
            for line in fh:
                r = json.loads(line)
                r['ok'] = _norm_key(r['ok'])
                # 引用抓到偵查案號（起訴案號括注）＝非裁判，永遠對不回索引 → 剔除
                if '偵' in r['ok'].split('|')[2]:
                    continue
                cited.add(r['ok'])
                appeals.append(r)
    print(f'上訴審列 {len(appeals)}，被引用原審 key {len(cited)}')
    # pass 2：從索引撈出被引用案的法官（同 key 出現多次＝更正判決等，保留第一次）
    idx = {}
    for f in jc_files:
        with gzip.open(os.path.join(WORK_DIR, f), 'rt', encoding='utf-8') as fh:
            for line in fh:
                r = json.loads(line)
                k = _norm_key(r['k'])
                if k in cited and k not in idx:
                    idx[k] = r['j']
    matched = sum(1 for a in appeals if a['ok'] in idx)
    print(f'原審可對回：{matched}/{len(appeals)}（{matched/max(len(appeals),1)*100:.1f}%）')
    # 聚合：trial＝原審法官被維持/廢棄；appellate＝上級審法官駁回/廢棄傾向
    agg = defaultdict(lambda: {'appealed': 0, 'upheld': 0, 'rev_full': 0,
                               'rev_part': 0, 'other': 0})
    for a in appeals:
        oj = idx.get(a['ok'])
        if oj:
            oc = a['ok'].split('|')[0]
            for name in oj:
                r = agg[(name, oc, 'trial', a['cat'])]
                r['appealed'] += 1
                r[a['out']] += 1
        for name in a['aj']:
            r = agg[(name, a['ac'], 'appellate', a['cat'])]
            r['appealed'] += 1
            r[a['out']] += 1
    rows = [{'name': k[0], 'court_name': k[1], 'side': k[2], 'cat': k[3], **v}
            for k, v in agg.items()]
    out = os.path.join(WORK_DIR, 'appeal_agg.json')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump({'rows': rows, 'months_idx': [f[:6] for f in jc_files],
                   'months_ap': [f[:6] for f in ap_files],
                   'n_appeals': len(appeals), 'n_matched': matched}, f, ensure_ascii=False)
    print(f'聚合 {len(rows)} 列 → {out}')


def upload():
    d = json.load(open(os.path.join(WORK_DIR, 'appeal_agg.json'), encoding='utf-8'))
    rows = d['rows']
    # 全量重建（DELETE + 分批 INSERT；表小、無外鍵）
    r = requests.delete(f'{SB_URL}/rest/v1/judge_appeal_stats?id=gt.0', headers=HEAD, timeout=120)
    print(f'DELETE {r.status_code}')
    for i in range(0, len(rows), 3000):
        r = requests.post(f'{SB_URL}/rest/v1/judge_appeal_stats',
                          headers={**HEAD, 'Content-Type': 'application/json',
                                   'Prefer': 'return=minimal'},
                          json=rows[i:i + 3000], timeout=300)
        if r.status_code not in (200, 201, 204):
            print(f'batch {i} 失敗 {r.status_code}: {r.text[:300]}')
            sys.exit(1)
        print(f'  insert {i}~{i + len(rows[i:i + 3000])}', flush=True)
    print(f'完成：{len(rows)} 列（上訴審 {d["n_appeals"]}、可對回 {d["n_matched"]}）')


def _next_ym(ym):
    y, m = int(ym[:4]), int(ym[4:]) + 1
    return f'{y + 1:04d}01' if m > 12 else f'{y:04d}{m:02d}'


def auto():
    """月增量：從最後快取月的次月補到（當月-2，月包晚兩個月發布）；有新月才 join+upload"""
    from datetime import date as _date
    yms = sorted(f[:6] for f in os.listdir(WORK_DIR) if f.endswith('_appeal.jsonl.gz'))
    if not yms:
        print('無既有快取，請先跑 backfill')
        return
    today = _date.today()
    ty, tm = (today.year, today.month - 2) if today.month > 2 else (today.year - 1, today.month + 10)
    target = f'{ty:04d}{tm:02d}'
    ym, ran = _next_ym(yms[-1]), []
    while ym <= target:
        print(f'== {ym} ==', flush=True)
        try:
            month(ym)
            ran.append(ym)
        except RuntimeError as e:
            print(f'  {ym}：{e}（停止，下次再試）', flush=True)
            break
        ym = _next_ym(ym)
    if ran:
        join()
        upload()
        print(f'月增量完成：{ran}')
    else:
        print('無新月份可補')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'month':
        month(sys.argv[2])
    elif cmd == 'backfill':
        y0, y1 = sys.argv[2], sys.argv[3]
        ym = y0
        while ym <= y1:
            print(f'== {ym} ==', flush=True)
            try:
                month(ym)
            except RuntimeError as e:
                print(f'  {ym} 失敗：{e}', flush=True)
            y, m = int(ym[:4]), int(ym[4:])
            m += 1
            if m > 12:
                y, m = y + 1, 1
            ym = f'{y:04d}{m:02d}'
    elif cmd == 'join':
        join()
    elif cmd == 'upload':
        upload()
    elif cmd == 'auto':
        auto()
    else:
        print(__doc__)
