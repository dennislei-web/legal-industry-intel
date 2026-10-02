# -*- coding: utf-8 -*-
"""firm_ads_render_scan.py — 廣告碼偵測補強（mig 239）

原 firm_digital_signals.py 只掃首頁原始 HTML，經 GTM 載入的碼會漏判。本腳本：
  ② 拆 GTM 容器（gtm.js?id=）— 容器內只含「啟用中」標籤（暫停的會被換成 __paused），
     可抓到要點擊/送表單才觸發的轉換碼
  ③ Playwright 真開網頁（首頁＋最多 2 個聯絡/服務內頁），錄下實際對外請求
三來源（html / gtm / network）任一偵測到即 has_*=true；來源寫進 ads_evidence。
渲染失敗時保留原靜態結果（只 OR，不覆寫成 false）。

用法:
  python firm_ads_render_scan.py --limit 5     # pilot（不寫 DB，印結果與耗時）
  python firm_ads_render_scan.py --write       # 全量並 upsert
  python firm_ads_render_scan.py --write --only-url https://zhelu.tw/
"""
import os, re, sys, io, json, time, random, asyncio, argparse
from urllib.parse import urljoin, urlparse
import urllib3, requests

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
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

KINDS = ("fb", "gads", "line", "tiktok", "yahoo")
COL = {"fb": "has_fb_pixel", "gads": "has_google_ads", "line": "has_line_tag",
       "tiktok": "has_tiktok_pixel", "yahoo": "has_yahoo_ads"}

# 實際送出的追蹤請求（network）
NET_RE = {
    "fb": re.compile(r"facebook\.com/tr[/?]|connect\.facebook\.net/[^/]+/fbevents\.js|connect\.facebook\.net/signals/"),
    # 只認帶廣告帳號 ID 的請求；YouTube 嵌入會打 googleads.g.doubleclick.net/pagead/id，不能當 Ads
    "gads": re.compile(r"pagead/(?:viewthrough)?conversion/\d{6,}|google\.com/pagead/1p-(?:user-list|conversion)/\d{6,}"
                       r"|[?&/]id=AW-\d+|/AW-\d+|td\.doubleclick\.net/td/rul/\d+"),
    "line": re.compile(r"tr\.line\.me/|d\.line-scdn\.net/n/line_tag"),
    "tiktok": re.compile(r"analytics\.tiktok\.com"),
    "yahoo": re.compile(r"s\.yimg\.com/wi/ytc\.js|sp\.analytics\.yahoo\.com|s\.yimg\.jp/images/listing/tool/cv"),
}
# 原始碼 / GTM 容器內的簽名（text）
TXT_RE = {
    "fb": re.compile(r"fbq\(|fbevents\.js|facebook\.com/tr\?"),
    # GTM 執行環境本身就含 googleads.g.doubleclick.net 字串（每個容器都有），不可當簽名
    "gads": re.compile(r"['\"]AW-\d{6,}|\"function\":\"__(?:awct|sp)\""),
    "line": re.compile(r"tr\.line\.me|line_tag|_lt\(['\"]init"),
    "tiktok": re.compile(r"analytics\.tiktok\.com|ttq\.load"),
    "yahoo": re.compile(r"ytc\.js|sp\.analytics\.yahoo\.com|yahoo_retargeting|yahoo_conversion"),
}
GTM_ID_RE = re.compile(r"GTM-[A-Z0-9]{4,10}")
# 追蹤 ID 抽取：用來辨識「建站平台共用的碼」（同一 ID 出現在 >=PLATFORM_MIN 個不相干網域＝平台的，不是事務所的）
ID_RE = {
    "fb": re.compile(r"facebook\.com/tr/?\?(?:[^\s\"']*&)?id=(\d{10,20})|signals/config/(\d{10,20})|fbq\(\s*['\"]init['\"]\s*,\s*['\"](\d{10,20})"),
    "gads": re.compile(r"AW-(\d{6,12})|pagead/(?:viewthrough)?conversion/(\d{6,12})|1p-(?:user-list|conversion)/(\d{6,12})|td/rul/(\d{6,12})"
                       r"|\"vtp_conversionId\":\"?(\d{6,12})"),
}
NEED_ID = {"gads"}  # 這類訊號必須抽得到帳號 ID 才算（字串簽名誤判太多）
PLATFORM_MIN = 3


