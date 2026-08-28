# -*- coding: utf-8 -*-
"""firm_google_places.py — 事務所 Google 商家評分/評論數（Outscraper Maps search，mig 169）

來源: firm_websites (verified=true) x moj_firm_stats_cache (main_region)
輸出: firm_google_places (upsert by firm_name)
計價: Outscraper Places 每筆 1 place record（500/月免費、之後 $3/千筆）

用法:
  python firm_google_places.py --limit 5   # pilot
  python firm_google_places.py             # 全量（跳過已有 place_id 者）
  python firm_google_places.py --force     # 全量重抓
"""
import os, sys, json, time, argparse, winreg
import urllib3
import requests

urllib3.disable_warnings()
HERE = os.path.dirname(os.path.abspath(__file__))

def load_env():
    env = {}
    with open(os.path.join(HERE, ".env"), encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env

ENV = load_env()
SB_URL = ENV["SUPABASE_URL"].rstrip("/")
SB_KEY = ENV["SUPABASE_SERVICE_KEY"]
HDR = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY}

def outscraper_key():
    if os.environ.get("OUTSCRAPER_API_KEY"):
        return os.environ["OUTSCRAPER_API_KEY"]
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
        return winreg.QueryValueEx(k, "OUTSCRAPER_API_KEY")[0]

OS_KEY = outscraper_key()
OS_HDR = {"X-API-KEY": OS_KEY}

def sb_get_all(path, params):
    rows, start = [], 0
    while True:
        r = requests.get(SB_URL + path, params=params,
                         headers={**HDR, "Range": f"{start}-{start+999}"},
                         timeout=30, verify=False)
        r.raise_for_status()
        batch = r.json()
        rows.extend(batch)
        if len(batch) < 1000:
            break
        start += 1000
    return rows

def targets(force=False):
    firms = sb_get_all("/rest/v1/firm_websites",
                       {"verified": "eq.true", "website_url": "not.is.null",
                        "select": "firm_name"})
    names = sorted({f["firm_name"] for f in firms})
    cache = sb_get_all("/rest/v1/moj_firm_stats_cache",
                       {"select": "firm_name,main_region"})
    region = {c["firm_name"]: (c.get("main_region") or "") for c in cache}
    if not force:
        have = sb_get_all("/rest/v1/firm_google_places",
                          {"select": "firm_name", "place_id": "not.is.null"})
        skip = {h["firm_name"] for h in have}
        names = [n for n in names if n not in skip]
    return [(n, region.get(n, "")) for n in names]

def short_name(firm):
    for suf in ("法律事務所", "律師事務所", "聯合事務所", "事務所"):
        if firm.endswith(suf):
            return firm[: -len(suf)]
    return firm

def search_batch(queries):
    """一次最多 25 條 query，async 輪詢。回 list of (query, result_or_None)"""
    r = requests.get("https://api.app.outscraper.com/maps/search-v3",
                     params=[("query", q) for q in queries] +
                            [("limit", "1"), ("language", "zh-TW"),
                             ("region", "TW"), ("async", "true")],
                     headers=OS_HDR, timeout=60)
    r.raise_for_status()
    loc = r.json()["results_location"]
    for _ in range(60):
        time.sleep(10)
        rr = requests.get(loc, headers=OS_HDR, timeout=60)
        j = rr.json()
        if j.get("status") == "Success":
            return j["data"]
        if j.get("status") in ("Failure", "Error"):
            print("BATCH FAIL", str(j)[:200])
            return [[] for _ in queries]
    print("BATCH TIMEOUT")
    return [[] for _ in queries]

def upsert(rows):
    for i in range(0, len(rows), 50):
        r = requests.post(SB_URL + "/rest/v1/firm_google_places",
                          headers={**HDR, "Content-Type": "application/json",
                                   "Prefer": "resolution=merge-duplicates"},
                          data=json.dumps(rows[i:i+50], ensure_ascii=False).encode("utf-8"),
                          timeout=60, verify=False)
        if r.status_code not in (200, 201, 204):
            print("UPSERT FAIL", r.status_code, r.text[:200])
        time.sleep(2)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    tg = targets(force=args.force)
    if args.limit:
        tg = tg[: args.limit]
    print("targets:", len(tg))

    out, t0 = [], time.time()
    for i in range(0, len(tg), 25):
        chunk = tg[i:i+25]
        queries = [f"{name} {region}".strip() for name, region in chunk]
        data = search_batch(queries)
        for (name, region), q, res in zip(chunk, queries, data):
            place = res[0] if res else None
            if place:
                gname = place.get("name") or ""
                sn = short_name(name)
                matched = (sn in gname) or (gname in name) or (name in gname)
                out.append({"firm_name": name, "query": q,
                            "place_id": place.get("place_id"),
                            "gmaps_name": gname,
                            "rating": place.get("rating"),
                            "reviews_count": place.get("reviews"),
                            "address": place.get("full_address"),
                            "matched": bool(matched), "fetched_at": "now()"})
            else:
                out.append({"firm_name": name, "query": q, "place_id": None,
                            "gmaps_name": None, "rating": None,
                            "reviews_count": None, "address": None,
                            "matched": False, "fetched_at": "now()"})
        print(f"batch {i//25+1}: total {min(i+25, len(tg))}/{len(tg)} elapsed {time.time()-t0:.0f}s")
        upsert(out[-len(chunk):])

    got = sum(1 for r in out if r["place_id"])
    m = sum(1 for r in out if r["matched"])
    print(f"DONE targets={len(out)} found={got} matched={m} elapsed={time.time()-t0:.0f}s")

if __name__ == "__main__":
    main()
