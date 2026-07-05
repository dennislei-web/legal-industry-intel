-- 年度平均結案天數（估算）趨勢，供法官總覽頁趨勢圖
-- months < 12 表示該年度裁判書尚未回填滿（前端標註）
CREATE OR REPLACE FUNCTION judge_days_by_year()
RETURNS TABLE (year text, avg_days numeric, n_cases bigint, months int) AS $$
  SELECT left(yyyymm, 4) AS year,
         round(sum(sum_days)::numeric / NULLIF(sum(n_days), 0), 0) AS avg_days,
         sum(n_days)::bigint AS n_cases,
         count(DISTINCT yyyymm)::int AS months
  FROM judge_month_stats
  GROUP BY 1
  ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
