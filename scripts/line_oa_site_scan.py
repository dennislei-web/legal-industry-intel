"""官網 LINE 連結深掃（補 firm_digital_signals 只掃首頁、只涵蓋 573 家的缺口）。

掃 firm_websites verified=true 全部官網：首頁＋最多 3 個「聯絡／預約／諮詢」站內頁，
抽 LINE 官方帳號 ID（lin.ee 短網址解析、line.me/R/ti/p/@、page.line.me、QR 圖檔名常見的 @id）。
新帳號寫進 line_oa_accounts（source=website_deep）；之後 line_oa_daily.py daily 會接手抓好友數。

  python line_oa_site_scan.py            # 全量
  python line_oa_site_scan.py --dry      # 只輸出 JSON 不寫 DB
"""
import json
import re
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

import requests
import urllib3

from line_oa_daily import (LAW_WORD, LINE, UA, _safe_profile, load_firm_names, norm_id,
                           pick_firm, resolve_id, sb_get, sb_upsert)

urllib3.disable_warnings()
WEB = requests.Session()
WEB.headers["User-Agent"] = UA
RE_LINK = re.compile(r'https?://(?:lin\.ee/[A-Za-z0-9]{4,20}|(?:page\.)?line\.me/[^\s"\'<>)]{2,120})', re.I)
RE_SUB = re.compile(r'<a[^>]+href=["\']([^"\'#]+)["\'][^>]*>(.*?)</a>', re.I | re.S)
SUB_WORD = re.compile(r"聯絡|聯繫|預約|諮詢|contact|line", re.I)


def get(url):
    try:
        r = WEB.get(url, timeout=15, verify=False, allow_redirects=True)
        if r.status_code >= 400:
            return None, url
        r.encoding = r.apparent_encoding if r.encoding in (None, "ISO-8859-1") else r.encoding
        return r.text, r.url
    except Exception:  # noqa: BLE001
        return None, url


def scan_site(row):
    html, final = get(row["website_url"])
    if not html:
        return row, set(), "fail"
    links = set(RE_LINK.findall(html))
    host = urllib.parse.urlparse(final).netloc
    subs = []
    for href, text in RE_SUB.findall(html):
        if SUB_WORD.search(text) or SUB_WORD.search(href):
            u = urllib.parse.urljoin(final, href)
            if urllib.parse.urlparse(u).netloc == host and u not in subs and u != final:
                subs.append(u)
    for u in subs[:3]:
        h, _ = get(u)
        if h:
            links |= set(RE_LINK.findall(h))
    ids = set()
    for l in links:
        sid = resolve_id(l)
        if sid:
            ids.add(sid)
    return row, ids, "ok"


def main(dry=False):
    t0 = time.time()
    sites = sb_get("firm_websites?select=firm_name,website_url&verified=eq.true")
    print(f"官網 {len(sites)} 個", flush=True)
    with ThreadPoolExecutor(12) as ex:
        res = list(ex.map(scan_site, sites))
    ok = sum(1 for _, _, s in res if s == "ok")
    found = {}
    for row, ids, _ in res:
        for sid in ids:
            found.setdefault(sid, row["firm_name"])
    print(f"掃描完成 {time.time() - t0:.0f}s｜可連 {ok}/{len(sites)}｜有 LINE 帳號 {sum(1 for _, i, _ in res if i)} 家｜帳號 {len(found)} 個", flush=True)
    existing = sb_get("line_oa_accounts?select=search_id,basic_id")
    known = {r["search_id"] for r in existing} | {norm_id(r["basic_id"]) for r in existing if r["basic_id"]}
    cand = {s: f for s, f in found.items() if s not in known}
    with ThreadPoolExecutor(6) as ex:
        profs = dict(zip(cand, ex.map(_safe_profile, cand)))
    firm_names = load_firm_names()
    new = []
    for sid, firm in cand.items():
        p = profs[sid]
        b = norm_id(p.get("basic_id"))
        if b and b in known:
            continue
        name = p.get("name")
        rec = {"search_id": sid, "source": "website_deep", "source_url": None,
               "firm_name": pick_firm(name, firm, firm_names) if name else firm,
               "display_name": name, "basic_id": p.get("basic_id"), "premium_id": p.get("premium_id"),
               "is_certified": (p.get("badge") == "certified") if "page" in p else None,
               "excluded": False, "note": None}
        if name and not LAW_WORD.search(name):
            rec["excluded"], rec["note"] = True, "顯示名不像法律帳號，待人工確認"
        if p.get("country") not in (None, "TW"):
            rec["excluded"], rec["note"] = True, f"非台灣帳號（{p.get('country')}）"
        if not rec["excluded"] and rec["firm_name"] and "事務所" not in rec["firm_name"]:
            # firm_websites 含公司法人（企業法務）官網，連到的是公司自己的帳號（銀行、建設…）
            rec["excluded"], rec["note"] = True, "來源官網為公司／法人（企業法務），非事務所帳號"
        known.add(sid)
        if b:
            known.add(b)
        new.append(rec)
    json.dump(new, open("_line_site_scan.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"新帳號 {len(new)}（認證 {sum(1 for r in new if r['is_certified'])}，排除 {sum(1 for r in new if r['excluded'])}）", flush=True)
    if not dry and new:
        sb_upsert("line_oa_accounts", new, "search_id")
        print("已寫入 line_oa_accounts", flush=True)


if __name__ == "__main__":
    main(dry="--dry" in sys.argv)
