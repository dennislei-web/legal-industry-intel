# -*- coding: utf-8 -*-
"""firm_dossier.py — 批次分析用：把單一事務所的全部 DB 資料彙整成一個 UTF-8 文字檔

用法:
  python firm_dossier.py "宸星法律事務所"     # 單家 → _batch408/dossiers/<所名>.txt
  python firm_dossier.py --all               # 產出待分析清單 todo.json ＋ 全部 dossier
"""
import os, re, sys, json, time
import urllib3, requests

urllib3.disable_warnings()
HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(HERE, "_batch408", "dossiers")

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
U = ENV["SUPABASE_URL"].rstrip("/")
K = ENV["SUPABASE_SERVICE_KEY"]
H = {"apikey": K, "Authorization": "Bearer " + K}

def get(path, params, rng=None):
    h = dict(H)
    if rng:
        h["Range"] = rng
    r = requests.get(U + path, params=params, headers=h, timeout=30, verify=False)
    if r.status_code >= 400:
        return []
    return r.json()

def get_all(path, params):
    rows, s = [], 0
    while True:
        b = get(path, params, rng=f"{s}-{s+999}")
        rows.extend(b)
        if len(b) < 1000:
            break
        s += 1000
    return rows

def rpc(fn, payload):
    r = requests.post(U + "/rest/v1/rpc/" + fn, headers={**H, "Content-Type": "application/json"},
                      json=payload, timeout=30, verify=False)
    if r.status_code >= 400:
        return None
    return r.json()

def inlist(names):
    return "in.(" + ",".join('"' + n.replace('"', '') + '"' for n in names) + ")"