def ids_of(kind, text):
    rx = ID_RE.get(kind)
    if not rx or not text:
        return set()
    return {next(g for g in m.groups() if g) for m in rx.finditer(text)}
SUBPAGE_RE = re.compile(r"聯絡|聯繫|contact|預約|諮詢|服務|service|收費|fee", re.I)


def fetch_targets():
    rows, start = [], 0
    while True:
        r = requests.get(SB_URL + "/rest/v1/firm_digital_signals",
                         params={"select": "*", "url": "not.is.null", "order": "firm_name"},
                         headers={**HDR, "Range": f"{start}-{start+999}"}, timeout=30, verify=False)
        r.raise_for_status()
        b = r.json()
        rows += b
        if len(b) < 1000:
            break
        start += 1000
    return rows


_gtm_cache = {}


def scan_gtm(gid):
    if gid in _gtm_cache:
        return _gtm_cache[gid]
    hit, ids = set(), {}
    try:
        r = requests.get("https://www.googletagmanager.com/gtm.js", params={"id": gid},
                         headers={"User-Agent": UA}, timeout=20)
        if r.status_code == 200:
            for k, rx in TXT_RE.items():
                if rx.search(r.text):
                    hit.add(k)
                    ids[k] = sorted(ids_of(k, r.text))
    except Exception:
        pass
    _gtm_cache[gid] = (hit, ids)
    return hit, ids


async def render(ctx_factory, url, max_sub=2):
    """回 (status, pages, net_hits:set, html_concat, gtm_ids:set)"""
    reqs = []
    ctx = await ctx_factory()
    ctx.on("request", lambda req: reqs.append(req.url))
    htmls, pages = [], 0
    status = "ok"
    try:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=25000)
        except Exception as e:
            status = "fail:" + type(e).__name__ + ":" + str(e).splitlines()[0][:80]
            return status, 0, set(), "", set(), ""
        pages = 1
        try:
            await page.wait_for_load_state("networkidle", timeout=10000)
        except Exception:
            pass
        await page.mouse.wheel(0, 3000)
        await page.wait_for_timeout(2500)
        htmls.append(await page.content())
        # 內頁：同網域、文字或路徑像聯絡/服務
        links = await page.eval_on_selector_all(
            "a[href]", "els => els.map(e => [e.href, (e.innerText||'').trim().slice(0,30)])")
        host = urlparse(page.url).netloc
        cand, seen = [], set()
        for href, txt in links:
            p = urlparse(href)
            if p.netloc != host or p.scheme not in ("http", "https"):
                continue
            key = p.path.rstrip("/")
            if not key or key in seen or key == urlparse(page.url).path.rstrip("/"):
                continue
            if SUBPAGE_RE.search(txt) or SUBPAGE_RE.search(p.path):
                seen.add(key)
                cand.append(href.split("#")[0])
        for href in cand[:max_sub]:
            try:
                await page.goto(href, wait_until="domcontentloaded", timeout=20000)
                try:
                    await page.wait_for_load_state("networkidle", timeout=8000)
                except Exception:
                    pass
                await page.wait_for_timeout(1500)
                htmls.append(await page.content())
                pages += 1
            except Exception:
                pass
    finally:
        await ctx.close()
    net = set()
    joined = "\n".join(reqs)
    for k, rx in NET_RE.items():
        if rx.search(joined):
            net.add(k)
    html = "\n".join(htmls)
    gtm = set(GTM_ID_RE.findall(html)) | set(GTM_ID_RE.findall(joined))
    return status, pages, net, html, gtm, joined


