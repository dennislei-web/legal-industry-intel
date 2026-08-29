# -*- coding: utf-8 -*-
"""國際評鑑三源爬蟲：Legal 500 / IFLR1000 / Asialaw（Taiwan），寫入 firm_awards（mig 175）

各源結構（皆 SSR HTML，curl 可抓）：
  - Legal 500（source=legal500，Asia Pacific 2026）：
      /c/taiwan/practice-areas 枚舉 → /c/taiwan/{pa}（firm tiers：sr-only h3 分組）
      ＋ /c/taiwan/{pa}/lawyers（個人卡：name + badge + firm）
  - IFLR1000（source=iflr1000，2026 Edition）：
      https://www.iflr.com/taiwan 單頁全包（.Ranking 區塊×5，RankingTier）
  - Asialaw（source=asialaw，2025 版——站上未標年度，以研究週期推定，2026 版約 9 月發布）：
      /Jurisdiction/Taiwan/Rankings/432 單頁全包（panel×18，tier=Outstanding/
      Highly recommended/Recommended/Notable）；律師另頁未收

所名歸戶：各源英文寫法不同 → FIRM_ALIAS 正規化到 Chambers canonical 名 → FIRM_MAP 中文。
band_rank：Tier N=N；asialaw Outstanding=1/Highly recommended=2/Recommended=3/Notable=4；
iflr Notable=5；Lawyers only=98。

用法：
  python rating_awards.py scrape [legal500|iflr1000|asialaw]   # 預設三源全抓 → cache
  python rating_awards.py report                               # 歸戶狀態＋缺口
  python rating_awards.py upload                               # cache → firm_awards
  python rating_awards.py run                                  # scrape + upload
"""
import html as html_mod
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

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")

from chambers_firm_map import FIRM_MAP, FIRM_ALIAS


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


def unesc(s):
    return html_mod.unescape(s).strip()


def canon(name_en):
    """各源英文所名 → Chambers canonical（查 FIRM_ALIAS，查無回原名）"""
    n = unesc(name_en)
    return FIRM_ALIAS.get(n, n)


# ---------------- Legal 500 ----------------

L500_BASE = "https://www.legal500.com"

def scrape_legal500():
    h = fetch(L500_BASE + "/c/taiwan/practice-areas")
    slugs = sorted(set(re.findall(r'href="/c/taiwan/([a-z0-9-]+)"', h))
                   - {"practice-areas", "directory"})
    print(f"legal500 practice areas: {len(slugs)}")
    out = []
    for slug in slugs:
        h = fetch(f"{L500_BASE}/c/taiwan/{slug}")
        pa_name = slug.replace("-", " ").title()
        m = re.search(r"<h1[^>]*>([^<]+)</h1>", h)
        if m:
            pa_name = unesc(m.group(1))
        # firm tiers：sr-only h3 開 tier 區、rows 是其後的 ranking-table-row
        depts, cur_tier = [], None
        for mm in re.finditer(
                r'<h3 class="sr-only">([^<]+)</h3>|data-testid="ranking-table-row">.*?<h4[^>]*>([^<]+)</h4>', h, re.S):
            if mm.group(1):
                cur_tier = unesc(mm.group(1))
            elif cur_tier:
                depts.append({"band": cur_tier, "name_en": unesc(mm.group(2))})
        # lawyers 子頁
        hl = fetch(f"{L500_BASE}/c/taiwan/{slug}/lawyers")
        lawyers = []
        # 頁面是區塊制：h2（Hall of Fame/Leading partners/Next Generation Partners/
        # Leading associates）之後接該級全部律師卡
        sections = re.split(r'<h2[^>]*>([^<]{3,60})</h2>', hl)
        for si in range(1, len(sections), 2):
            band = unesc(sections[si])
            if band == "Comparative Guides":
                continue
            for art in re.findall(r'<article class="h-full">(.*?)</article>', sections[si + 1], re.S):
                name = re.search(r'<h3[^>]*><span>([^<]+)</span></h3>', art)
                firm = re.search(r'typography-interface-s[^>]*>([^<]+)</span>', art)
                if name and firm:
                    lawyers.append({"name_en": unesc(name.group(1)), "band": band,
                                    "firm_en": unesc(firm.group(1))})
        print(f"  {pa_name}: {len(depts)} firms, {len(lawyers)} lawyers")
        out.append({"practice_area": pa_name, "slug": slug,
                    "url": f"{L500_BASE}/c/taiwan/{slug}",
                    "departments": depts, "lawyers": lawyers})
        time.sleep(1.5)
    _save("legal500", {"year": 2026, "publication": "Asia Pacific", "areas": out})