def dossier(firm):
    L = []
    A = L.append
    A(f"# {firm} — DB dossier（產出於 {time.strftime('%Y-%m-%d')}，供 AI 分析用）")

    cache = get("/rest/v1/moj_firm_stats_cache", {"firm_name": "eq." + firm, "select": "*"})
    A("\n## 事務所統計 (moj_firm_stats_cache)")
    A(json.dumps(cache, ensure_ascii=False))

    web = get("/rest/v1/firm_websites", {"firm_name": "eq." + firm, "select": "firm_name,website_url,website_title,description,phone,address,verified"})
    A("\n## 官網 (firm_websites)")
    A(json.dumps(web, ensure_ascii=False))

    # v2：名冊以 MOJ 現行名冊為準（office_normalized 前綴歸戶分所、剔除已除名），
    # lawyers_with_stats 只補案量/專長；三源合併多出的非 MOJ 人員不入名冊
    moj = get_all("/rest/v1/moj_lawyers", {"office_normalized": "like." + firm + "*",
        "select": "name,lic_no,deregistered_at"})
    moj = [r for r in moj if not r.get("deregistered_at")]
    lws = get_all("/rest/v1/lawyers_with_stats", {"firm_name": "like." + firm + "*",
        "select": "name,moj_lic_no,lic_year,moj_sex,official_cases_5yr,official_cases_total,official_cats_5yr,official_top_court,name_ambiguous,expertise_areas,practice_start_date"})
    lwmap = {r["name"]: r for r in lws if r.get("moj_lic_no")}
    roster = []
    for r in moj:
        o = dict(lwmap.get(r["name"]) or {"name": r["name"], "official_cases_5yr": None,
                                          "official_cats_5yr": None, "name_ambiguous": False})
        o["moj_lic_no"] = r["lic_no"]
        if o.get("lic_year") is None:
            mres = re.match(r"[(（]?(\d+)", r["lic_no"] or "")
            if mres:
                o["lic_year"] = int(mres.group(1))
        roster.append(o)
    A("\n## 律師名冊＋官方案量 (名冊=MOJ 現行在籍（分所歸戶、已除名剔除）；案量 name_ambiguous=true 者為同名合併值)")
    for r in roster:
        A(json.dumps(r, ensure_ascii=False))
    names = [r["name"] for r in roster]

    # 名冊口徑宣告素材：分所/「母所字號+姓名」個人登記的成員列名，供 metadata 第二行照抄
    sub = [{"name": r["name"], "登記所": r["firm_name"]} for r in lws
           if r.get("firm_name") and r["firm_name"] != firm and r["name"] in set(names)]
    A("\n## 名冊口徑（分析 metadata 第二行照抄；本段列出非本所主登記的歸戶成員）")
    if sub:
        A(f"本所主登記 {len(names)-len(sub)} 位＋分所/個人登記 {len(sub)} 位＝合計 {len(names)} 位；歸戶成員：")
        A(json.dumps(sub, ensure_ascii=False))
    else:
        A(f"僅本所 {len(names)} 位（無分所/個人登記歸戶）")

    if names:
        byy = get("/rest/v1/lawyer_judgment_stats", {"name": inlist(names), "select": "name,by_year,top_court_5yr"})
        A("\n## 律師逐年案量 (lawyer_judgment_stats.by_year)")
        for r in byy:
            A(json.dumps(r, ensure_ascii=False))
        yr_tot = {}
        for r in byy:
            for y, v in (r.get("by_year") or {}).items():
                yr_tot[y] = yr_tot.get(y, 0) + (v or 0)
        A("全所逐年合計（趨勢段先列此實數再下結論；⚠️ 最末年為部分年僅供年化參考，不得當趨勢證據；"
          "name_ambiguous=true 者含同名案量）：")
        A(json.dumps(dict(sorted(yr_tot.items())), ensure_ascii=False))

    if names:
        causes = get_all("/rest/v1/lawyer_cause_stats", {"name": inlist(names), "select": "name,cases_5yr,by_group,top_causes"})
        A("\n## 律師×案由 (lawyer_cause_stats, 滾動60月)")
        for r in causes:
            r["top_causes"] = (r.get("top_causes") or [])[:6]
            A(json.dumps(r, ensure_ascii=False))

        conc = get_all("/rest/v1/lawyer_client_concentration", {"name": inlist(names), "select": "name,n_cases,tier,top1_name,top1_share,top_entities,top_court,top_titles"})
        A("\n## 客戶集中度 (lawyer_client_concentration, 近12月)")
        for r in conc:
            A(json.dumps(r, ensure_ascii=False))

        exj = get("/rest/v1/ex_judicial_lawyers", {"name": inlist(names), "select": "name,kind,first_yyyymm,last_yyyymm,main_org,confidence,firm_name,source"})
        A("\n## 前司法官訊號 (ex_judicial_lawyers；firm_name 不同=同名他人，要甄別)")
        A(json.dumps(exj, ensure_ascii=False))

        pairs = get_all("/rest/v1/lawyer_pair_month_stats", {"or": f'(name_a.{inlist(names)},name_b.{inlist(names)})',
                    "select": "name_a,name_b,cases"})
        pagg = {}
        nset = set(names)
        for r in pairs:
            key = (r["name_a"], r["name_b"])
            pagg[key] = pagg.get(key, 0) + (r.get("cases") or 0)
        A("\n## 同案共同列名 (lawyer_pair_month_stats；已跨月加總=總件數，禁止再引單月列；"
          "同所兩人高頻成對=掛名/協作證據，配對對象非本所名冊=跨所協作或同名污染)")
        for (a, b), n in sorted(pagg.items(), key=lambda kv: -kv[1])[:20]:
            other_in = (a in nset) and (b in nset)
            A(json.dumps({"pair": f"{a}×{b}", "總件數": n,
                          "關係": "同所" if other_in else "對方非本所名冊"}, ensure_ascii=False))

        amt = get_all("/rest/v1/lawyer_case_amount_stats", {"name": inlist(names), "select": "name,bucket,cases"})
        bux, per = {}, {}
        for r in amt:
            bux[r["bucket"]] = bux.get(r["bucket"], 0) + r["cases"]
            d = per.setdefault(r["name"], {})
            d[r["bucket"]] = d.get(r["bucket"], 0) + r["cases"]
        A("\n## 標的金額桶 (lawyer_case_amount_stats，mig 171 官方登錄值×裁判書 join，202111 起；民訴+家訴，非財產訴訟無金額不在內)")
        A("全所合計：" + json.dumps(bux, ensure_ascii=False))
        top_amt = sorted(per.items(), key=lambda kv: -sum(kv[1].values()))[:12]
        A("律師層（有金額案件數 TOP12）：")
        for nm, d in top_amt:
            A(json.dumps({"name": nm, **d}, ensure_ascii=False))

        fee = get_all("/rest/v1/lawyer_case_fee_stats", {"name": inlist(names),
            "select": "name,cases_200plus,surcharge_base_sum,surcharge_capped_sum,appeal2_cases,appeal3_cases"})
        fagg = {}
        for r in fee:
            d = fagg.setdefault(r["name"], {"c200": 0, "sur": 0, "cap": 0, "a2": 0, "a3": 0})
            d["c200"] += r.get("cases_200plus") or 0
            d["sur"] += r.get("surcharge_base_sum") or 0
            d["cap"] += r.get("surcharge_capped_sum") or 0
            d["a2"] += r.get("appeal2_cases") or 0
            d["a3"] += r.get("appeal3_cases") or 0
        cap_sum = sum(d["cap"] for d in fagg.values())
        sur_sum = sum(d["sur"] for d in fagg.values())
        n_amount = sum(bux.values())  # 有標的金額登錄的全體案件數＝二三審佔比的正確分母
        tot = {"200萬+件數": sum(d["c200"] for d in fagg.values()),
               "有金額案件總數(審級佔比分母用此)": n_amount,
               "超額標的capped合計_萬元": round(cap_sum / 10000),
               "未cap原值_萬元": round(sur_sum / 10000),
               "二審件數": sum(d["a2"] for d in fagg.values()),
               "三審件數": sum(d["a3"] for d in fagg.values())}
        A("\n## 收費模型三因子 (lawyer_case_fee_stats，mig 172/cap 方案1，202111 起；"
          "加費公式一律用 capped 欄=Σmax(0,min(金額,1億)-200萬)，未cap 僅供離群對照)")
        A("全所合計：" + json.dumps(tot, ensure_ascii=False))
        A("★規格加費（照抄，勿自行重算；係數加成另計）：capped %s 萬 × 1.5%% ＝ %s 萬（4.6 年累計）；年化（÷4.6）＝ %s 萬" % (
            f"{round(cap_sum/1e4):,}", f"{round(cap_sum*0.015/1e4):,}", f"{round(cap_sum*0.015/4.6/1e4):,}"))
        if cap_sum and abs(cap_sum - sur_sum) < 1:
            A("★capped==未cap：正常狀態（全所無單案標的逾 1 億），不是封頂失效，禁用任何自創算法")
        A("律師層（capped 超額 TOP12，萬元）：")
        for nm, d in sorted(fagg.items(), key=lambda kv: -kv[1]["cap"])[:12]:
            A(json.dumps({"name": nm, "200萬+件數": d["c200"],
                          "surcharge_capped萬元": round(d["cap"] / 10000),
                          "未cap萬元": round(d["sur"] / 10000),
                          "二審": d["a2"], "三審": d["a3"]}, ensure_ascii=False))

        chg_in = get("/rest/v1/moj_lawyer_changes", {"new_office": "eq." + firm, "select": "name,change_type,old_office,new_office,changed_at", "order": "changed_at.desc"}, rng="0-19")
        chg_out = get("/rest/v1/moj_lawyer_changes", {"old_office": "eq." + firm, "select": "name,change_type,old_office,new_office,changed_at", "order": "changed_at.desc"}, rng="0-19")
        A("\n## 人員異動 (moj_lawyer_changes, 2026-07-03 起追蹤) — 轉入")
        A(json.dumps(chg_in, ensure_ascii=False))
        A("轉出：")
        A(json.dumps(chg_out, ensure_ascii=False))

    corp = rpc("corp_firm_clients", {"p_firm": firm})
    A("\n## 企業當事人 (corp_firm_clients RPC)")
    A(json.dumps(corp, ensure_ascii=False)[:4000])

    gt = get_all("/rest/v1/gov_tender_firms", {"firm_name": "eq." + firm, "select": "tender_key,is_winner,award_amount"})
    A("\n## 政府標案 (gov_tender_firms＋gov_tenders 全量聚合)")
    if gt:
        keys = list({g["tender_key"] for g in gt})
        td = []
        for i in range(0, len(keys), 80):
            td += get("/rest/v1/gov_tenders", {"tender_key": inlist(keys[i:i+80]),
                      "select": "tender_key,title,unit_name,award_date,budget_amount"}, rng="0-199")
        tmap = {t["tender_key"]: t for t in td}
        yearly = {}
        for g in gt:
            t = tmap.get(g["tender_key"]) or {}
            yr = (t.get("award_date") or "")[:4] or "不明"
            d = yearly.setdefault(yr, {"投標": 0, "得標": 0, "得標金額": 0})
            d["投標"] += 1
            if g.get("is_winner"):
                d["得標"] += 1
                d["得標金額"] += g.get("award_amount") or 0
        A("年度聚合（全量 %d 筆投標）：" % len(gt))
        A(json.dumps(yearly, ensure_ascii=False, sort_keys=True))
        wins = sorted([g for g in gt if g.get("is_winner") and g.get("award_amount")],
                      key=lambda g: -g["award_amount"])[:10]
        A("前 10 大得標明細：")
        for g in wins:
            t = tmap.get(g["tender_key"]) or {}
            A(json.dumps({"金額": g["award_amount"], "機關": t.get("unit_name"),
                          "案名": (t.get("title") or "")[:60], "決標日": t.get("award_date")},
                         ensure_ascii=False))
    else:
        A("[]")

    ind = get("/rest/v1/firm_indep_directorships", {"office_normalized": "eq." + firm, "select": "person_name,company_name,market,title"})
    A("\n## 獨董席次 (firm_indep_directorships)")
    A(json.dumps(ind, ensure_ascii=False))

    tipo = get("/rest/v1/tipo_firm_stats", {"firm": "eq." + firm, "select": "kind,year_tw,cases,agents_n"})
    A("\n## TIPO 專利商標代理 (tipo_firm_stats)")
    A(json.dumps(tipo, ensure_ascii=False))

    gp = get("/rest/v1/firm_google_places", {"firm_name": "eq." + firm, "select": "gmaps_name,rating,reviews_count,address,matched"})
    ds = get("/rest/v1/firm_digital_signals", {"firm_name": "eq." + firm, "select": "url,http_status,fb_url,ig_url,line_url,yt_url,has_fb_pixel,has_google_ads,has_ga,has_gtm,has_tiktok_pixel"})
    A("\n## Google 商家 (firm_google_places；matched=false 不可信)")
    A(json.dumps(gp, ensure_ascii=False))
    A("\n## 數位訊號 (firm_digital_signals)")
    A(json.dumps(ds, ensure_ascii=False))

    prof = get("/rest/v1/firm_profiles", {"firm_name": "eq." + firm, "select": "user_notes,description,founded_year"})
    A("\n## 既有 profile（user_notes 絕不可覆蓋）")
    A(json.dumps(prof, ensure_ascii=False))

    os.makedirs(OUTDIR, exist_ok=True)
    path = os.path.join(OUTDIR, firm + ".txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    return path, len(roster)

def build_todo():
    web = get_all("/rest/v1/firm_websites", {"verified": "eq.true", "website_url": "not.is.null", "select": "firm_name"})
    names = sorted({w["firm_name"] for w in web if "事務所" in w["firm_name"]})
    done = {p["firm_name"] for p in get_all("/rest/v1/firm_profiles", {"ai_analysis": "not.is.null", "select": "firm_name"})}
    cache = {c["firm_name"]: c.get("lawyer_count") or 0 for c in get_all("/rest/v1/moj_firm_stats_cache", {"select": "firm_name,lawyer_count"})}
    todo = [{"firm": n, "n": cache.get(n, 0), "tier": ("full" if cache.get(n, 0) >= 10 else "std" if cache.get(n, 0) >= 3 else "lite")}
            for n in names if n not in done]
    todo.sort(key=lambda x: -x["n"])
    os.makedirs(os.path.join(HERE, "_batch408"), exist_ok=True)
    with open(os.path.join(HERE, "_batch408", "todo.json"), "w", encoding="utf-8") as f:
        json.dump(todo, f, ensure_ascii=False, indent=1)
    return todo

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--all":
        todo = build_todo()
        print("todo:", len(todo))
        t0 = time.time()
        for i, t in enumerate(todo):
            try:
                dossier(t["firm"])
            except Exception as e:
                print("FAIL", i, repr(e)[:120])
            if (i + 1) % 20 == 0:
                print(f"{i+1}/{len(todo)} elapsed {time.time()-t0:.0f}s")
        print("ALL DONE", len(todo), f"{time.time()-t0:.0f}s")
    else:
        path, n = dossier(sys.argv[1])
        print("wrote", path.encode("utf-8", "replace"), "roster", n)

if __name__ == "__main__":
    main()