async def run(targets, conc):
    from playwright.async_api import async_playwright
    out = {}
    sem = asyncio.Semaphore(conc)
    t0 = time.time()
    done = 0
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)

        async def factory():
            return await browser.new_context(user_agent=UA, ignore_https_errors=True, locale="zh-TW",
                                             viewport={"width": 1366, "height": 900})

        async def one(url):
            nonlocal done
            async with sem:
                ts = time.time()
                try:
                    res = await asyncio.wait_for(render(factory, url), timeout=90)
                except Exception as e:
                    res = ("fail:" + type(e).__name__, 0, set(), "", set(), "")
                status, pages, net, html, gtm, joined = res
                txt = {k for k, rx in TXT_RE.items() if html and rx.search(html)}
                gtm_detail = {}
                for g in gtm:
                    h, ids = await asyncio.to_thread(scan_gtm, g)
                    gtm_detail[g] = {"hit": sorted(h), "ids": ids}
                out[url] = dict(status=status, pages=pages, net=sorted(net), txt=sorted(txt), gtm=gtm_detail,
                                net_ids={k: sorted(ids_of(k, joined)) for k in net},
                                txt_ids={k: sorted(ids_of(k, html)) for k in txt},
                                secs=round(time.time() - ts, 1))
                done += 1
                if done % 25 == 0:
                    print(f"  {done}/{len(targets)} elapsed {time.time()-t0:.0f}s", flush=True)

        await asyncio.gather(*(one(u) for u in targets))
        await browser.close()
    return out, time.time() - t0


def host_of(url):
    h = urlparse(url).netloc.lower()
    return h[4:] if h.startswith("www.") else h


def platform_ids(results):
    """同一 GTM / 追蹤 ID 出現在 >=PLATFORM_MIN 個不同主機＝建站平台的碼（例：webnode 的 GTM-542MMSL）"""
    seen = {}
    for url, r in results.items():
        h = host_of(url)
        bag = set("gtm:" + g for g in r["gtm"])
        for src in ("net_ids", "txt_ids"):
            for k, ids in r[src].items():
                bag |= {k + ":" + i for i in ids}
        for g, d in r["gtm"].items():
            for k, ids in d["ids"].items():
                bag |= {k + ":" + i for i in ids}
        for x in bag:
            seen.setdefault(x, set()).add(h)
    return {x: sorted(hs) for x, hs in seen.items() if len(hs) >= PLATFORM_MIN}


def _own(kind, ids, plat):
    """有抽到 ID 且全是平台 ID → 不算；沒抽到 ID（只有簽名）→ NEED_ID 類不算、其他類算"""
    if not ids:
        return kind not in NEED_ID
    return any(kind + ":" + i not in plat for i in ids)


def build_rows(by_url, results, plat):
    rows = []
    for url, firms in by_url.items():
        res = results.get(url)
        if not res:
            continue
        own_gtm = {g: d for g, d in res["gtm"].items() if "gtm:" + g not in plat}
        for old in firms:
            ev = {}
            for k in KINDS:
                src = []
                if res["status"] != "ok" and old.get(COL[k]):
                    src.append("static")  # 渲染失敗才沿用舊靜態結果
                if k in res["txt"] and _own(k, res["txt_ids"].get(k), plat):
                    src.append("html")
                if any(k in d["hit"] and _own(k, d["ids"].get(k), plat) for d in own_gtm.values()):
                    src.append("gtm")
                if k in res["net"] and _own(k, res["net_ids"].get(k), plat):
                    src.append("network")
                if src:
                    ev[k] = src
            row = {"firm_name": old["firm_name"],
                   "gtm_ids": sorted(own_gtm) or None,
                   "ads_evidence": ev,
                   "render_pages": res["pages"],
                   "render_status": res["status"],
                   "render_scanned_at": "now()",
                   "has_gtm": bool(own_gtm) if res["status"] == "ok" else bool(old.get("has_gtm"))}
            for k in KINDS:
                row[COL[k]] = k in ev
            rows.append(row)
    return rows


