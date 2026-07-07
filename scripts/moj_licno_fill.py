"""
指定證號補爬 — 補齊「證號遍歷漏抓」的律師明細

背景：判決書比對找出「有實際出庭、但 MOJ 名冊查無」的活躍律師（_missing_lawyers.csv）。
法務部「姓名查詢」綁 captcha 無法自動化，故證號需人工上 lawyerbc.moj.gov.tw 查填；
但「證號單查」端點 /cert/lyinfosd/{證號} 免 captcha，本工具讀填好的證號逐一補進 moj_lawyers。

用法:
  python moj_licno_fill.py                       # 讀 ../＿missing_lawyers.csv 的「證號」欄
  python moj_licno_fill.py path/to/list.csv      # 指定 CSV（需有「姓名」「證號」欄）
  python moj_licno_fill.py --lics 108臺檢證字第00543號 109臺檢證字第01234號

CSV 格式：需含欄位「姓名」與「證號(請填)」（或「證號」）。證號可填完整
「108臺檢證字第00543號」，或簡寫「108-543」「108 543」自動補成標準格式。
補入時會比對 API 回傳姓名與 CSV 姓名，不符會警告（仍補入，供人工複核）。
"""
import os
import re
import sys
import csv
import time

# 復用證號遍歷爬蟲的 API 查詢／轉檔／上傳（同目錄）
from moj_licno_scan import query_lic, to_lawyer_record, upload_batch

DEFAULT_CSV = os.path.join(os.path.dirname(__file__), '..', '_missing_lawyers.csv')


def normalize_licno(s):
    """寬鬆解析證號：完整格式原樣傳；「108-543」「(108) 543」→ 標準臺檢證字格式"""
    s = (s or '').strip().replace('　', '')
    if not s:
        return None
    if any(k in s for k in ('臺檢證字', '臺證字', '臺檢補證字', '台檢證字')):
        return s.replace('台', '臺')
    m = re.match(r'^\(?(\d{2,3})\)?[\s\-,、]+第?(\d+)號?$', s)
    if m:
        return f'{int(m.group(1))}臺檢證字第{int(m.group(2)):05d}號'
    return s  # 交給 API 判斷（可能是補證/早年格式）


def load_items(args):
    """回傳 [(lic_no, expect_name), ...]"""
    if args and args[0] == '--lics':
        return [(normalize_licno(x), '') for x in args[1:] if normalize_licno(x)]
    path = args[0] if args else DEFAULT_CSV
    items = []
    with open(path, encoding='utf-8-sig') as f:
        for row in csv.DictReader(f):
            raw = (row.get('證號(請填)') or row.get('證號') or '').strip()
            lic = normalize_licno(raw)
            if lic:
                items.append((lic, (row.get('姓名') or '').strip()))
    return items


def main():
    items = load_items(sys.argv[1:])
    if not items:
        print('沒有可補的證號（CSV 的「證號」欄都空白？先人工填入證號再跑）')
        return
    print(f'待補證號 {len(items)} 筆\n')

    found, notfound, mismatch = [], [], []
    batch = []
    for lic, expect in items:
        data = query_lic(lic)
        if not data:
            notfound.append((lic, expect))
            print(f'  ✗ {lic}  查無資料')
            time.sleep(0.1)
            continue
        got = data.get('name', '')
        if expect and got and got != expect:
            mismatch.append((lic, expect, got))
            print(f'  ⚠ {lic} → {got}（CSV 寫 {expect}，不符！仍補入待複核）')
        else:
            print(f'  ✓ {lic} → {got} [{data.get("statedesc")}]')
        batch.append(to_lawyer_record(lic, data))
        found.append((lic, got))
        if len(batch) >= 30:
            upload_batch(batch)
            batch = []
            time.sleep(2)
        time.sleep(0.1)
    if batch:
        upload_batch(batch)

    print('\n=== 完成 ===')
    print(f'補入 {len(found)} 筆、查無 {len(notfound)} 筆、姓名不符 {len(mismatch)} 筆')
    if notfound:
        print('查無的證號（請檢查是否填錯）:')
        for lic, name in notfound[:30]:
            print(f'  {name} {lic}')
    if mismatch:
        print('姓名不符（可能同名或填錯證號，請複核）:')
        for lic, exp, got in mismatch[:30]:
            print(f'  {lic}: CSV={exp} / API={got}')
    print('\n補完後記得跑 refresh_firm_stats_cache 更新前端顯示。')


if __name__ == '__main__':
    import urllib3
    urllib3.disable_warnings()
    main()
