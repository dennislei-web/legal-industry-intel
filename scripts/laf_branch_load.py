# -*- coding: utf-8 -*-
"""法扶「全國及分會扶助律師接案數」PDF → public/data/laf_branch_load.json

資料源：https://www.laf.org.tw/fotherReport/5 （?yearly=西元年 篩選）
每年一份 PDF，每頁一個單位（全國 + 22 分會 + 原民中心），
每頁 3 張圖（計件案件 / 消債案件 / 陪偵後偵查中辯護），
每張圖為律師依接案數均分四組（前25%/26-50%/51-75%/76-100%）的 最大/中位/最小 值。

用法：python scripts/laf_branch_load.py            # 抓 2020(109)–最新，全部重建
      python scripts/laf_branch_load.py --years 2025,2024
"""
import io
import json
import re
import ssl
import sys
import unicodedata
import urllib.request
from pathlib import Path

from pypdf import PdfReader

BASE = "https://www.laf.org.tw/fotherReport/5"
OUT = Path(__file__).resolve().parent.parent / "public" / "data" / "laf_branch_load.json"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
CTX = ssl.create_default_context()

CASE_TYPES = ["計件案件", "消債案件", "陪偵後偵查中辯護"]
# 頁面標題格式：「台北 - 114年 接案數」；罕用相容字（⾼ ⼠ ⽵ ⾦ ⾨ ⾺ ⺠…）先 NFKC
TITLE_RE = re.compile(r"^(.{2,6}?)-(\d{2,3})年接案數")


def fetch(url: str) -> bytes:
    # href 可能含未編碼中文（檔名），逐段 quote
    url = urllib.parse.quote(url, safe=":/?&=%")
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
        return r.read()


def find_pdf_url(year: int) -> str | None:
    html = fetch(f"{BASE}?yearly={year}").decode("utf-8", "ignore")
    m = re.search(r'href="(https://www\.laf\.org\.tw/upload/[^"]+\.pdf)"', html)
    return m.group(1) if m else None


def parse_pdf(data: bytes) -> dict:
    """回傳 {單位名: {案件類型: [[min,med,max]×4組]}}

    pypdf 抽出的中文字間有空白（數字 token 靠空白分隔，不可移除），
    故標籤用「字元間可夾空白」的 regex 定位，數字從保留空白的原文取。"""
    reader = PdfReader(io.BytesIO(data))
    result = {}
    for page in reader.pages:
        text = unicodedata.normalize("NFKC", page.extract_text() or "")
        tm = TITLE_RE.search(text.replace(" ", "").replace("\n", ""))
        if not tm:
            continue
        unit = tm.group(1).replace("⺠", "民")  # NFKC 沒涵蓋的 CJK 部首字
        pos, unit_data, ok = 0, {}, True
        for ct in CASE_TYPES:
            label_re = re.compile(r"\s*".join(map(re.escape, ct)))
            m = label_re.search(text, pos)
            if not m:
                ok = False
                break
            seg = text[pos : m.start()]
            nums = re.findall(r"\d+", seg)
            # 四分位區間標籤（a.前25%…d.76%~100%）的數字一定在資料值之前，
            # 取最後一組相鄰「76,100」之後的數字：12 個=有資料、0 個=該類型無資料（空圖）
            tail = None
            for i in range(len(nums) - 1, 0, -1):
                if nums[i] == "100" and nums[i - 1] == "76":
                    tail = nums[i + 1 :]
                    break
            if tail is None:  # 找不到標籤序列，退回舊邏輯
                tail = nums[-12:] if len(nums) >= 12 else []
            if len(tail) == 0:
                unit_data[ct] = None  # 該分會此類型無案件
            elif len(tail) >= 12:
                vals = [int(x) for x in tail[-12:]]
                # 每 3 個一組（一組=一個四分位區間），組內排序成 [min, med, max]
                unit_data[ct] = [sorted(vals[i : i + 3]) for i in range(0, 12, 3)]
            else:
                ok = False
                break
            pos = m.end()
        if ok:
            result[unit] = unit_data
    return result


def main():
    years = None
    if len(sys.argv) > 2 and sys.argv[1] == "--years":
        years = [int(y) for y in sys.argv[2].split(",")]
    if years is None:
        # 官網下拉選單列出民國94–114，但改版後多數舊檔尚未重新上架；逐年試抓、無檔自動跳過
        years = list(range(2005, 2027))

    out = {"source": "法律扶助基金會官網「全國及分會扶助律師接案數」統計", "url": BASE, "years": {}}
    if OUT.exists():
        try:
            out = json.loads(OUT.read_text("utf-8"))
        except Exception:
            pass

    for y in years:
        url = find_pdf_url(y)
        if not url:
            print(f"{y}: 無 PDF，跳過")
            continue
        parsed = parse_pdf(fetch(url))
        n_units = len(parsed)
        if n_units < 20:  # 防呆：正常應有 24 單位
            print(f"{y}: 只解析到 {n_units} 單位，格式可能不同，跳過（{url}）")
            continue
        roc = y - 1911
        out["years"][str(roc)] = {"ad": y, "pdf": url, "units": parsed}
        print(f"{y}(民國{roc}): {n_units} 單位 OK")

    OUT.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), "utf-8")
    print(f"寫入 {OUT}（{len(out['years'])} 個年度）")


if __name__ == "__main__":
    main()
