"""搜尋引擎發現 LINE 認證帳號：Brave 搜 `site:page.line.me <關鍵字>`。

page.line.me 只有認證帳號有主頁、才會被收錄 → 搜到的都是認證帳號。
顯示名對得到名冊所名（或 XXX 律師→名冊律師現職所）才掛 firm_name，否則 firm_name=NULL 留待人工。
搜尋引擎對機房 IP 常封鎖，本機跑。

  python line_oa_search_discover.py [--dry] [--pages 5]
"""
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

from line_oa_daily import LAW_WORD, UA, _safe_profile, load_firm_names, norm_id, sb_get, sb_upsert

BRAVE = "https://search.brave.com/search"
S = requests.Session()
S.headers["User-Agent"] = UA
RE_ID = re.compile(r"page\.line\.me(?:/|%2F)(?:%40|@)?([A-Za-z0-9._-]{3,40})")
RE_HIDDEN = re.compile(r'<input type="hidden" name="([a-z_]+)" value="([^"]*)"')

BASE = ["法律事務所", "律師事務所", "律師", "法律諮詢", "免費法律諮詢", "法律顧問", "聯合律師事務所",
        "國際法律事務所", "law firm", "lawyer 台灣", "律師諮詢", "法律服務"]
CITY = ["台北", "臺北", "新北", "桃園", "新竹", "苗栗", "台中", "臺中", "彰化", "南投", "雲林", "嘉義",
        "台南", "臺南", "高雄", "屏東", "宜蘭", "花蓮", "台東", "基隆", "板橋", "中壢", "竹北"]
TOPIC = ["離婚", "車禍", "刑事", "勞資", "債務", "繼承", "詐欺", "家事", "智慧財產", "房地產", "醫療糾紛",
         "勞動", "公司法務", "保險", "毒品", "消費者", "專利商標", "移民", "租賃", "工程", "性騷擾", "霸凌"]


def queries():
    qs = [f"site:page.line.me {b}" for b in BASE]
    qs += [f"site:page.line.me {c} 律師" for c in CITY]
    qs += [f"site:page.line.me {c} 法律事務所" for c in CITY]
    qs += [f"site:page.line.me {t} 律師" for t in TOPIC]
    return qs


def search(q, pages):
    """Brave 搜尋（DDG html 版短時間多查會回 202 限流）；offset=0..pages-1 翻頁。"""
    ids = set()
    for p in range(pages):
        try:
            r = S.get(BRAVE, params={"q": q, "offset": p}, timeout=20)
        except requests.RequestException:
            return ids, "err"
        if r.status_code != 200:
            return ids, f"blocked:{r.status_code}"
        got = {m.lower() for m in RE_ID.findall(r.text)} - {"showcase"}
        if not got - ids:
            break
        ids |= got
        time.sleep(4)
    return ids, "ok"


def build_lawyer_map():
    """律師名 → 現職所（同名多人時不採用）。"""
    rows = sb_get("moj_lawyers?select=name,office_normalized&state_desc=eq.正常&office_normalized=not.is.null")
    m, dup = {}, set()
    for r in rows:
        n = r["name"]
        if n in m and m[n] != r["office_normalized"]:
            dup.add(n)
        m[n] = r["office_normalized"]
    return {k: v for k, v in m.items() if k not in dup}


def match_firm(name, firm_names, lawyer_map):
    if not name:
        return None, None
    hits = [f for f in firm_names if len(f) >= 5 and f in name]
    if hits:
        return max(hits, key=len), "所名比對"
    # 「○○法律事務所」去掉國際/聯合等字再比
    m = re.search(r"([一-鿿]{2,6})(?:國際)?(?:聯合)?(?:法律|律師)事務所", name)
    if m:
        for f in firm_names:
            if f.startswith(m.group(1)) and f.endswith("事務所"):
                return f, "所名字首"
    if name.strip() in lawyer_map:  # 帳號名就是律師本名
        return lawyer_map[name.strip()], f"律師名→現職所（{name.strip()}）"
    m = re.search(r"([一-鿿]{2,4})\s*律師", name)
    if m and m.group(1) in lawyer_map:
        return lawyer_map[m.group(1)], f"律師名→現職所（{m.group(1)}）"
    return None, None


def main():
    dry = "--dry" in sys.argv
    pages = int(sys.argv[sys.argv.index("--pages") + 1]) if "--pages" in sys.argv else 5
    t0, allids, blocked = time.time(), set(), 0
    qs = queries()
    if "--ids" in sys.argv:  # 跳過搜尋，直接收錄給定 ID 檔（每行一個；例如內建搜尋工具查到的結果）
        allids = {norm_id(x) for x in open(sys.argv[sys.argv.index("--ids") + 1], encoding="utf-8") if x.strip()}
        qs = []
    for i, q in enumerate(qs):
        ids, st = search(q, pages)
        allids |= ids
        if st.startswith("blocked"):
            blocked += 1
            print(f"  ! {q} {st}", flush=True)
            if blocked >= 3:
                print("連續被擋，停止", flush=True)
                break
            time.sleep(30)
        print(f"[{i + 1}/{len(qs)}] {q}: +{len(ids)}（累計 {len(allids)}）", flush=True)
        time.sleep(3)
    existing = sb_get("line_oa_accounts?select=search_id,basic_id,premium_id")
    known = set()
    for r in existing:
        known |= {r["search_id"], norm_id(r["basic_id"]), norm_id(r["premium_id"])}
    cand = sorted(allids - known)
    print(f"搜尋完成 {time.time() - t0:.0f}s｜ID {len(allids)}｜未收錄 {len(cand)}", flush=True)
    with ThreadPoolExecutor(6) as ex:
        profs = dict(zip(cand, ex.map(_safe_profile, cand)))
    firm_names, lawyer_map = load_firm_names(), build_lawyer_map()
    new = []
    for sid in cand:
        p = profs[sid]
        if not p.get("page") or p.get("country") not in (None, "TW"):
            continue  # 無主頁／非台灣帳號（搜尋結果常混日本事務所）
        b = norm_id(p.get("basic_id"))
        if b in known:
            continue
        name = p.get("name") or ""
        firm, how = match_firm(name, firm_names, lawyer_map)
        law = bool(LAW_WORD.search(name)) or bool(how and how.startswith("律師名"))
        rec = {"search_id": sid, "source": "web_search", "source_url": f"https://page.line.me/{sid}",
               "firm_name": firm, "display_name": name, "basic_id": p.get("basic_id"),
               "premium_id": p.get("premium_id"), "is_certified": p.get("badge") == "certified",
               "excluded": not law, "note": how if law else "顯示名不像法律帳號"}
        known |= {sid, b}
        new.append(rec)
    json.dump(new, open("_line_search_discover.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"新認證帳號 {len(new)}｜法律類 {sum(1 for r in new if not r['excluded'])}｜對到所 {sum(1 for r in new if r['firm_name'] and not r['excluded'])}", flush=True)
    if not dry and new:
        sb_upsert("line_oa_accounts", new, "search_id")
        print("已寫入 line_oa_accounts", flush=True)


if __name__ == "__main__":
    main()
