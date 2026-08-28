# -*- coding: utf-8 -*-
"""firm_digital_signals.py — 事務所官網社群連結＋廣告追蹤碼偵測（mig 169）

來源: firm_websites (verified=true, website_url not null)
輸出: firm_digital_signals (upsert by firm_name)

用法:
  python firm_digital_signals.py            # 全量
  python firm_digital_signals.py --limit 10 # pilot
"""
import os, re, sys, json, time, random, argparse
import urllib3
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

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

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

RE_FB = re.compile(r'https?://(?:www\.|m\.|zh-tw\.)?facebook\.com/(?!sharer|share\.php|plugins|tr\b|dialog|2008)[A-Za-z0-9_.\-/%]{2,80}', re.I)
RE_IG = re.compile(r'https?://(?:www\.)?instagram\.com/[A-Za-z0-9_.\-/%]{2,60}', re.I)
RE_LINE = re.compile(r'https?://(?:line\.me/[A-Za-z0-9_.\-/@~%]{2,80}|lin\.ee/[A-Za-z0-9]{3,20})', re.I)
RE_YT = re.compile(r'https?://(?:www\.)?youtube\.com/(?:channel/|user/|c/|@)[A-Za-z0-9_.\-/%]{2,80}', re.I)

def detect(html):
    return {
        "fb_url": RE_FB.search(html).group(0) if RE_FB.search(html) else None,
        "ig_url": RE_IG.search(html).group(0) if RE_IG.search(html) else None,
        "line_url": RE_LINE.search(html).group(0) if RE_LINE.search(html) else None,
        "yt_url": RE_YT.search(html).group(0) if RE_YT.search(html) else None,
        "has_fb_pixel": ("fbq(" in html) or ("fbevents.js" in html) or ("facebook.com/tr?" in html),
        "has_google_ads": bool(re.search(r"['\"]AW-\d{6,}", html)) or ("googleads.g.doubleclick.net" in html),
        "has_ga": bool(re.search(r"['\"]G-[A-Z0-9]{6,}", html)) or ("google-analytics.com" in html) or ("gtag/js?id=" in html),
        "has_gtm": ("googletagmanager.com/gtm.js" in html) or bool(re.search(r"['\"]GTM-[A-Z0-9]{4,}", html)),
        "has_tiktok_pixel": "analytics.tiktok.com" in html,
    }

def fetch_firms():
    rows, start = [], 0
    while True:
        r = requests.get(
            SB_URL + "/rest/v1/firm_websites",
            params={"verified": "eq.true", "website_url": "not.is.null",
                    "select": "firm_name,website_url"},
            headers={**HDR, "Range": f"{start}-{start+999}"}, timeout=30, verify=False)
        r.raise_for_status()
        batch = r.json()
        rows.extend(batch)
        if len(batch) < 1000:
            break
        start += 1000
    return rows

def probe(url):
    """回 (status, html) — 失敗回 (0, '')"""
    try:
        r = requests.get(url, headers={"User-Agent": UA}, timeout=(8, 15),
                         verify=False, allow_redirects=True)
        return r.status_code, (r.text[:800000] if r.status_code == 200 else "")
    except Exception:
        return 0, ""

def upsert(rows):
    for i in range(0, len(rows), 50):
        r = requests.post(
            SB_URL + "/rest/v1/firm_digital_signals",
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
    args = ap.parse_args()

    firms = fetch_firms()
    print("firms with verified website:", len(firms))
    # 同 URL 多所共用：以 URL 去重抓一次，結果套回每一所
    by_url = {}
    for f in firms:
        by_url.setdefault(f["website_url"], []).append(f["firm_name"])
    urls = list(by_url.keys())
    random.shuffle(urls)
    if args.limit:
        urls = urls[:args.limit]
    print("distinct urls to probe:", len(urls))

    out, done = [], 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(probe, u): u for u in urls}
        for fut in as_completed(futs):
            u = futs[fut]
            status, html = fut.result()
            sig = detect(html) if html else {
                "fb_url": None, "ig_url": None, "line_url": None, "yt_url": None,
                "has_fb_pixel": False, "has_google_ads": False, "has_ga": False,
                "has_gtm": False, "has_tiktok_pixel": False}
            for name in by_url[u]:
                out.append({"firm_name": name, "url": u, "http_status": status,
                            **sig, "fetched_at": "now()"})
            done += 1
            if done % 50 == 0:
                print(f"probed {done}/{len(urls)} elapsed {time.time()-t0:.0f}s")

    upsert(out)
    ok = sum(1 for r in out if r["http_status"] == 200)
    pix = sum(1 for r in out if r["has_fb_pixel"])
    ads = sum(1 for r in out if r["has_google_ads"])
    fb = sum(1 for r in out if r["fb_url"])
    ln = sum(1 for r in out if r["line_url"])
    print(f"DONE rows={len(out)} http200={ok} fb_page={fb} line={ln} fb_pixel={pix} google_ads={ads} elapsed={time.time()-t0:.0f}s")

if __name__ == "__main__":
    main()
