# 合夥人訪談筆記（field notes）— 記錄規格

雷皓明陸續拜訪各所律師（合夥人、主持律師、合署與受僱律師）。拜訪拿到的是**公開資料抓不到的產業細節**
（薪酬結構、引案抽成、公關預算、標案人力門檻、利衝護城河…），是 `ai_analysis`（只靠裁判書／標案／名冊）
天生缺的那一層。本規格定義怎麼把口述變成**可跨所比較**的結構化資料。
「面談」與「拜訪」是同一種手段（雷 2026-09-15 說明），通道一律記為 `拜訪`；另一種來源是北所面試筆記彙整（見下）。

- DB（全部 **admin-only RLS**）：
  - `field_note_dimensions` 維度目錄（mig 196；`rankable`／`mirror_only` 旗標 mig 203）
  - `firm_field_notes` 一次拜訪或一版面試筆記彙整一列（`channel` 只允許 拜訪／面試筆記彙整；`interviewee` 受訪者姓名只供追溯，mig 203）
  - `firm_field_facts` 原子觀察（`crosscheck_kind`／`corroboration`／`verification_status` mig 202）
  - `field_note_overviews` 各面向概述（mig 205；首版 mig 206）＋ view `field_note_overview_status`（落後偵測）
  - `interview_market_bands` 面試筆記數字市場帶（mig 200／201）
- 前端（喆律戰情＞合夥人訪談筆記，三層）：
  - L1 總覽：資料來源條（拜訪／面試筆記）＋面向磚（一句話結論、來源色條、代表數字）＋其他面向一行式＋喆律鏡像＋事務所與拜訪索引
  - L2 面向頁：樣本句（自動）→ 概述 → 關鍵數字 → 市場帶（薪酬、人才）→ 矛盾與缺口 → 各所陳述（一所一行）
  - L3 事務所：面向頁內行內展開（依維度條列）；事務所 modal「🔒 田野筆記」tab（本所自述／他人談本所、面向切換、原始口述）
- 首筆：眾博法律事務所合夥人，2026-09-12（migration 196 內含 seed，可當範本）
- 回填：2023／2024「拜訪律師名單.xlsx」28 筆（migration 197）——日期僅知年份時 `interviewed_on` 記該年 01-01 並設 `date_precision='year'`；
  原表「營收/個人收入」欄＝**受訪者個人（或其單位）收入，一律歸 `fin.personal_income`**，不得當全所營收（受訪者多為合署靠行律師；mig 199 修正）；區間取中位＋`'~'`

## 流程（每次拜訪後）

1. 雷把口述／訊息原文丟給 Claude（可以很口語、不用整理）。
2. Claude 依下列規則拆成 facts，**先貼一張表給雷過目**（對象／維度／值／信心），確認後再寫 DB。
3. 寫入方式：新開 `supabase/migrations/NNN_field_note_<所簡稱>_<YYYYMMDD>.sql`（一份拜訪一個檔，
   內容照 196 的 `WITH n AS (INSERT … RETURNING id) INSERT INTO firm_field_facts … SELECT n.id, f.* FROM n, (VALUES …)` 寫法），
   `supabase db query --linked -f` 套用，查 `firm_field_facts` 筆數驗證，commit。
4. 拜訪提到本站已有資料可對照的（標案金額、人數、成立年、人員異動…）**一定先查 DB 再寫 `db_crosscheck`**；
   口述與 DB 對不上時兩邊都記，不要只留一邊。
5. **概述更新**：facts 套用後查 `select * from field_note_overview_status where is_stale;`。
   新增涉及新事務所、或同面向新增 ≥3 條、或概述引用的條目已變更 → Claude 依下方「概述撰寫規則」重寫該面向，先貼給雷過目，
   出 `NNN_overview_<grp>_<YYYYMMDD>.sql`，固定兩句：`UPDATE field_note_overviews SET is_current=false WHERE grp=… AND is_current;`
   ＋`INSERT … version = 舊版+1，basis 用子查詢算`（寫法照 mig 206）。雷核定後另出一句把 `reviewed_by` 填「雷皓明」。
   其餘不重寫：頁面會自動標「另有 K 條新增未納入」並列出新條目。凡 UPDATE 既有 facts 的 migration 一律同檔處理概述（basis 偵測不到改寫）。
6. **每支 migration 的驗證**（放在檔尾 DO 區塊，任一不符就 RAISE 整支回滾）：
   - 查核狀態字串不得進 `db_crosscheck`：`db_crosscheck ~ '(未逐字查核|同上|單一來源|第一版分析|未逐條複核)'` 必為 0
   - 遮名 lint：`value_text／db_crosscheck／quote／corroboration／summary／source_desc` 對 `moj_lawyers.name`（3–4 字）比對必為 0（寫法照 mig 204；「○○律師事務所」所名本身除外）
   - 所名對齊：`firm`／`subject_firm` 必須在 `moj_firm_stats_cache.firm_name`（「（未載）…」佔位名除外）

