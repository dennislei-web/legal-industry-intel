"""
僅Lawsnote 律師 → lawyerbc 證號補掃（mig 091 歸戶配套）

對「僅Lawsnote 且有 cert_number、但 DB 內證號/舊名比對未命中」的律師，
逐一以證號打 /api/cert/lyinfosd 免 captcha 端點確認：
  * 查得 → MOJ 名冊有此人（licno_scan 漏抓：補證字/早年/格式變體）
           → 插入 moj_lawyers；姓名用字不同者由 lawsnote_alias_backfill() 歸戶
  * 查無 → 確認已從名冊移除（註銷/停止登錄）→ 留在僅Lawsnote，
           近 5 年無官方案件者由 is_historical 自動標歷史名冊

證號格式變體（lyinfosd 極挑剔）：重組為「{年}臺檢證字第{5位補零}號」優先，
再退原字串／不補零／4位補零；台⇄臺互換由 query_lic 內建處理（≦95 年）。

用法:
  python lawsnote_moj_backfill.py            # 全量
  python lawsnote_moj_backfill.py --limit 20 # 煙霧測試
"""
import os
import re
import sys
import time
import urllib.parse

import requests

from moj_licno_scan import (
    HEADERS_SB, SUPABASE_URL, query_lic, to_lawyer_record, upload_batch,
)

if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')


def fetch_targets():
    """僅Lawsnote 且有證號者（mig 091 套用後的口徑，已排除 DB 內可比對命中者）"""
    out = []
    frm = 0
    sel = 'name,cert_number'
    src = urllib.parse.quote('僅Lawsnote')
    while True:
        r = requests.get(
            f'{SUPABASE_URL}/rest/v1/lawyers_with_stats'
            f'?select={sel}&data_source=eq.{src}&cert_number=not.is.null'
            f'&order=name&offset={frm}&limit=1000',
            headers=HEADERS_SB, verify=False, timeout=60)
        r.raise_for_status()
        data = r.json()
        out.extend(data)
        if len(data) < 1000:
            break
        frm += 1000
    return out


def lic_variants(cert):
    """產生查詢用證號變體（依命中機率排序、去重）"""
    s = re.sub(r'[()（）\s]', '', cert)
    variants = []
    m = re.match(r'^(\d+)?[臺台]檢(補)?證字第(\d+)號$', s)
    if m:
        year, sup, num = m.group(1) or '', m.group(2) or '', int(m.group(3))
        kind = f'臺檢{sup}證字'
        for fmt in (f'{num:05d}', str(num), f'{num:04d}'):
            variants.append(f'{year}{kind}第{fmt}號')
    else:
        # 非標準格式（如「臺證字第0915號」）：原樣 + 去補零 + 5位補零
        variants.append(s.replace('台', '臺'))
        m2 = re.match(r'^(.*第)0*(\d+)(號)$', s.replace('台', '臺'))
        if m2:
            head, num, tail = m2.group(1), int(m2.group(2)), m2.group(3)
            variants += [f'{head}{num}{tail}', f'{head}{num:05d}{tail}']
    variants.append(s)  # 最後保底：原字串
    seen, out = set(), []
    for v in variants:
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out


def main():
    limit = None
    if '--limit' in sys.argv:
        limit = int(sys.argv[sys.argv.index('--limit') + 1])

    targets = fetch_targets()
    if limit:
        targets = targets[:limit]
    print(f'目標：{len(targets)} 位僅Lawsnote 律師（有證號）', flush=True)

    found_records = []   # 待 upsert 進 moj_lawyers
    found_pairs = []     # (lawsnote_name, api_name, lic_no)
    gone = 0
    t0 = time.time()

    for i, t in enumerate(targets, 1):
        name, cert = t['name'], t['cert_number']
        data, hit_lic = None, None
        for v in lic_variants(cert):
            data = query_lic(v)
            if data:
                hit_lic = v
                break
            time.sleep(0.05)
        if data:
            found_records.append(to_lawyer_record(hit_lic, data))
            found_pairs.append((name, data.get('name', ''), hit_lic))
            mark = '=' if data.get('name') == name else '≠'
            print(f'  ✓ [{i}/{len(targets)}] {name} → API:{data.get("name")} ({mark}) {hit_lic}', flush=True)
            if len(found_records) >= 30:
                upload_batch(found_records)
                found_records = []
        else:
            gone += 1
        if i % 25 == 0:
            el = time.time() - t0
            eta = el / i * (len(targets) - i)
            print(f'  [{i}/{len(targets)}] 查得 {len(found_pairs)}, 查無 {gone}, '
                  f'已跑 {el/60:.1f} 分, 預估剩 {eta/60:.1f} 分', flush=True)
        time.sleep(0.1)

    if found_records:
        upload_batch(found_records)

    print(f'\n=== 完成（{(time.time()-t0)/60:.1f} 分） ===')
    print(f'查得（補進 moj_lawyers）: {len(found_pairs)}')
    print(f'查無（確認除名/停止登錄）: {gone}')
    if found_pairs:
        print('\n查得清單（lawsnote 名 → MOJ 名）:')
        for ls, mj, lic in found_pairs:
            print(f'  {ls} → {mj}  {lic}')
        print('\n⚠ 請再跑 SELECT * FROM lawsnote_alias_backfill(); 完成用字不同者的歸戶')


if __name__ == '__main__':
    main()
