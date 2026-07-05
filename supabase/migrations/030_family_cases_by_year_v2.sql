-- family_cases_by_year v2：加 ok_months（該年家事分類已完成回填的月份數）
-- 舊分類的月份家事僅個位數～數十件，新分類約 1,500-3,000 件/月，以月家事 >= 300 判別
DROP FUNCTION IF EXISTS family_cases_by_year();
CREATE OR REPLACE FUNCTION family_cases_by_year()
RETURNS TABLE (year text, family_cases bigint, total_cases bigint,
               months int, ok_months int, fam_avg_days numeric) AS $$
  WITH m AS (
    SELECT yyyymm,
           sum(coalesce((cats->>'家事')::int, 0)) AS fam,
           sum(case_count) AS tot,
           sum(sum_days) FILTER (WHERE coalesce((cats->>'家事')::int, 0)::numeric / nullif(case_count, 0) >= 0.8) AS sd,
           sum(n_days) FILTER (WHERE coalesce((cats->>'家事')::int, 0)::numeric / nullif(case_count, 0) >= 0.8) AS nd
    FROM judge_month_stats
    GROUP BY yyyymm
  )
  SELECT left(yyyymm, 4),
         sum(fam)::bigint,
         sum(tot)::bigint,
         count(*)::int,
         (count(*) FILTER (WHERE fam >= 300))::int,
         round(sum(sd)::numeric / nullif(sum(nd), 0), 0)
  FROM m
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