## 拆解規則

| 欄位 | 規則 |
|---|---|
| `firm`（notes） | 受訪者所屬所，用 `moj_firm_statistics().firm_name` 的全名（例「眾博法律事務所」），前端靠這個名字對到事務所 modal；**先查 DB 對齊異體字**（宇恆→宇恒、六合國際→六合、KPMG→安侯…），所名未載時寫「（未載）○○所屬事務所」，**佔位名不得含人名** |
| `channel` | 一律 `拜訪`（預設值）；面試筆記彙整才用 `面試筆記彙整` |
| `interviewed_on` / `date_precision` | 確切日填 `day`；只知年份填該年 01-01＋`year`；只知月份填該月 01＋`month` |
| `source_role` / `source_desc` | 合夥人／主持律師／合署律師／受僱律師／其他。`source_desc` **只寫角色與年資，不寫姓名**；姓名放 `interviewee`（前端不顯示） |
| `summary` | 三行以內，寫「這次最有價值的 2–3 個發現」，不是逐條複述；**只寫角色不寫人名** |
| `raw_notes` | 原話全文照貼（保留口語），日後維度改版可重拆；只在事務所視窗收合區顯示，不跑遮名 lint |
| `subject_scope` | `firm`＝談自己所；`peer`＝談別家（`subject_firm` 填該所）；`industry`＝「大所都這樣」類的通則（`subject_firm` 留 null） |
| `dimension_key` | 從 `field_note_dimensions` 挑；**找不到合適維度就新增一個**（同一 migration 內 INSERT，key 用 `群組.蛇形英文`，sort 接在群組尾端），不要硬塞進不對的維度；一條混了兩件事就拆成兩條，不要複製 |
| `value_num` / `value_qual` | 有數字就填：「20% 以下」→ `20, '<'`；「大概一年本薪」→ `1, '~'`；「300 萬」→ `300, '='`。單位依維度（萬元／%／倍／人），**不要換算成元**；數字的單位和維度單位不同（例「調薪 10%」掛在萬元維度）就不填數字 |
| `value_text` | 一句人話結論，不帶數字前綴（前端會自動把 value_num 排前面）；律師、當事人一律寫角色或所名 |
| `confidence` | `high`＝受訪者親身參與且具體；`medium`＝概略／推測／「可能」；`low`＝聽說、金額不明 |
| `secondhand` | 受訪者轉述別人／別所＝true（`industry` 通常 true）；談自己待過的前東家（親歷）＝false，前端顯示「親歷前東家」 |
| `db_crosscheck`＋`crosscheck_kind` | **只放本站資料**：`evidence`＝「表名：數字」（例 `gov_tenders：114 年度 1,350 萬`）；`pointer`＝本站可對照但還沒核（例「ex_judicial_lawyers 可核對…」） |
| `corroboration` | 跨訪談互證或矛盾（例「與 2026-09-12 拜訪口徑一致」「2 位候選人口徑一致」）；不是本站資料，不要寫進 `db_crosscheck` |
| `verification_status` | 面試筆記彙整條目必填：`verified`／`partial`／`unverified`／`first_pass`；拜訪條目留 NULL |
| `quote` | 原話片段（可省），供日後回看語氣；含人名時以「○○○」代替 |
| `fin.revenue` vs `fin.personal_income` | 受訪者說的錢預設是**個人或其單位**收入（合署所的主持律師尤其如此）→ `fin.personal_income`；只有明講「全所」才進 `fin.revenue`。**不要拿個人收入去校正本站營收推估** |
| `strat.zhelu_implication` | **雷自己的判讀**用這個維度獨立記一條，不要混進受訪者說法；前端以「雷判讀」標記，不進事務所列 |

## 維度

最新清單以 DB 為準：`select key, grp_label, label, unit, rankable, mirror_only from field_note_dimensions order by sort;`
面向（`grp`）：薪酬 comp／組織 org／行銷 mkt／機構標案 gov／工時 work／業務線 biz／客戶 client／人才 talent／財務 fin／戰略 strat／個人職涯 career。
`mirror_only`＝候選人看喆律（雇主品牌、競爭雇主、應徵者期待薪資），只出現在「喆律鏡像」；`rankable=false`＝個人收入類，不排名、不加總。

## 概述撰寫規則（field_note_overviews）

