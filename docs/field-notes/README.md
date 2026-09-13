# 合夥律師訪談田野筆記（field notes）— 記錄規格

雷皓明 2026-09 起陸續與各所合夥律師面談。面談拿到的是**公開資料抓不到的產業細節**
（薪酬結構、引案抽成、公關預算、標案人力門檻、利衝護城河…），是 `ai_analysis`（只靠裁判書／標案／名冊）
天生缺的那一層。本規格定義怎麼把口述變成**可跨所比較**的結構化資料。

- DB：`field_note_dimensions`（維度目錄）／`firm_field_notes`（一次訪談一列）／`firm_field_facts`（原子觀察）— migration 196，三表 **admin-only RLS**
- 前端：喆律戰情＞合夥人訪談筆記（KPI＋維度×事務所 pivot＋逐次訪談）；事務所 modal「🔒 田野筆記」tab（admin 才顯示）
- 首筆：眾博法律事務所合夥人，2026-09-12（migration 196 內含 seed，可當範本）
- 回填：2023／2024「拜訪律師名單.xlsx」28 筆（migration 197）——日期僅知年份時 `interviewed_on` 記該年 01-01 並設 `date_precision='year'`；
  原表「營收/個人收入」欄＝**受訪者個人（或其單位）收入，一律歸 `fin.personal_income`**，不得當全所營收（受訪者多為合署靠行律師；mig 199 修正）；區間取中位＋`'~'`

## 流程（每次面談後）

1. 雷把口述／訊息原文丟給 Claude（可以很口語、不用整理）。
2. Claude 依下列規則拆成 facts，**先貼一張表給雷過目**（對象／維度／值／信心），確認後再寫 DB。
3. 寫入方式：新開 `supabase/migrations/NNN_field_note_<所簡稱>_<YYYYMMDD>.sql`（一份訪談一個檔，
   內容照 196 的 `WITH n AS (INSERT … RETURNING id) INSERT INTO firm_field_facts … SELECT n.id, f.* FROM n, (VALUES …)` 寫法），
   `supabase db query --linked -f` 套用，查 `firm_field_facts` 筆數驗證，commit。
4. 面談提到本站已有資料可對照的（標案金額、人數、成立年、人員異動…）**一定先查 DB 再寫 `db_crosscheck`**；
   口述與 DB 對不上時兩邊都記，不要只留一邊。

## 拆解規則

| 欄位 | 規則 |
|---|---|
| `firm`（notes） | 受訪者所屬所，用 `moj_firm_statistics().firm_name` 的全名（例「眾博法律事務所」），前端靠這個名字對到事務所 modal；**先查 DB 對齊異體字**（宇恆→宇恒、六合國際→六合、KPMG→安侯…），所名未載時寫「（未載）○○所屬事務所」 |
| `interviewed_on` / `date_precision` | 確切日填 `day`；只知年份填該年 01-01＋`year`；只知月份填該月 01＋`month` |
| `source_role` | 合夥人／所長／受僱律師／法務／其他。`source_desc` 可不具名；**不放個資**（電話、私人關係） |
| `summary` | 三行以內，寫「這次最有價值的 2–3 個發現」，不是逐條複述 |
| `raw_notes` | 原話全文照貼（保留口語），日後維度改版可重拆 |
| `subject_scope` | `firm`＝談自己所；`peer`＝談別家（`subject_firm` 填該所）；`industry`＝「大所都這樣」類的通則（`subject_firm` 留 null） |
| `dimension_key` | 從 `field_note_dimensions` 挑；**找不到合適維度就新增一個**（同一 migration 內 INSERT，key 用 `群組.蛇形英文`，sort 接在群組尾端），不要硬塞進不對的維度 |
| `value_num` / `value_qual` | 有數字就填：「20% 以下」→ `20, '<'`；「大概一年本薪」→ `1, '~'`；「300 萬」→ `300, '='`。單位依維度（萬元／%／倍／人），**不要換算成元** |
| `value_text` | 一句人話結論，不帶數字前綴（前端會自動把 value_num 排前面） |
| `confidence` | `high`＝受訪者親身參與且具體；`medium`＝概略／推測／「可能」；`low`＝聽說、金額不明 |
| `secondhand` | 受訪者轉述別人／別所＝true（`industry` 通常 true） |
| `db_crosscheck` | 本站佐證或矛盾：寫「表名：數字」，例 `gov_tenders：114 年度 1,350 萬` |
| `quote` | 原話片段（可省），供日後回看語氣 |
| `fin.revenue` vs `fin.personal_income` | 受訪者說的錢預設是**個人或其單位**收入（合署所的主持律師尤其如此）→ `fin.personal_income`；只有明講「全所」才進 `fin.revenue`。**不要拿個人收入去校正本站營收推估** |
| `strat.zhelu_implication` | **雷自己的判讀**用這個維度獨立記一條，不要混進受訪者說法 |

## 現有維度（key）

comp.base_model／comp.bonus_ratio_to_base／comp.bonus_components／comp.origination_rate／comp.partner_expense／comp.associate_pay_band
／org.model_lineage／org.partner_track／org.headcount／org.decision_style
／mkt.event_spend／mkt.annual_budget／mkt.channel_mix／mkt.effect_view
／gov.tender_annual_amount／gov.tender_staffing／gov.entry_barrier／gov.spillover
／biz.niche／biz.intl_arbitration／biz.revenue_line／client.mix／client.pricing
／talent.turnover／talent.hiring_source／fin.revenue／fin.margin／strat.zhelu_implication／strat.market_view

最新清單以 DB 為準：`select key, grp_label, label, unit from field_note_dimensions order by sort;`

## 累積到一定量後可做的分析（現在先不做）

- 薪酬結構橫向表：底薪模式 × 年終倍數 × 引案抽成，按所規模分層 → 對照喆律薪制
- 公關支出／營收比：`mkt.*` 對 `firm_analysis_facts.rev_*`
- 「駐點型標案」清單：`gov_tenders.title` 篩 駐點／進駐／派駐，配 `gov.tender_staffing` 口述門檻，評估喆律可競標池
- 訪談口述 vs `ai_analysis` 推估的營收落差 → 校正 REVENUE_RULES 係數（**只能用明講「全所」口徑的 `fin.revenue`**；目前 0 筆，個人收入不可用）

## 邊界

- 面談內容屬商業敏感：**只進 admin-only 表，不進 `ai_analysis` 公開文、不進 `industry_review`**；要引用時只寫「業界訪談」不點名受訪者。
- 一次訪談只建一筆 note；同一所多次面談就多筆 note，facts 各自掛自己的 note。
