# -*- coding: utf-8 -*-
"""Legal 500 firm×領域頁深層內容 → firm_award_highlights（mig 177）

抓 /c/taiwan/{pa} 各領域 ranking 頁的 firm row 連結
（/rankings/ranking/c-taiwan/{pa}/{id-slug}），逐頁解析 SSR HTML：
  - Key clients（<h4>Key clients</h4><ul><li>…）
  - Work highlights（<h4>Work highlights</h4> 後 grid，抽金額 USD/NT$ × million/billion）
  - Practice head / Other key lawyers（<h5> 區塊）

口徑（存 DB 前端分析都要記得）：highlights 是 submission 精選（每領域 ~3 件、挑大的），
金額是「交易標的」不是律師費——只能推單案量級與客戶質量，不得加總成年營收。

用法：
  python l500_highlights.py scrape    # 13 領域 → firm 頁逐頁抓 → cache JSON
  python l500_highlights.py report    # 統計（不動 DB）
  python l500_highlights.py upload    # cache → firm_award_highlights
  python l500_highlights.py run       # scrape + upload
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
BASE = "https://www.legal500.com"
YEAR = 2026  # Asia Pacific 2026（與 rating_awards.py legal500 同步）

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
    return html_mod.unescape(re.sub(r"\s+", " ", s)).strip()


def strip_tags(s):
    return unesc(re.sub(r"<[^>]+>", " ", s))


AMOUNT_RE = re.compile(
    r"(?:USD?|US\$|NT\$|NTD|TWD|EUR|JPY|GBP|HK\$|RMB|\$)\s?[\d.,]+\s?"
    r"(?:billion|million|bn|m)\b", re.I)

# 換算成百萬美元的粗略係數（僅供排序/量級，非精算）
CUR_USD = {"USD": 1, "US$": 1, "$": 1, "NT$": 1/31, "NTD": 1/31, "TWD": 1/31,
           "EUR": 1.1, "JPY": 1/150, "GBP": 1.3, "HK$": 1/7.8, "RMB": 1/7.2}


def parse_amounts(text):
    out = []
    for raw in AMOUNT_RE.findall(text):
        m = re.match(r"(USD?|US\$|NT\$|NTD|TWD|EUR|JPY|GBP|HK\$|RMB|\$)\s?([\d.,]+)\s?(billion|million|bn|m)\b",
                     raw, re.I)
        if not m:
            out.append({"raw": raw})
            continue
        cur, num, unit = m.group(1).upper().replace("USD", "USD"), m.group(2), m.group(3).lower()
        try:
            v = float(num.replace(",", ""))
        except ValueError:
            out.append({"raw": raw})
            continue
        if unit in ("billion", "bn"):
            v *= 1000
        cur_key = "USD" if cur.startswith("USD") or cur == "US$" else cur
        musd = round(v * CUR_USD.get(cur_key, CUR_USD.get(cur, 1)), 1)
        out.append({"raw": raw, "musd": musd})
    return out


def section(h, title, tag="h4"):
    """取 <h4>{title}</h4> 之後到下一個同級 section 的 HTML 片段"""
    m = re.search(rf'<{tag}[^>]*>{re.escape(title)}</{tag}>(.*?)(?=<{tag}[^>]*>|</section>)', h, re.S)
    return m.group(1) if m else ""


def parse_firm_page(h):
    out = {}
    kc = section(h, "Key clients")
    out["key_clients"] = [strip_tags(x) for x in re.findall(r"<li[^>]*>(.*?)</li>", kc, re.S)]
    wh = section(h, "Work highlights")
    items = [strip_tags(x) for x in re.findall(r'<div class="w-full break-words box-border">(.*?)</div>', wh, re.S)]
    out["highlights"] = [{"text": t, "amounts": parse_amounts(t)} for t in items if t]
    ph = section(h, "Practice head", tag="h5")
    out["practice_heads"] = [s.strip() for p in re.findall(r"<p[^>]*>(.*?)</p>", ph, re.S)
                             for s in strip_tags(p).split(";") if s.strip()]
    ol = section(h, "Other key lawyers", tag="h5")
    out["other_lawyers"] = [s.strip() for p in re.findall(r"<p[^>]*>(.*?)</p>", ol, re.S)
                            for s in strip_tags(p).split(";") if s.strip()]
    return out


def scrape():
    h = fetch(BASE + "/c/taiwan/practice-areas")
    slugs = sorted(set(re.findall(r'href="/c/taiwan/([a-z0-9-]+)"', h))
                   - {"practice-areas", "directory"})
    print(f"practice areas: {len(slugs)}")
    result = []
    for slug in slugs:
        hp = fetch(f"{BASE}/c/taiwan/{slug}")
        pa_name = slug.replace("-", " ").title()
        m = re.search(r"<h1[^>]*>([^<]+)</h1>", hp)
        if m:
            pa_name = unesc(m.group(1))
        # firm rows：tier（sr-only h3）＋連結
        rows, cur_tier = [], None
        for mm in re.finditer(
                r'<h3 class="sr-only">([^<]+)</h3>|'
                r'<a href="(/rankings/ranking/c-taiwan/[^"]+)"[^>]*>.*?<h4[^>]*>([^<]+)</h4>', hp, re.S):
            if mm.group(1):
                cur_tier = unesc(mm.group(1))
            else:
                rows.append({"href": mm.group(2), "name_en": unesc(mm.group(3)), "tier": cur_tier})
        print(f"== {pa_name}: {len(rows)} firms")
        for r in rows:
            hf = fetch(BASE + r["href"])
            parsed = parse_firm_page(hf)
            n_amt = sum(len(x["amounts"]) for x in parsed["highlights"])
            print(f"   {r['name_en']}: clients {len(parsed['key_clients'])}, "
                  f"highlights {len(parsed['highlights'])} (金額 {n_amt})")
            result.append({"practice_area": pa_name, "url": BASE + r["href"],
                           "name_en": r["name_en"], "tier": r["tier"], **parsed})
            time.sleep(1.2)
    path = os.path.join(CACHE, "l500_highlights.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(f"saved → {path}（{len(result)} firm×領域頁）")


def canon(name_en):
    n = unesc(name_en)
    return FIRM_ALIAS.get(n, n)


def build_rows():
    data = json.load(open(os.path.join(CACHE, "l500_highlights.json"), encoding="utf-8"))
    rows, seen = [], set()
    for d in data:
        cn = canon(d["name_en"])
        key = (d["practice_area"], cn)
        if key in seen:
            continue
        seen.add(key)
        rows.append({
            "source": "legal500", "year": YEAR, "practice_area": d["practice_area"],
            "firm_name_en": cn, "firm_name": FIRM_MAP.get(cn), "tier": d["tier"],
            "key_clients": d["key_clients"], "highlights": d["highlights"],
            "practice_heads": d["practice_heads"], "other_lawyers": d["other_lawyers"],
            "url": d["url"]})
    return rows


def report():
    rows = build_rows()
    n_cl = sum(len(r["key_clients"]) for r in rows)
    n_hl = sum(len(r["highlights"]) for r in rows)
    n_amt = sum(len(h["amounts"]) for r in rows for h in r["highlights"])
    mapped = sum(1 for r in rows if r["firm_name"])
    print(f"rows {len(rows)}（歸戶 {mapped}）, key clients {n_cl}, highlights {n_hl}, 含金額 {n_amt}")
    # 客戶數 TOP
    from collections import Counter
    c = Counter()
    for r in rows:
        if r["firm_name"]:
            c[r["firm_name"]] += len(r["key_clients"])
    for f, n in c.most_common(10):
        print(f"  {f}: {n} 客戶條目")


def sb_req(method, path, body=None):
    req = urllib.request.Request(
        SUPABASE_URL + path, method=method,
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status


def upload():
    rows = build_rows()
    st = sb_req("DELETE", f"/rest/v1/firm_award_highlights?source=eq.legal500&year=eq.{YEAR}")
    print(f"DELETE legal500 {YEAR}: {st}")
    for i in range(0, len(rows), 20):
        st = sb_req("POST", "/rest/v1/firm_award_highlights", rows[i:i+20])
        print(f"INSERT {i}..{i+len(rows[i:i+20])}: {st}")
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
