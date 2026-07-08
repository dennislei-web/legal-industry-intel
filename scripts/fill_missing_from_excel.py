# -*- coding: utf-8 -*-
"""一次性：把「判決書有出庭、MOJ 名冊漏抓、已人工查得證號」的律師補進 moj_lawyers。

來源：C:\\Users\\admin\\Desktop\\律師證號查詢結果_20260707_003.xlsx 分頁「律師證號查詢」
      查詢狀態 = 已查得 / 已查得(異體字校正) 的 78 筆。

流程：對每筆用 Excel 原始證號字串（人工在法務部查得的正確可查格式，含括號/台/補零，
      不可正規化否則 API 查不到）呼叫 query_lic，以三元組（年,類型,編號；台→臺、去括號
      補零）比對 moj_lawyers，只補「不在 DB」那批，去重後上傳。
"""
import os, re, sys, time
import openpyxl, requests, urllib3
from dotenv import load_dotenv
from moj_licno_scan import query_lic, to_lawyer_record, upload_batch, SUPABASE_URL, HEADERS_SB

urllib3.disable_warnings()
XLSX = r'C:\Users\admin\Desktop\律師證號查詢結果_20260707_003.xlsx'


def triple(lic):
    """(年, 類型, 編號)；台→臺、去括號空白補零。無法解析回 None。"""
    if not lic:
        return None
    s = str(lic).replace('　', '').replace(' ', '').replace('(', '').replace(')', '').replace('台', '臺')
    m = re.match(r'^(\d{2,3})(臺檢補證字|臺檢證字|臺證字)第(\d+)號?$', s)
    return (int(m.group(1)), m.group(2), int(m.group(3))) if m else None


def load_db_triples():
    out = set()
    start = 0
    while True:
        r = requests.get(f'{SUPABASE_URL}/rest/v1/moj_lawyers?select=lic_no&offset={start}&limit=1000',
                         headers=HEADERS_SB, verify=False, timeout=60)
        data = r.json()
        if not data:
            break
        for d in data:
            t = triple(d.get('lic_no'))
            if t:
                out.add(t)
        if len(data) < 1000:
            break
        start += 1000
    return out


def main():
    wb = openpyxl.load_workbook(XLSX, read_only=True, data_only=True)
    ws = wb['律師證號查詢']
    rows = list(ws.iter_rows(values_only=True))
    ix = {h: i for i, h in enumerate(rows[0])}
    si, li, ni = ix['查詢狀態'], ix['律師證號'], ix['姓名']

    print('載入 DB 三元組...')
    db = load_db_triples()
    print(f'  DB {len(db):,} 個三元組')

    # 篩「已查得」且三元組不在 DB，去重
    seen = set()
    todo = []
    for r in rows[1:]:
        if len(r) <= si:
            continue
        st = r[si]
        if not (st and str(st).startswith('已查得')):
            continue
        lic = r[li]
        t = triple(lic)
        if t is None or t in db or t in seen:
            continue
        seen.add(t)
        todo.append((str(lic).strip(), r[ni]))

    print(f'\n待補（真漏抓、去重後）: {len(todo)} 筆')

    batch, ok, miss = [], [], []
    for lic, exp in todo:
        d = query_lic(lic)          # 用 Excel 原字串查（正確可查格式）
        if not d:
            miss.append((lic, exp))
            print(f'  X 查無 {lic}  ({exp})')
            time.sleep(0.1)
            continue
        got = d.get('name', '')
        rec = to_lawyer_record(lic, d)
        batch.append(rec)
        ok.append((lic, got, exp))
        flag = '' if got == exp else f'  <-判決名={exp}(更名/異體，仍補入)'
        print(f'  V {lic} -> {got} [{d.get("statedesc")}]{flag}')
        if len(batch) >= 30:
            upload_batch(batch)
            batch = []
            time.sleep(2)
        time.sleep(0.1)
    if batch:
        upload_batch(batch)

    print(f'\n=== 完成 ===  補入 {len(ok)} 筆、查無 {len(miss)} 筆')
    if miss:
        print('查無明細:')
        for lic, exp in miss:
            print(f'  {lic}  {exp}')


if __name__ == '__main__':
    main()
