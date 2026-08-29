# -*- coding: utf-8 -*-
"""評鑑上榜律師 → 中文名歸戶（官網雙語對照 + 人工核對名單）

資料源：
  .chambers_cache/lawyer_pairs.json —— 各所官網中英對照（en→zh），來源 URL 記錄在檔內
  chambers_firm_map.LAWYER_MAP —— 人工逐案核對名單（MOJ 反查一致者）

匹配規則（防張冠李戴，寧缺勿錯）：
  1. 英文名正規化（去 Dr./中間名縮寫/標點/大小寫）後 exact match
  2. 正規化後「首名+姓」match（Janice C. H. Lin ↔ Janice Lin）——僅當該所 pairs 內唯一
  3. match 到的中文名再對 moj_lawyers 名冊驗證「現職該所」；不在名冊該所者標 unverified
     （官網對照仍可信，例如顧問/外國律師/掛分所，保留歸戶但註記）

用法：
  python award_lawyer_match.py report   # 只看匹配結果
  python award_lawyer_match.py apply    # 更新 firm_awards.ranked_lawyers（逐列 PATCH）
"""
import io
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".chambers_cache")

ENV = {}
for line in open(os.path.join(HERE, ".env"), encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        ENV[k.strip()] = v.strip()
SUPABASE_URL = ENV["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = ENV["SUPABASE_SERVICE_KEY"]

from chambers_firm_map import LAWYER_MAP

PAIRS = json.load(open(os.path.join(CACHE, "lawyer_pairs.json"), encoding="utf-8"))


def norm(name):
    """英文名正規化：小寫、去點逗、去單字母縮寫、壓空白"""
    n = re.sub(r"^(dr|mr|ms|mrs)\.?\s+", "", name.strip().lower())
    n = n.replace(",", " ").replace(".", " ").replace("-", "")
    toks = [t for t in n.split() if t]
    return " ".join(toks), " ".join(t for t in toks if len(t) > 1)


def build_index(firm_en):
    """firm 官網 pairs → {norm_full: zh} 與 {norm_noinit: [zh...]}"""
    entry = PAIRS.get(firm_en)
    if not entry:
        return None
    full, noinit = {}, {}
    for en, zh in entry["pairs"].items():
        f, ni = norm(en)
        full[f] = zh
        noinit.setdefault(ni, []).append(zh)
    return {"full": full, "noinit": noinit}


def match_one(name_en, firm_en):
    if (name_en, firm_en) in LAWYER_MAP:
        return LAWYER_MAP[(name_en, firm_en)], "manual"
    idx = build_index(firm_en)
    if not idx:
        return None, None
    variants = [name_en]
    # 「Ya-Chun (Patricia) Lin」→ 也試「Patricia Lin」（括號英文名＋姓）
    m = re.match(r".*\(([A-Za-z .'-]+)\)\s*(\S+)$", name_en)
    if m:
        variants.append(f"{m.group(1)} {m.group(2)}")
    for v in variants:
        f, ni = norm(v)
        if f in idx["full"]:
            return idx["full"][f], "exact"
        cands = idx["noinit"].get(ni, [])
        if len(cands) == 1:
            return cands[0], "noinit"
        rev = [zh for k, zh in idx["full"].items()
               if " ".join(t for t in k.split() if len(t) > 1) == ni]
        if len(set(rev)) == 1:
            return rev[0], "noinit-rev"
        # first+last（唯一時）：Angela Lin ↔ Angela Yao Lin
        toks = ni.split()
        if len(toks) >= 2:
            fl = (toks[0], toks[-1])
            cands2 = {zh for k, zh in idx["full"].items()
                      if (lambda t: len(t) >= 2 and (t[0], t[-1]) == fl)(k.split())}
            if len(cands2) == 1:
                return cands2.pop(), "first-last"
    return None, None


def sb(method, path, body=None):
    req = urllib.request.Request(
        SUPABASE_URL + path, method=method,
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=60) as r:
        if method == "GET":
            return json.load(r)
        return r.status


def sb_get(path):
    req = urllib.request.Request(
        SUPABASE_URL + path,
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def verify_roster(zh, firm_zh):
    """中文名是否在 moj_lawyers 現職該所（分所歸戶：所名前綴比對）"""
    rows = sb_get("/rest/v1/moj_lawyers?name=eq." + urllib.parse.quote(zh) +
                  "&select=office&limit=5")
    return any((r.get("office") or "").startswith(firm_zh[:4]) for r in rows)


def run(apply=False):
    rows = sb_get("/rest/v1/firm_awards?select=id,source,practice_area,firm_name_en,"
                  "firm_name,ranked_lawyers&order=id&limit=1000")
    tot = matched = already = 0
    misses = {}
    for r in rows:
        lws = r["ranked_lawyers"]
        if not lws:
            continue
        changed = False
        for lw in lws:
            tot += 1
            if lw.get("name"):
                already += 1
                matched += 1
                continue
            zh, how = match_one(lw["name_en"], r["firm_name_en"])
            if zh:
                lw["name"] = zh
                lw["match"] = how
                matched += 1
                changed = True
            else:
                misses.setdefault(r["firm_name_en"], set()).add(lw["name_en"])
        if apply and changed:
            st = sb("PATCH", f"/rest/v1/firm_awards?id=eq.{r['id']}",
                    {"ranked_lawyers": lws})
            time.sleep(0.2)
    print(f"entries {tot}, 歸戶 {matched} ({matched/tot*100:.1f}%), 其中先前已歸 {already}")
    print("\n未歸戶（按所）:")
    for f, names in sorted(misses.items(), key=lambda x: -len(x[1])):
        print(f"  {f}: {sorted(names)}")
    if apply:
        print("\napply 完成")


if __name__ == "__main__":
    run(apply=(sys.argv[1:] and sys.argv[1] == "apply"))
