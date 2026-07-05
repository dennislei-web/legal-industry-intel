-- 家事律師版圖 RPC × 2（讀 lawyer_month_stats 60.9 萬列，DB 端聚合）
-- family_lawyer_stats：每位律師的家事案量/佔比/主要法院/事務所歸屬（唯一同名才歸）
-- family_lawyer_by_court：律師×法院的家事案量（法院視角查詢用）
-- 注意：PostgREST max-rows=1000，前端要用 .range() 分批抓

CREATE OR REPLACE FUNCTION family_lawyer_stats()
RETURNS TABLE (name text, family_cases bigint, total_cases bigint, family_share numeric,
               n_courts int, top_court text, last_ym text, firm_name text, firm_ambiguous boolean) AS $$
  WITH per AS (
    SELECT name, court_name,
           sum(coalesce((cats->>'家事')::int, 0)) AS fam,
           sum(case_count) AS tot,
           max(yyyymm) AS last_ym
    FROM lawyer_month_stats
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

CREATE OR REPLACE FUNCTION family_lawyer_by_court()
RETURNS TABLE (name text, court_name text, family_cases bigint) AS $$
  SELECT name, court_name, sum(coalesce((cats->>'家事')::int, 0))::bigint AS fam
  FROM lawyer_month_stats
  GROUP BY name, court_name
  HAVING sum(coalesce((cats->>'家事')::int, 0)) >= 3
  ORDER BY 3 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
