-- 082: 法官姓名「以」折行黏字併回本名
-- 問題：裁判書結尾「以上正本證明與原本無異」折行時，「以」偶爾落在
-- 「法 官 ○○○」同一行，姓名被抓成「○○○以」（如 商啓泰以/王奕華以/林筠以）。
-- 盤點：19 個「以」結尾名，其中 18 個 rows=1 且去尾前綴存在於 judge_month_stats
-- （多數也在現任名冊）＝黏字；「陳衡以」rows=20/cases=726 且無前綴＝真名，保留。
-- 名冊 4 字「以」結尾 = 0 筆，本規則不誤傷真人。
-- 處置：併回本名列（真法官的判決，不刪），同 (name,court,yyyymm) 已存在則累加。
-- ETL extract_judges 已同步加去尾規則。套用後需重跑
-- refresh_judge_judgment_stats() + refresh_judge_changes()。

WITH del AS (
  DELETE FROM judge_month_stats m
  WHERE char_length(m.name) = 4 AND m.name ~ '以$'
    AND EXISTS (SELECT 1 FROM judge_month_stats p WHERE p.name = left(m.name, 3))
  RETURNING left(m.name, 3) AS name, m.court_name, m.yyyymm,
            m.case_count, m.sum_days, m.n_days, m.cats
), agg AS (
  SELECT name, court_name, yyyymm, sum(case_count)::int AS cc,
         sum(sum_days)::bigint AS sd, sum(n_days)::int AS nd,
         jsonb_sum_counts(cats) AS cats
  FROM del GROUP BY name, court_name, yyyymm
)
INSERT INTO judge_month_stats (name, court_name, yyyymm, case_count, sum_days, n_days, cats)
SELECT name, court_name, yyyymm, cc, sd, nd, cats FROM agg
ON CONFLICT (name, court_name, yyyymm) DO UPDATE SET
  case_count = judge_month_stats.case_count + EXCLUDED.case_count,
  sum_days   = judge_month_stats.sum_days   + EXCLUDED.sum_days,
  n_days     = judge_month_stats.n_days     + EXCLUDED.n_days,
  cats       = jsonb_add_counts(judge_month_stats.cats, EXCLUDED.cats);

-- 3 字「○○以」：2 字名黏「以」。3 字名結尾「以」有真名（陳衡以，rows=20 無前綴），
-- 故用更嚴條件：去尾後的 2 字名必須在現任名冊 jy_judges（林筠✓／陳衡✗ 保留）。
-- ETL 端不加 3 字規則（無名冊可查、真名風險高），僅靠本清洗＋量極少可接受。
WITH del AS (
  DELETE FROM judge_month_stats m
  WHERE char_length(m.name) = 3 AND m.name ~ '以$'
    AND EXISTS (SELECT 1 FROM jy_judges j WHERE j.name = left(m.name, 2))
  RETURNING left(m.name, 2) AS name, m.court_name, m.yyyymm,
            m.case_count, m.sum_days, m.n_days, m.cats
), agg AS (
  SELECT name, court_name, yyyymm, sum(case_count)::int AS cc,
         sum(sum_days)::bigint AS sd, sum(n_days)::int AS nd,
         jsonb_sum_counts(cats) AS cats
  FROM del GROUP BY name, court_name, yyyymm
)
INSERT INTO judge_month_stats (name, court_name, yyyymm, case_count, sum_days, n_days, cats)
SELECT name, court_name, yyyymm, cc, sd, nd, cats FROM agg
ON CONFLICT (name, court_name, yyyymm) DO UPDATE SET
  case_count = judge_month_stats.case_count + EXCLUDED.case_count,
  sum_days   = judge_month_stats.sum_days   + EXCLUDED.sum_days,
  n_days     = judge_month_stats.n_days     + EXCLUDED.n_days,
  cats       = jsonb_add_counts(judge_month_stats.cats, EXCLUDED.cats);
