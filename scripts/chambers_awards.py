# -*- coding: utf-8 -*-
"""Chambers 評鑑爬蟲（國際法律評鑑 pilot，mig 175）

抓 chambers.com Greater China Region「Taiwan Jurisdiction」各 practice area 的
ranked firms（Band）與 ranked lawyers，寫入 firm_awards 表。

資料源：頁面為 Angular SSR，完整結構化資料在 <script id="ng-state"> 的
transfer-state JSON（key 是 hash 不固定，靠內容 shape 判別）：
  - guide 頁（/legal-guide/greater-china-region-116）: locations→practiceAreas 清單
  - ranking 頁（/legal-rankings/{slug}-116:{paId}:207:1）:
      Departments（categories→Band→organisations）
      Lawyers（categories→Senior Statespeople/Eminent/Band N/Up and Coming→individuals）

口徑註記（存 DB 前端都要帶）：質性聲譽排名（submission＋客戶訪談），一年一更、
無金額、有 submission 偏差（缺席≠不強）、台灣覆蓋僅涉外大所 ~20-40 家。

用法：
  python chambers_awards.py scrape            # 抓 10 個 practice area → cache JSON
  python chambers_awards.py report            # 印出所名/歸戶狀態（不動 DB）
  python chambers_awards.py upload            # cache → firm_awards（DELETE 該 source+year 再 INSERT）
  python chambers_awards.py run               # scrape + upload
"""
import io
import json
import os
import re
import sys
import time
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".chambers_cache")
os.makedirs(CACHE, exist_ok=True)

