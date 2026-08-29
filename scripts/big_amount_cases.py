# -*- coding: utf-8 -*-
"""1 億+ 標的案件逐案明細回填（mig 174：big_amount_cases）

微資料側＝司法院終結案件月包（民訴＋家訴，官方標的金額），只取 amount >= 1 億；
裁判書側＝scripts/.judgment_work/{ym}_clients.jsonl.gz（律師/當事人/camp/案由/法院），
join key＝JID 前 4 段，按該案「裁判月」查快取（同 lawyer_case_amount.py 口徑）。
每月處理完即 DELETE 該終結月再 INSERT（冪等），並記入 .bac_done 清單可斷點續跑。

用法：
  python big_amount_cases.py backfill 202111 202606   # 由新往舊逐月回填（跳過已完成月）
  python big_amount_cases.py run 202503               # 強制重跑單月
"""
import io
import os
import sys
import json
import glob
import gzip
import shutil
import subprocess
from collections import defaultdict

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lawyer_case_amount import (  # noqa: E402
    list_datasets, key4, JID_RE, FILE_TYPES,
    APPEAL2_PREFIXES, APPEAL3_PREFIXES,
    SUPABASE_URL, HEADERS_SB, OPENDATA, SEVENZ, JW_DIR,
)

if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

THRESHOLD = 100_000_000  # 1 億
TABLE = 'big_amount_cases'
WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.bac_work')
DONE = os.path.join(WORK, '.bac_done')
os.makedirs(WORK, exist_ok=True)


def done_set():
    if not os.path.exists(DONE):
        return set()
    return set(io.open(DONE, encoding='utf-8').read().split())


def mark_done(ym):
    with io.open(DONE, 'a', encoding='utf-8') as f:
        f.write(ym + '\n')


def parse_big_cases(ext_dir):
    """月包 → [(jid, k4, 裁判月, amount)]，僅 amount >= 1 億"""
    out = []
    for ft in FILE_TYPES:
        for path in glob.glob(os.path.join(ext_dir, '**', f'*.{ft}.txt'), recursive=True):
            try:
                lines = io.open(path, encoding='utf-8-sig').read().splitlines()
            except UnicodeDecodeError:
                lines = io.open(path, encoding='cp950', errors='replace').read().splitlines()
            except OSError:
                continue
            for line in lines:
                if not line.startswith('0!'):
                    continue
                c = line.split('!')
                if len(c) < 30:
                    continue
                try:
                    amount = float(c[c.index('新台幣') + 1])
                except (ValueError, IndexError):
                    continue
                if amount < THRESHOLD:
                    continue
                jid = next((f.strip() for f in reversed(c) if JID_RE.match(f.strip())), None)
                if jid:
                    out.append((jid, key4(jid), jid.split(',')[4][:6], amount))
    return out


_CL = {}


def load_clients_detail(ym):
    """clients 快取 → {k4: {court, cat, title, lawyers: {name: {camp, parties}}}}"""
    if ym in _CL:
        return _CL[ym]
    while len(_CL) > 6:
        _CL.pop(next(iter(_CL)))
    path = os.path.join(JW_DIR, f'{ym}_clients.jsonl.gz')
    if not os.path.exists(path):
        _CL[ym] = None
        return None
    out = {}
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        for line in f:
            r = json.loads(line)
            k = key4(r['jid'])
            d = out.setdefault(k, {'court': r.get('court'), 'cat': r.get('cat'),
                                   'title': r.get('title'), 'lawyers': {}})
            L = d['lawyers'].setdefault(r['lawyer'], {'camp': r.get('camp'), 'parties': []})
            for p in (r.get('parties') or []):
                p = (p or '').strip()
                if p and p != '00' and p not in L['parties']:
                    L['parties'].append(p)
    _CL[ym] = out
    return out


def run_month(ym, fileset_id):
    print(f'=== {ym} (fileSetId {fileset_id}) ===', flush=True)
    arc = os.path.join(WORK, f'{ym}.7z')
    ext = os.path.join(WORK, ym)
    r = requests.get(f'{OPENDATA}/api/FilesetLists/{fileset_id}/file', timeout=600, verify=False)
    r.raise_for_status()
    with open(arc, 'wb') as f:
        f.write(r.content)
    if os.path.isdir(ext):
        shutil.rmtree(ext)
    subprocess.run([SEVENZ, 'x', '-y', arc, f'-o{ext}'], check=True, capture_output=True)

    big = parse_big_cases(ext)
    rows = []
    for jid, k4, jym, amount in big:
        cl = load_clients_detail(jym)
        info = (cl or {}).get(k4) if cl else None
        lvl = 2 if k4[0].startswith(APPEAL2_PREFIXES) else \
              3 if k4[0].startswith(APPEAL3_PREFIXES) else 1
        detail = []
        names = []
        if info:
            for nm, d in info['lawyers'].items():
                names.append(nm)
                detail.append({'name': nm, 'camp': d['camp'], 'parties': d['parties'][:8]})
        rows.append({
            'jid': jid, 'ym': ym,
            'court': (info or {}).get('court'), 'cat': (info or {}).get('cat'),
            'title': (info or {}).get('title'),
            'amount': int(round(amount)), 'appeal_level': lvl,
            'lawyer_names': names, 'detail': detail,
        })

    # 冪等：先刪該終結月再插；同一 jid 若跨月重複，以後插者為準（先刪 jid 衝突列）
    requests.delete(f'{SUPABASE_URL}/rest/v1/{TABLE}?ym=eq.{ym}',
                    headers=HEADERS_SB, timeout=60).raise_for_status()
    if rows:
        jids = ','.join('"%s"' % r['jid'] for r in rows)
        requests.delete(f'{SUPABASE_URL}/rest/v1/{TABLE}?jid=in.({requests.utils.quote(jids)})',
                        headers=HEADERS_SB, timeout=60)
        resp = requests.post(f'{SUPABASE_URL}/rest/v1/{TABLE}', headers={
            **HEADERS_SB, 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates',
        }, json=rows, timeout=120)
        resp.raise_for_status()
    joined = sum(1 for r in rows if r['lawyer_names'])
    print(f'  1億+ 案 {len(rows)} 件（有律師紀錄 {joined}）', flush=True)

    os.remove(arc)
    shutil.rmtree(ext, ignore_errors=True)
    return len(rows)


def main():
    mode = sys.argv[1]
    ds = list_datasets()
    if mode == 'run':
        ym = sys.argv[2]
        run_month(ym, ds[ym])
        mark_done(ym)
        return
    lo, hi = sys.argv[2], sys.argv[3]
    months = sorted([ym for ym in ds if lo <= ym <= hi], reverse=True)  # 由新往舊
    done = done_set()
    total = 0
    for ym in months:
        if ym in done:
            print(f'skip {ym}（已完成）', flush=True)
            continue
        try:
            total += run_month(ym, ds[ym])
            mark_done(ym)
        except Exception as e:
            print(f'  ❌ {ym} 失敗：{type(e).__name__} {e}', flush=True)
    print(f'DONE，累計 {total} 件', flush=True)


if __name__ == '__main__':
    import urllib3
    urllib3.disable_warnings()
    main()
