# -*- coding: utf-8 -*-
"""
裁判書 → 合議庭共署 pair（judge_copanel_pairs）

目的：法官「共署指紋」。同名不同人的同事圈幾乎不相交，
用 (法官A, 法官B, 法院, 月) 聚合可把同一名字的歷史署名裂成不同軌跡，
仲裁 judge_changes 的同名誤判與「查無遷調」疑難 case（memory: project-judge-transfers）。

重用 judgment_stats.py 的 download / extract_judges / normalize_court。
RAR 已全清（僅存 agg.json，無逐篇 panel 資訊）→ 每月需重新下載月包，
逐月「下載→解壓→抽取→上傳→清理（含 RAR）」控制磁碟。

用法:
  python jy_copanel.py run 202504            # 單月（下載→解析→上傳→清理）
  python jy_copanel.py backfill 202001 202604  # 區間（跳過已上傳月份）
"""
import os
import sys
import json
import time
import shutil
import subprocess
from collections import defaultdict

import requests

import judgment_stats as js

sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

COPANEL_MAX_PANEL = 8   # 單篇署名超過此數視為抽取雜訊，跳過（正常合議庭 3-5 人）


def parse_copanel(yyyymm):
    """解壓後逐篇抽合議庭組合 → {yyyymm}_copanel.json"""
    out_path = os.path.join(js.WORK_DIR, f'{yyyymm}_copanel.json')
    if os.path.exists(out_path):
        print(f'  {yyyymm}_copanel.json 已存在，跳過解析')
        return out_path
    rar_path = os.path.join(js.WORK_DIR, f'{yyyymm}.rar')
    extract_dir = os.path.join(js.WORK_DIR, yyyymm)
    if not os.path.isdir(extract_dir):
        print(f'  解壓 {yyyymm}.rar ...')
        r = subprocess.run([js.SEVENZ, 'x', rar_path, f'-o{extract_dir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 解壓失敗: {r.stderr[:500]}')

    pairs = defaultdict(int)   # (a, b, court) canonical a<b
    n_files = n_panel = 0
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
            mc = js.RE_COURT.search(jfull[:60].strip())
            court = js.normalize_court(mc.group(1)) if mc else '未知法院'
            if court == '未知法院':
                continue
            judges = js.extract_judges(jfull)
            if len(judges) < 2 or len(judges) > COPANEL_MAX_PANEL:
                continue
            n_panel += 1
            for i in range(len(judges)):
                for j in range(i + 1, len(judges)):
                    a, b = sorted((judges[i], judges[j]))
                    pairs[(a, b, court)] += 1
            if n_files % 50000 == 0:
                print(f'  ...{n_files} 檔，{(time.time()-t0)/60:.1f} 分', flush=True)

    rows = [{'judge_a': k[0], 'judge_b': k[1], 'court_name': k[2],
             'yyyymm': yyyymm, 'case_count': v} for k, v in pairs.items()]
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False)
    print(f'  {yyyymm}: {n_files} 檔 / {n_panel} 篇合議 / {len(rows)} pair，'
          f'{(time.time()-t0)/60:.1f} 分鐘')
    return out_path


def month_uploaded(yyyymm):
    r = requests.get(f'{js.SUPABASE_URL}/rest/v1/judge_copanel_pairs',
                     params={'yyyymm': f'eq.{yyyymm}', 'select': 'yyyymm', 'limit': 1},
                     headers=js.HEADERS_SB, timeout=60, verify=False)
    return r.status_code == 200 and len(r.json()) > 0


def upload(yyyymm):
    out_path = os.path.join(js.WORK_DIR, f'{yyyymm}_copanel.json')
    with open(out_path, encoding='utf-8') as f:
        rows = json.load(f)
    # 冪等：先刪該月再插
    requests.delete(f'{js.SUPABASE_URL}/rest/v1/judge_copanel_pairs',
                    params={'yyyymm': f'eq.{yyyymm}'},
                    headers=js.HEADERS_SB, timeout=300, verify=False).raise_for_status()
    for i in range(0, len(rows), 3000):
        r = requests.post(f'{js.SUPABASE_URL}/rest/v1/judge_copanel_pairs',
                          json=rows[i:i+3000],
                          headers={**js.HEADERS_SB, 'Content-Type': 'application/json'},
                          timeout=300, verify=False)
        if r.status_code >= 300:
            raise RuntimeError(f'upload {yyyymm} HTTP {r.status_code}: {r.text[:300]}')
    print(f'  {yyyymm}: 上傳 {len(rows)} pair')


def run_month(yyyymm, purge_rar=True):
    js.download(yyyymm)
    parse_copanel(yyyymm)
    upload(yyyymm)
    # 清理解壓目錄 + RAR（copanel json 保留，冪等重傳用）
    d = os.path.join(js.WORK_DIR, yyyymm)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    rar = os.path.join(js.WORK_DIR, f'{yyyymm}.rar')
    if purge_rar and os.path.exists(rar):
        os.remove(rar)


def backfill(start, end):
    months = list(js.month_range(start, end))
    t0 = time.time()
    done = 0
    for ym in months:
        if month_uploaded(ym):
            print(f'{ym}: 已上傳，跳過')
            done += 1
            continue
        print(f'== {ym} ({done+1}/{len(months)}) ==')
        run_month(ym)
        done += 1
        elapsed = (time.time() - t0) / 60
        print(f'  進度 {done}/{len(months)}，累計 {elapsed:.0f} 分', flush=True)
    print('backfill 完成')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'run':
        run_month(sys.argv[2])
    elif cmd == 'backfill':
        backfill(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