# .env
ENV = {}
env_path = os.path.join(HERE, ".env")
if os.path.exists(env_path):
    for line in open(env_path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            ENV[k.strip()] = v.strip()
SUPABASE_URL = ENV.get("SUPABASE_URL", "").rstrip("/")
SERVICE_KEY = ENV.get("SUPABASE_SERVICE_KEY", "")

BASE = "https://chambers.com"
GUIDE_URL = BASE + "/legal-guide/greater-china-region-116"
TAIWAN_LOCATION_ID = 207
SOURCE = "chambers"
PUBLICATION = "Greater China Region"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")

from chambers_firm_map import FIRM_MAP, LAWYER_MAP  # 歸戶對照（歸不了戶=None）

# 律師分級排序（rankType → 排序值；越小越高）
RANK_ORDER = {"S": 0, "EP": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "U": 90, "A": 95}


def fetch(url, retries=3):
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:
            print(f"  fetch retry {i+1}: {e}")
            time.sleep(3 * (i + 1))
    raise RuntimeError(f"fetch failed: {url}")


def ng_state(html):
    m = re.search(r'<script id="ng-state" type="application/json">(.*?)</script>', html, re.S)
    if not m:
        raise RuntimeError("ng-state not found（頁面版式可能已改）")
    return json.loads(m.group(1))


def taiwan_practice_areas():
    """guide 頁 → Taiwan 的 practice area 清單 [{id,name,urlPath}]"""
    data = ng_state(fetch(GUIDE_URL))
    for v in data.values():
        b = v.get("b") if isinstance(v, dict) else None
        if isinstance(b, dict) and "locations" in b and b.get("groupId") == 116:
            for loc in b["locations"]:
                if loc["id"] == TAIWAN_LOCATION_ID:
                    return loc["practiceAreas"]
    raise RuntimeError("guide ng-state 找不到 Taiwan locations（版式改？）")


def parse_ranking_page(html):
    """ranking 頁 → {year, departments:[...], lawyers:[...]}"""
    data = ng_state(html)
    out = {"year": None, "departments": [], "lawyers": []}
    for v in data.values():
        b = v.get("b") if isinstance(v, dict) else None
        if isinstance(b, dict) and b.get("description") == "Departments":
            for cat in b.get("categories", []):
                for org in cat.get("organisations", []):
                    out["departments"].append({
                        "band": cat["description"],
                        "rank_type": cat.get("rankType"),
                        "org_id": org.get("organisationId"),
                        "name_en": org.get("displayName") or org.get("organisationName"),
                        "ranked_years": org.get("rankedYearsCount"),
                        "year": org.get("publicationYear"),
                    })
                    out["year"] = out["year"] or org.get("publicationYear")
        elif isinstance(b, list) and b and isinstance(b[0], dict) and b[0].get("description") == "Lawyers":
            for grp in b:
                for cat in grp.get("categories", []):
                    for ind in cat.get("individuals", []):
                        out["lawyers"].append({
                            "band": cat["description"],
                            "rank_type": cat.get("rankType"),
                            "name_en": ind.get("displayName"),
                            "firm_en": ind.get("organisationName"),
                            "org_id": ind.get("organisationId"),
                            "is_dept_head": bool(ind.get("isDepartmentHead")),
                            "ranked_years": ind.get("rankedYearsCount"),
                        })
                        out["year"] = out["year"] or ind.get("publicationYear")
    return out


def scrape():
    pas = taiwan_practice_areas()
    print(f"Taiwan practice areas: {len(pas)}")
    result = []
    for pa in pas:
        url = BASE + "/" + pa["urlPath"].lstrip("/")
        print(f"  {pa['name']} ...")
        parsed = parse_ranking_page(fetch(url))
        result.append({"practice_area": pa["name"], "practice_area_id": pa["id"],
                       "url": url, **parsed})
        time.sleep(1.5)
    path = os.path.join(CACHE, "taiwan_2026.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    n_dept = sum(len(r["departments"]) for r in result)
    n_law = sum(len(r["lawyers"]) for r in result)
    print(f"done → {path}（dept rows {n_dept}, lawyer rows {n_law}）")
    return result


def load_cache():
    path = os.path.join(CACHE, "taiwan_2026.json")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def build_rows(result):
    """cache → firm_awards 列（每 firm×practice_area 一列，ranked_lawyers 塞 jsonb）"""
    rows = []
    for pa in result:
        year = pa.get("year") or 2026
        # 該 practice area 的律師按 firm 分桶
        by_firm = {}
        for lw in pa["lawyers"]:
            by_firm.setdefault(lw["firm_en"], []).append({
                "name_en": lw["name_en"],
                "name": LAWYER_MAP.get((lw["name_en"], lw["firm_en"])),  # 中文名（歸不了戶=None）
                "band": lw["band"],
                "rank_order": RANK_ORDER.get(lw["rank_type"], 99),
                "is_dept_head": lw["is_dept_head"], "ranked_years": lw["ranked_years"],
            })
        seen_firms = set()
        for d in pa["departments"]:
            zh = FIRM_MAP.get(d["name_en"])
            rows.append({
                "source": SOURCE, "publication": PUBLICATION, "year": year,
                "practice_area": pa["practice_area"], "practice_area_id": pa["practice_area_id"],
                "firm_name_en": d["name_en"], "firm_name": zh,
                "band": d["band"], "band_rank": int(d["rank_type"]) if d["rank_type"].isdigit() else 99,
                "ranked_years_count": d["ranked_years"], "org_id": d["org_id"],
                "ranked_lawyers": sorted(by_firm.pop(d["name_en"], []), key=lambda x: x["rank_order"]),
                "url": pa["url"],
            })
            seen_firms.add(d["name_en"])
        # 有上榜律師但 firm 本身沒進 band 的（常見：individual-only）→ band='Lawyers only'
        for firm_en, lws in by_firm.items():
            if not firm_en:
                continue
            zh = FIRM_MAP.get(firm_en)
            rows.append({
                "source": SOURCE, "publication": PUBLICATION, "year": year,
                "practice_area": pa["practice_area"], "practice_area_id": pa["practice_area_id"],
                "firm_name_en": firm_en, "firm_name": zh,
                "band": "Lawyers only", "band_rank": 98,
                "ranked_years_count": None, "org_id": None,
                "ranked_lawyers": sorted(lws, key=lambda x: x["rank_order"]),
                "url": pa["url"],
            })
    return rows


def report():
    result = load_cache()
    rows = build_rows(result)
    firms = {}
    for r in rows:
        firms.setdefault(r["firm_name_en"], {"zh": r["firm_name"], "areas": 0, "lawyers": 0})
        firms[r["firm_name_en"]]["areas"] += 1
        firms[r["firm_name_en"]]["lawyers"] += len(r["ranked_lawyers"])
    mapped = sum(1 for f in firms.values() if f["zh"])
    print(f"practice areas: {len(result)}  rows: {len(rows)}  firms: {len(firms)}  歸戶: {mapped}/{len(firms)}")
    for en, f in sorted(firms.items(), key=lambda x: -x[1]["areas"]):
        mark = "✓" if f["zh"] else "✗"
        print(f"  {mark} {en}  →  {f['zh'] or '(未歸戶)'}  [{f['areas']} 領域, {f['lawyers']} 律師]")
    return rows


def sb_req(method, path, body=None):
    req = urllib.request.Request(
        SUPABASE_URL + path, method=method,
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status


def upload():
    rows = build_rows(load_cache())
    years = sorted({r["year"] for r in rows})
    for y in years:
        st = sb_req("DELETE", f"/rest/v1/firm_awards?source=eq.{SOURCE}&year=eq.{y}")
        print(f"DELETE source={SOURCE} year={y}: {st}")
    for i in range(0, len(rows), 50):
        st = sb_req("POST", "/rest/v1/firm_awards", rows[i:i+50])
        print(f"INSERT {i}..{i+len(rows[i:i+50])}: {st}")
        time.sleep(1)
    print(f"uploaded {len(rows)} rows")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "report"
    if mode == "scrape":
        scrape()
    elif mode == "report":
        report()
    elif mode == "upload":
        upload()
    elif mode == "run":
        scrape()
        upload()
    else:
        print(__doc__)