# ---------------- IFLR1000 ----------------

def scrape_iflr1000():
    h = fetch("https://www.iflr.com/taiwan")
    ed = re.search(r'RankingList-published">\s*(\d{4})', h)
    year = int(ed.group(1)) if ed else 2026
    # rankings 區塊截到 accordion 結束，避免尾部 firm 名錄污染
    mrank = re.search(r'JurisdictionPage-rankings.*?</ps-list-accordion>', h, re.S)
    body = mrank.group(0) if mrank else h
    out = []
    for block in re.split(r'<div class="Ranking close" data-list>', body)[1:]:
        t = re.search(r'Ranking-title">([^<]+)<', block)
        pa = unesc(t.group(1)) if t else "?"
        depts = []
        for tname, tb in re.findall(
                r'RankingTier-header-title">\s*([^<]+?)\s*</h3>(.*?)(?=<div class="RankingTier">|\Z)',
                block, re.S):
            for f in re.findall(r'href="[^"]*/iflr1000/firms/[^"]*"[^>]*>([^<]+)</a>', tb):
                depts.append({"band": unesc(tname), "name_en": unesc(f)})
        print(f"  {pa}: {len(depts)} firms")
        out.append({"practice_area": pa, "url": "https://www.iflr.com/taiwan",
                    "departments": depts, "lawyers": []})
    _save("iflr1000", {"year": year, "publication": "IFLR1000", "areas": out})


# ---------------- Asialaw ----------------

def scrape_asialaw():
    h = fetch("https://www.asialaw.com/Jurisdiction/Taiwan/Rankings/432")
    out = []
    for title, body in re.findall(
            r'<h5 class="panel-title">(.*?)</h5>(.*?)(?=<div class="panel panel-default rankings">|\Z)',
            h, re.S):
        pa = unesc(title)
        depts = []
        for tname, ul in re.findall(r'<h6>(.*?)</h6>\s*<ul class="list-group">(.*?)</ul>', body, re.S):
            for f in re.findall(r'>([^<]+)</a>', ul):
                depts.append({"band": unesc(tname), "name_en": unesc(f)})
        if depts:
            print(f"  {pa}: {len(depts)} firms")
            out.append({"practice_area": pa,
                        "url": "https://www.asialaw.com/Jurisdiction/Taiwan/Rankings/432",
                        "departments": depts, "lawyers": []})
    _save("asialaw", {"year": 2025, "publication": "asialaw", "areas": out})