def upsert(rows):
    for i in range(0, len(rows), 50):
        for attempt in range(3):
            try:
                r = requests.post(SB_URL + "/rest/v1/firm_digital_signals",
                                  headers={**HDR, "Content-Type": "application/json",
                                           "Prefer": "resolution=merge-duplicates"},
                                  data=json.dumps(rows[i:i+50], ensure_ascii=False).encode("utf-8"),
                                  timeout=60, verify=False)
                if r.status_code in (200, 201, 204):
                    break
                print("UPSERT FAIL status", r.status_code)
            except Exception as e:
                print("UPSERT ERR", type(e).__name__)
            time.sleep(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--conc", type=int, default=4)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--only-url")
    ap.add_argument("--from-dump", action="store_true", help="用上次全量渲染結果重算，不重掃")
    ap.add_argument("--retry-failed", action="store_true", help="只重掃上次 dump 裡失敗的網址，併回 dump")
    a = ap.parse_args()

    rows = fetch_targets()
    by_url = {}
    for r in rows:
        if r.get("http_status") == 200 or a.only_url:
            by_url.setdefault(r["url"], []).append(r)
    urls = list(by_url)
    if a.only_url:
        urls = [u for u in urls if u == a.only_url]
    random.shuffle(urls)
    if a.limit:
        urls = urls[:a.limit]
    print(f"targets distinct urls={len(urls)} (rows total={len(rows)})", flush=True)

    dump = os.path.join(HERE, "_ads_render_results.json")
    if a.retry_failed:
        results = json.load(open(dump, encoding="utf-8"))
        redo = [u for u in urls if u in results and results[u]["status"] != "ok"]
        print("retry failed:", len(redo), flush=True)
        new, el = asyncio.run(run(redo, a.conc))
        for u, v in new.items():
            if v["status"] == "ok" or results[u]["status"] != "ok":
                results[u] = v
        json.dump(results, open(dump, "w", encoding="utf-8"), ensure_ascii=False)
        urls = [u for u in urls if u in results]
        import collections
        print("status after retry:", collections.Counter(v["status"].split(":")[0] + ":" + v["status"].split(":")[1] if ":" in v["status"] else v["status"] for v in results.values()))
        for u in redo:
            if results[u]["status"] != "ok":
                print("  still fail", results[u]["status"], u)
    elif a.from_dump:
        results = json.load(open(dump, encoding="utf-8"))
        urls = [u for u in urls if u in results]
        # GTM 容器用現行規則重抓重算（容器小、數量少，規則改了不必重開瀏覽器）
        for v in results.values():
            for g in list(v["gtm"]):
                h, ids = scan_gtm(g)
                v["gtm"][g] = {"hit": sorted(h), "ids": ids}
    else:
        results, el = asyncio.run(run(urls, a.conc))
        if not (a.limit or a.only_url):
            json.dump(results, open(dump, "w", encoding="utf-8"), ensure_ascii=False)
        print(f"elapsed={el:.0f}s per_url_avg={el/max(len(urls),1):.1f}s")
    if a.limit or a.only_url:
        for u in urls:
            r = results[u]
            print(f"{r['secs']:>5}s p={r['pages']} {r['status']:<14} net={r['net_ids'] or r['net']} "
                  f"gtm={ {g: d['hit'] for g, d in r['gtm'].items()} } html={r['txt']} {u}")
    fails = sum(1 for r in results.values() if r["status"] != "ok")
    print(f"fails={fails}")
    plat = platform_ids(results)
    print("platform-shared ids (excluded):")
    for x, hs in sorted(plat.items(), key=lambda t: -len(t[1])):
        print(f"  {x}  hosts={len(hs)}  e.g. {hs[:3]}")

    out = build_rows({u: by_url[u] for u in urls}, results, plat)
    before = {k: sum(1 for r in rows if r.get(COL[k])) for k in KINDS}
    after = {k: sum(1 for r in out if r[COL[k]]) for k in KINDS}
    print("static(before, all rows):", before)
    print("merged(after, scanned rows):", after)
    if a.write:
        upsert(out)
        print("upserted", len(out))


if __name__ == "__main__":
    main()
