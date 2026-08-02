-- 專業法庭：未滿年同期比 RPC
-- 回傳各年度「1 月～最新資料月」同窗切片的裁判量與平均結案天數，
-- 供前端在未滿年時顯示「vs 去年同期」一行敘述（右截尾偏差的公平比較基準）。
-- 口徑同 cat_cases_by_year（mig 126）：2020-01 起、平均天數取該月該類佔比 >= 0.8 的法官月。
CREATE OR REPLACE FUNCTION cat_same_period_stats(p_cat text DEFAULT NULL, p_court_like text DEFAULT NULL)
RETURNS TABLE (year text, upto_month int, cat_cases bigint, cat_avg_days numeric) AS $$
  WITH mx AS (SELECT right(max(yyyymm), 2) AS mm FROM judge_month_stats),
  m AS (
    SELECT yyyymm,
           sum(CASE WHEN p_cat IS NULL THEN case_count
                    ELSE coalesce((cats->>p_cat)::int, 0) END) AS cc,
           sum(sum_days) FILTER (WHERE p_cat IS NULL
               OR coalesce((cats->>p_cat)::int, 0)::numeric / nullif(case_count, 0) >= 0.8) AS sd,
           sum(n_days) FILTER (WHERE p_cat IS NULL
               OR coalesce((cats->>p_cat)::int, 0)::numeric / nullif(case_count, 0) >= 0.8) AS nd
    FROM judge_month_stats
    WHERE yyyymm >= '202001'
      AND right(yyyymm, 2) <= (SELECT mm FROM mx)
      AND (p_court_like IS NULL OR court_name LIKE p_court_like)
    GROUP BY yyyymm
  )
  SELECT left(yyyymm, 4),
         max(right(yyyymm, 2))::int,
         sum(cc)::bigint,
         round(sum(sd)::numeric / nullif(sum(nd), 0), 0)
  FROM m
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cat_same_period_stats(text, text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION cat_same_period_stats(text, text) TO anon, authenticated;
