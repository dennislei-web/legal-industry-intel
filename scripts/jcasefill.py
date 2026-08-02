# -*- coding: utf-8 -*-
"""Phase 2 細分專庭：字別（JCASE）回填 → judge_month_jcase（mig 131）。

設計：
- DB 存全字別原始計數（法官×法院×月×字別），分類映射查詢時才 JOIN
  jcase_category_map——之後加新類別零重跑。
- 逐案快取存本地 .judgment_work/{ym}_jcase_cases.jsonl.gz
  （{k: 法院|年|字別|號, j: [法官], lw: [律師], c: 案類, d: 判決/裁定/其他}），
  未來律師端/配對端分析直接讀快取，免重下 RAR。
- 快取存在時跳過下載直接聚合上傳（冪等 resume）；月包下載失敗記 log 續跑下一月。
- 只寫 judge_month_jcase，不碰 judge/lawyer_month_stats 與 pair 表（mig 123 教訓）。

用法：
  python jcasefill.py 202001 202606      # 回填區間（含端點）
  python jcasefill.py 202604 202604      # 單月
"""
import sys
import os
import json
import gzip
import time
import shutil
import subprocess
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from judgment_stats import (  # noqa: E402
    download, month_range, WORK_DIR, SEVENZ, SUPABASE_URL, HEADERS_SB,
    RE_COURT, normalize_court, doctype_of, classify, extract_judges, extract_lawyers,
    _upload_rows,
)
import requests  # noqa: E402


def cache_path(ym):
    return os.path.join(WORK_DIR, f'{ym}_jcase_cases.jsonl.gz')


def build_cache(ym):
    """下載＋解壓＋逐案掃描 → 逐案快取。回傳快取路徑。"""
    rar_path = os.path.join(WORK_DIR, f'{ym}.rar')
    extract_dir = os.path.join(WORK_DIR, ym)
    if not os.path.isdir(extract_dir):
        if not os.path.exists(rar_path):
            download(ym)
        print(f'  解壓 {ym}.rar ...')
        r = subprocess.run([SEVENZ, 'x', rar_path, f'-o{extract_dir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'7z 解壓失敗: {r.stderr[:500]}')
    t0 = time.time()
    n = n_ok = 0
    tmp = cache_path(ym) + '.part'
    with gzip.open(tmp, 'wt', encoding='utf-8') as fo:
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
                jcase = (doc.get('JCASE') or '').strip()
                if not jfull or not jcase:
                    continue
                head = jfull[:60]
                mc = RE_COURT.search(head.strip())
                court = normalize_court(mc.group(1)) if mc else '未知法院'
                judges = extract_judges(jfull)
                lawyers = extract_lawyers(jfull)
                rec = {'k': f"{court}|{doc.get('JYEAR') or ''}|{jcase}|{doc.get('JNO') or ''}",
                       'j': judges, 'lw': lawyers,
                       'c': classify(head, jcase), 'd': doctype_of(head)}
                fo.write(json.dumps(rec, ensure_ascii=False) + '\n')
                n_ok += 1
    os.replace(tmp, cache_path(ym))
    print(f'  逐案快取完成：{n_ok}/{n} 檔、{(time.time() - t0) / 60:.1f} 分鐘')
    # 磁碟清理：rar 與解壓目錄都刪（快取已足以重建聚合）
    shutil.rmtree(extract_dir, ignore_errors=True)
    if os.path.exists(rar_path):
        os.remove(rar_path)
    return cache_path(ym)


def aggregate_and_upload(ym):
    """讀逐案快取 → 兩種口徑上傳（先刪該月再插，冪等）：
    judge_month_jcase＝法官人次（合議庭一案計多法官）、court_month_jcase＝案件數（每案一次，
    含未抽到法官的案件）。"""
    agg = defaultdict(int)
    cagg = defaultdict(int)
    with gzip.open(cache_path(ym), 'rt', encoding='utf-8') as f:
        for ln in f:
            rec = json.loads(ln)
            court = rec['k'].split('|')[0]
            jcase = rec['k'].split('|')[2]
            cagg[(court, jcase)] += 1
            for name in rec.get('j') or []:
                agg[(name, court, jcase)] += 1
    rows = [{'name': k[0], 'court_name': k[1], 'yyyymm': ym, 'jcase': k[2], 'n': v}
            for k, v in agg.items()]
    _upload_rows('judge_month_jcase', ym, rows)
    crows = [{'court_name': k[0], 'yyyymm': ym, 'jcase': k[1], 'n': v}
             for k, v in cagg.items()]
    _upload_rows('court_month_jcase', ym, crows)


def run_month(ym):
    marker = os.path.join(WORK_DIR, f'{ym}.jcase_done')
    if os.path.exists(marker):
        print(f'=== {ym} 已完成（marker），跳過 ===')
        return True
    print(f'=== {ym} ===')
    t0 = time.time()
    try:
        if not os.path.exists(cache_path(ym)):
            build_cache(ym)
        else:
            print('  逐案快取已存在，直接聚合')
        aggregate_and_upload(ym)
        open(marker, 'w').close()
        print(f'=== {ym} 完成，{(time.time() - t0) / 60:.1f} 分鐘 ===')
        return True
    except Exception as e:
        print(f'!!! {ym} 失敗：{e}')
        return False


def main():
    start, end = sys.argv[1], sys.argv[2]
    failed = []
    for ym in month_range(start, end):
        if not run_month(ym):
            failed.append(ym)
        time.sleep(2)
    print(f'\n全部結束。失敗月份：{failed or "無"}')
    if failed:
        sys.exit(2)


if __name__ == '__main__':
    main()
