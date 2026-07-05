-- 家事分析頁 RPC × 2
-- family_judge_stats：每位 (法官×法院) 的家事案件量/佔比/平均結案天數
-- family_cases_by_year：年度家事案件量與家事專責月的平均結案天數
--（結案天數無法按案類拆分，fam_avg_days 取「該月家事佔比 >= 80% 的法官月」估算）

CREATE OR REPLACE FUNCTION family_judge_stats()
RETURNS TABLE (name text, court_name text, total_cases bigint, family_cases bigint,
               family_share numeric, avg_days numeric, first_ym text, last_ym text) AS $$
  SELECT name, court_name,
         sum(case_count)::bigint,
         sum(coalesce((cats->>'家事')::int, 0))::bigint,
         round(sum(coalesce((cats->>'家事')::int, 0))::numeric / nullif(sum(case_count), 0), 3),
         round(sum(sum_days)::numeric / nullif(sum(n_days), 0), 0),
         min(yyyymm), max(yyyymm)
  FROM judge_month_stats
  GROUP BY 1, 2
  HAVING sum(coalesce((cats->>'家事')::int, 0)) > 0;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION family_cases_by_year()
RETURNS TABLE (year text, family_cases bigint, total_cases bigint, months int, fam_avg_days numeric) AS $$
  SELECT left(yyyymm, 4),
         sum(coalesce((cats->>'家事')::int, 0))::bigint,
         sum(case_count)::bigint,
         count(DISTINCT yyyymm)::int,
         round((sum(sum_days) FILTER (WHERE coalesce((cats->>'家事')::int, 0)::numeric / nullif(case_count, 0) >= 0.8))::numeric
               / nullif(sum(n_days) FILTER (WHERE coalesce((cats->>'家事')::int, 0)::numeric / nullif(case_count, 0) >= 0.8), 0), 0)
  FROM judge_month_stats
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