def _save(source, data):
    path = os.path.join(CACHE, f"{source}_taiwan.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"saved → {path}")


# ---------------- 共通：build / report / upload ----------------

def band_rank(band, source):
    b = band.strip()
    if b == "Firms to watch":
        return 97
    m = re.match(r"Tier (\d+)", b)
    if m:
        return int(m.group(1))
    table = {"Outstanding": 1, "Highly recommended": 2, "Recommended": 3}
    if b in table:
        return table[b]
    if b == "Notable":
        return 4 if source == "asialaw" else 5
    return 98


def build_rows(source):
    path = os.path.join(CACHE, f"{source}_taiwan.json")
    data = json.load(open(path, encoding="utf-8"))
    rows = []
    for pa in data["areas"]:
        lw_order = {"Hall of Fame": 0, "Leading partners": 1,
                    "Next Generation Partners": 2, "Leading associates": 3}
        by_firm = {}
        for lw in pa["lawyers"]:
            by_firm.setdefault(canon(lw["firm_en"]), []).append({
                "name_en": lw["name_en"], "name": None, "band": lw["band"],
                "rank_order": lw_order.get(lw["band"], 9),
                "is_dept_head": False, "ranked_years": None})
        seen = set()
        for d in pa["departments"]:
            cn = canon(d["name_en"])
            # L500 的 sr-only 分組把「Firms to watch」標成 Tier 0
            if d["band"] == "Tier 0":
                d = {**d, "band": "Firms to watch"}
            key = (pa["practice_area"], cn)
            if key in seen:      # 同 tier 重複列防呆
                continue
            seen.add(key)
            rows.append({
                "source": source, "publication": data["publication"], "year": data["year"],
                "practice_area": pa["practice_area"], "practice_area_id": None,
                "firm_name_en": cn, "firm_name": FIRM_MAP.get(cn),
                "band": d["band"], "band_rank": band_rank(d["band"], source),
                "ranked_years_count": None, "org_id": None,
                "ranked_lawyers": by_firm.pop(cn, []), "url": pa["url"]})
        for firm_en, lws in by_firm.items():
            if not firm_en:
                continue
            rows.append({
                "source": source, "publication": data["publication"], "year": data["year"],
                "practice_area": pa["practice_area"], "practice_area_id": None,
                "firm_name_en": firm_en, "firm_name": FIRM_MAP.get(firm_en),
                "band": "Lawyers only", "band_rank": 98, "ranked_years_count": None,
                "org_id": None, "ranked_lawyers": lws, "url": pa["url"]})
    return rows


SOURCES = ["legal500", "iflr1000", "asialaw"]


def report():
    for src in SOURCES:
        path = os.path.join(CACHE, f"{src}_taiwan.json")
        if not os.path.exists(path):
            print(f"== {src}: 尚未 scrape")
            continue
        rows = build_rows(src)
        firms = {}
        for r in rows:
            firms.setdefault(r["firm_name_en"], r["firm_name"])
        mapped = sum(1 for v in firms.values() if v)
        n_lw = sum(len(r["ranked_lawyers"]) for r in rows)
        print(f"== {src}: rows {len(rows)}, firms {len(firms)}, 歸戶 {mapped}/{len(firms)}, lawyers {n_lw}")
        for en, zh in sorted(firms.items()):
            if not zh:
                print(f"   ✗ {en}")


def sb_req(method, path, body=None):
    req = urllib.request.Request(
        SUPABASE_URL + path, method=method,
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status


def upload():
    for src in SOURCES:
        rows = build_rows(src)
        years = sorted({r["year"] for r in rows})
        for y in years:
            st = sb_req("DELETE", f"/rest/v1/firm_awards?source=eq.{src}&year=eq.{y}")
            print(f"DELETE {src} {y}: {st}")
        for i in range(0, len(rows), 50):
            st = sb_req("POST", "/rest/v1/firm_awards", rows[i:i+50])
            print(f"INSERT {src} {i}..{i+len(rows[i:i+50])}: {st}")
            time.sleep(1)
        print(f"{src}: uploaded {len(rows)} rows")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "report"
    if mode == "scrape":
        which = sys.argv[2:] or SOURCES
        for s in which:
            print(f"== scraping {s}")
            {"legal500": scrape_legal500, "iflr1000": scrape_iflr1000,
             "asialaw": scrape_asialaw}[s]()
    elif mode == "report":
        report()
    elif mode == "upload":
        upload()
    elif mode == "run":
        for s in SOURCES:
            print(f"== scraping {s}")
            {"legal500": scrape_legal500, "iflr1000": scrape_iflr1000,
             "asialaw": scrape_asialaw}[s]()
        upload()
    else:
        print(__doc__)