1. 樣本數、來源組成、信心分佈由頁面自動顯示，概述不重複；但只有一所的面向寫「單一案例、非跨所歸納」，2023–24 拜訪提醒已過數年。
2. 先寫跨所共通模式、再寫例外：至少 3 所支撐才可寫「跨所看得到」，2 所以下寫個案並點所名；例外一律點所名。
3. 每個數字附 n、口徑、單位、年份與來源；口徑不同不得並列或互推（年終倍數 vs 月數、個人收入 vs 全所營收、人均在手案 vs 名冊平均案量）；面試筆記市場帶不與拜訪數字合併成「業界平均」。
4. 面試筆記口徑一律標「離職者視角、二手」；低信心只作旁證；人才與工時面向點出樣本偏差（離職者偏流動快、在職受訪者偏留得住）。
5. 只寫角色不寫人名；所名用 MOJ 全名；喆律自身條目只寫在喆律鏡像。
6. 只可引用已入庫的 facts；`summary`／`raw_notes`／面試原文裡沒拆成 fact 的內容不得進概述；雷判讀不混入受訪者說法；一條產業通則不寫成業界共識。
7. `one_liner` 約 40 字以內（面向磚用）；`overview_md` 約 300 字以內，可用粗體小標。
8. `gaps_md` 寫矛盾與缺口：0 筆維度、單一所維度、口述與本站佐證矛盾、同所異口徑、年份過舊。
9. `key_numbers` 每項掛 `fact_ids`（facts）或市場帶自然鍵 `{dimension_key, level, size_band, position_kind, year}`（不用 band id，換版會變）。
10. `exemplars`（各所一句代表陳述）只為同所同面向 ≥5 條的格撰寫（雷 2026-09-15 拍板）；其餘由頁面自動取信心最高的一條。

## 累積到一定量後可做的分析（現在先不做）

- 薪酬結構橫向表：底薪模式 × 年終倍數 × 引案抽成，按所規模分層 → 對照喆律薪制
- 公關支出／營收比：`mkt.*` 對 `firm_analysis_facts.rev_*`
- 「駐點型標案」清單：`gov_tenders.title` 篩 駐點／進駐／派駐，配 `gov.tender_staffing` 口述門檻，評估喆律可競標池
- 訪談口述 vs `ai_analysis` 推估的營收落差 → 校正 REVENUE_RULES 係數（**只能用明講「全所」口徑的 `fin.revenue`**；目前 0 筆，個人收入不可用）

## 面試筆記彙整（channel='面試筆記彙整'，migration 200–207，2026-09-14 起）

北所面試筆記（人事機密，原文只在本機 `scripts/.interview_work/`）彙整後以同一套表承接，規則比拜訪嚴：

- 錨點：一版一列 `firm_field_notes`（firm＝喆律、`channel='面試筆記彙整'`、`raw_notes` 一律 NULL、`source_version` 記抽取版本）。
- 事務所層：`firm_field_facts` `subject_scope='peer'`、`secondhand=true`；門檻＝≥3 位不同候選人提到該所，且仍在職者（MOJ 現登錄所＝口述前東家）的條目排除；文字改寫不引述；未查證的違法／倫理／性別指控與健康婚育不入；主持律師姓名改職稱；`verification_status` 依來源分塊是否逐字查核判定，未逐字查核的一律 `confidence='low'`。
- 同一位候選人在不同分塊重複面試只算一位，不可當「2 筆一致」。
- **本 repo 是公開的**：含受訪者、候選人或各所觀察內容的 migration 檔不進 git（本機 `.git/info/exclude` 排除，只在本機保存並套用）；規格、前端程式可以進 git。
- 數字帶：`interview_market_bands`（名冊級距×職位×年度×維度；`n_candidates` ≥3 才入、≥5 才有四分位；`size_band='zhelu'` 放應徵喆律者期待薪資），由 `scripts/.interview_work/bands.ps1` 零 token 重算，改抽取後重跑再出新 migration（`source_version` 換版）。
- **第二版起的更新**：既有 facts 就地 UPDATE 保留 id（概述的 `fact_ids` 才不會失效）、新條目 INSERT、撤回 DELETE；bands 照 mig 201 換 `source_version`；note 的 `source_version` 換版；**薪酬、人才、組織、工時、客戶五個面向的概述固定重寫**（雷 2026-09-15 拍板）。
- 不存候選人姓名／參照碼／面試日期／狀態；喆律自身作為前東家的紀錄不入。

## 邊界

- 拜訪內容屬商業敏感：**只進 admin-only 表，不進 `ai_analysis` 公開文、不進 `industry_review`**；要引用時只寫「業界訪談」不點名受訪者。
- 一次拜訪只建一筆 note；同一所多次拜訪就多筆 note，facts 各自掛自己的 note。
- 不做前端寫入表單、不做匯出：寫入一律走 migration。
