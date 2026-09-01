-- ============================================================
-- 188: 所級案件量去重下游接線 — firm_dedup_totals view ＋ facts 去重欄位
-- ============================================================
-- mig 186 建了 firm_dedup_month_stats（所×月名目/去重 cache）；本檔補下游：
--
-- firm_dedup_totals：所級跨月合計 view（202101 起全期）。firm_dedup_month_stats
--   約 40 萬列，PostgREST 逐頁抓再 client 聚合要數百趟，改 DB 端 GROUP BY 一趟拿。
--   security_invoker：沿用基表 RLS（auth 可讀）；facts_extract.py 走 service key、
--   前端事務所 modal AI 分析 tab 也直讀本 view。
--
-- firm_analysis_facts 加欄：cases_5y 語意改「202101 起去重合計」（去重素材起點
--   202101、非 60 月窗，勿再當「近 5 年」讀），nominal 對照與重複率入新欄。
--   concentration 改由 dup 率重分桶（≥40% 且 top1 集中→掛名制度；≥40% 且分散
--   →協作型大所——大所協作團隊共同署名不是掛名），詳 facts_extract.py。

CREATE OR REPLACE VIEW firm_dedup_totals
WITH (security_invoker = true) AS
SELECT firm_key,
       count(*)::int           AS months_n,
       min(ym)                 AS ym_from,
       max(ym)                 AS ym_to,
       sum(nominal_cases)::int AS nominal_total,
       sum(dup_cases)::int     AS dup_total,
       sum(dedup_cases)::int   AS dedup_total
FROM firm_dedup_month_stats
GROUP BY firm_key;

ALTER TABLE firm_analysis_facts
  ADD COLUMN IF NOT EXISTS cases_nominal INT,      -- 202101 起名目合計（律師人次，對照欄）
  ADD COLUMN IF NOT EXISTS dup_rate NUMERIC,       -- 重複率 %（dup/nominal*100，1 位小數）
  ADD COLUMN IF NOT EXISTS dedup_months INT;       -- 去重口徑涵蓋月數（年化分母用）

COMMENT ON COLUMN firm_analysis_facts.cases_5y IS
  '202101 起去重案量合計（distinct 判決數，firm_dedup_totals）；無去重歸戶時退回 AI 分析文之名目近 5 年值（此時 cases_nominal 為空）';
COMMENT ON COLUMN firm_analysis_facts.avg_cases IS
  '年化去重人均案量 = dedup_total / months_n * 12 / lawyer_count（無去重資料時退回 moj_firm_stats_cache 名目值）';
COMMENT ON COLUMN firm_analysis_facts.concentration IS
  '掛名制度/真集中/分散非掛名/協作型大所/不明——dup_rate≥40% 時按 top1 署名占比重分桶（≥40%→掛名制度、<40%→協作型大所），否則沿用 AI 文字啟發式';
