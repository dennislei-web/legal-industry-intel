-- 家事分析 RPC 加時間窗（2020-01 起）+ function-level statement_timeout
-- 背景：lawyer/judge_month_stats 隨 1996-2019 歷史回填持續長大，
-- 全表聚合開始撞 role 預設 statement_timeout（57014）。
-- 家事分析口徑本來就是 2020 起（律師抽取/家事分類都以此驗證），鎖窗兼顧正確與效能。

CREATE OR REPLACE FUNCTION family_lawyer_stats()
RETURNS TABLE (name text, family_cases bigint, total_cases bigint, family_share numeric,
               n_courts int, top_court text, last_ym text, firm_name text, firm_ambiguous boolean) AS $$
  WITH per AS (
    SELECT name, court_name,
           sum(coalesce((cats->>'家事')::int, 0)) AS fam,
           sum(case_count) AS tot,
           max(yyyymm) AS last_ym
    FROM lawyer_month_stats
    WHERE yyyymm >= '202001'
    GROUP BY name, court_name
  ), agg AS (
    SELECT name, sum(fam) AS fam, sum(tot) AS tot,
           (count(*) FILTER (WHERE fam > 0))::int AS n_courts,
           max(last_ym) AS last_ym
    FROM per GROUP BY name
    HAVING sum(fam) >= 3
  ), topc AS (
    SELECT DISTINCT ON (name) name, court_name
    FROM per WHERE fam > 0
    ORDER BY name, fam DESC
  ), firm AS (
    SELECT name, min(firm_name) AS firm_name, count(*) AS n
    FROM lawyers_combined
    WHERE firm_name IS NOT NULL
    GROUP BY name
  )
  SELECT a.name, a.fam::bigint, a.tot::bigint,
         round(a.fam::numeric / nullif(a.tot, 0), 3),
         a.n_courts, t.court_name, a.last_ym,
         CASE WHEN f.n = 1 THEN f.firm_name END,
         coalesce(f.n, 0) > 1
  FROM agg a
  LEFT JOIN topc t USING (name)
  LEFT JOIN firm f USING (name)
  ORDER BY a.fam DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION family_lawyer_stats() SET statement_timeout = '120s';

CREATE OR REPLACE FUNCTION family_lawyer_by_court()
RETURNS TABLE (name text, court_name text, family_cases bigint) AS $$
  SELECT name, court_name, sum(coalesce((cats->>'家事')::int, 0))::bigint AS fam
  FROM lawyer_month_stats
  WHERE yyyymm >= '202001'
  GROUP BY name, court_name
  HAVING sum(coalesce((cats->>'家事')::int, 0)) >= 3
  ORDER BY 3 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION family_lawyer_by_court() SET statement_timeout = '120s';

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
  WHERE yyyymm >= '202001'
  GROUP BY 1, 2
  HAVING sum(coalesce((cats->>'家事')::int, 0)) > 0;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION family_judge_stats() SET statement_timeout = '120s';

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
    WHERE yyyymm >= '202001'
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
ALTER FUNCTION family_cases_by_year() SET statement_timeout = '120s';
