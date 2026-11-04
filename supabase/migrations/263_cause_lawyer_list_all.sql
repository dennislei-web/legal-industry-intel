-- 263：領域律師版圖「案類／種類」都可選「全部」（雷 2026-11-04：「都加一個選項是全部好了」）
--   cause_lawyer_list 加 p_cat；p_group NULL＝該案類全部種類（p_cat 也 NULL＝全部案類）
--   cause_court_list 加 p_cat、p_group 可 NULL（法院下拉跟著案類／種類）
--   兩支都是「簽名變更」：必須 DROP 舊版再建，否則 PostgREST named-arg 呼叫會歧義（mig 098 教訓）
--   案類篩選口徑：cause_group_map.cat 對應的種類＋未入 map 的鍵（鍵前綴＝案類，refresh 時落為同名種類）；
--   刑事與少年共用種類名，刑事加總會含少年刑事案件（與 cause_supply_stats／mig 245 一致）
--   加兩個索引：年度表 (yr)、法院表 (court_name)——不指定種類時原索引都用不上
CREATE INDEX IF NOT EXISTS idx_lcys_yr ON lawyer_cause_year_stats (yr);
CREATE INDEX IF NOT EXISTS idx_lccs_court ON lawyer_cause_court_stats (court_name);

DROP FUNCTION IF EXISTS cause_court_list(text);
CREATE OR REPLACE FUNCTION cause_court_list(p_group text DEFAULT NULL, p_cat text DEFAULT NULL)
RETURNS TABLE (court_name text, total bigint, lawyers int) AS $$
  SELECT s.court_name, sum(s.case_count)::bigint, count(DISTINCT s.name)::int
  FROM lawyer_cause_court_stats s
  WHERE (p_group IS NULL OR s.cause_group = p_group)
    AND (p_cat IS NULL OR s.cause_group = p_cat
         OR s.cause_group IN (SELECT DISTINCT m.cause_group FROM cause_group_map m WHERE m.cat = p_cat))
  GROUP BY 1 ORDER BY 2 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_court_list(text, text) SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_court_list(text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS cause_lawyer_list(text, int, text, int);
CREATE OR REPLACE FUNCTION cause_lawyer_list(
  p_group text DEFAULT NULL, p_year int DEFAULT NULL, p_court text DEFAULT NULL, p_limit int DEFAULT 250, p_cat text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lo text; hi text; res json;
BEGIN
  IF p_year IS NOT NULL THEN lo := p_year::text || '01'; hi := p_year::text || '12'; END IF;

  WITH g AS (
    SELECT DISTINCT m.cause_group FROM cause_group_map m WHERE p_cat IS NOT NULL AND m.cat = p_cat
  ), per AS (
    SELECT s.name,
           CASE WHEN p_group IS NOT NULL THEN coalesce((s.by_group->>p_group)::int, 0)
                WHEN p_cat IS NOT NULL THEN (SELECT coalesce(sum(e.v::int), 0) FROM jsonb_each_text(s.by_group) e(k, v)
                                             WHERE e.k = p_cat OR e.k IN (SELECT cause_group FROM g))::int
                ELSE s.cases_5yr END AS c,
           s.cases_5yr AS total
    FROM lawyer_cause_stats s
    WHERE p_court IS NULL AND p_year IS NULL
    UNION ALL
    SELECT y.name, sum(y.case_count)::int, NULL::int
    FROM lawyer_cause_year_stats y
    WHERE p_court IS NULL AND p_year IS NOT NULL AND y.yr = p_year
      AND (p_group IS NULL OR y.cause_group = p_group)
      AND (p_cat IS NULL OR y.cause_group = p_cat OR y.cause_group IN (SELECT cause_group FROM g))
    GROUP BY y.name
    UNION ALL
    SELECT s.name, sum(s.case_count)::int, NULL::int
    FROM lawyer_cause_court_stats s
    WHERE p_court IS NOT NULL AND p_year IS NULL AND s.court_name = p_court
      AND (p_group IS NULL OR s.cause_group = p_group)
      AND (p_cat IS NULL OR s.cause_group = p_cat OR s.cause_group IN (SELECT cause_group FROM g))
    GROUP BY s.name
    UNION ALL
    SELECT l.name,
           sum((k.value)::int) FILTER (WHERE
             (p_group IS NULL OR coalesce(m.cause_group, split_part(k.key, '|', 1)) = p_group)
             AND (p_cat IS NULL OR coalesce(m.cat, split_part(k.key, '|', 1)) = p_cat))::int AS c,
           sum((k.value)::int)::int AS total
    FROM lawyer_month_stats l
    CROSS JOIN LATERAL jsonb_each_text(l.causes) k
    LEFT JOIN cause_group_map m ON m.ck = k.key
    WHERE p_court IS NOT NULL AND p_year IS NOT NULL
      AND l.court_name = p_court AND l.yyyymm BETWEEN lo AND hi AND l.causes IS NOT NULL
    GROUP BY l.name
  ), per2 AS (
    SELECT p.name, p.c, p.total FROM per p WHERE coalesce(p.c, 0) > 0
  ), firm AS (
    SELECT lc.name, min(lc.firm_name) AS firm_name, count(*) AS n
    FROM lawyers_combined lc WHERE lc.firm_name IS NOT NULL GROUP BY lc.name
  ), j AS (
    SELECT p.name, p.c, p.total,
           CASE WHEN f.n = 1 THEN f.firm_name END AS firm_name,
           coalesce(f.n, 0) > 1 AS firm_ambiguous,
           (f.n = 1 AND f.firm_name LIKE '%喆律%') AS is_zhelu
    FROM per2 p LEFT JOIN firm f ON f.name = p.name
  ), kpi AS (
    SELECT coalesce(sum(c), 0)::bigint AS total_cases, count(*)::int AS lawyers,
           coalesce(sum(c) FILTER (WHERE is_zhelu), 0)::bigint AS zhelu_cases,
           count(*) FILTER (WHERE is_zhelu)::int AS zhelu_lawyers
    FROM j
  ), top0 AS (
    SELECT j.*, row_number() OVER (ORDER BY j.c DESC, j.name)::int AS rank
    FROM j ORDER BY j.c DESC, j.name LIMIT p_limit
  ), top AS (
    SELECT t.rank, t.name, t.firm_name, t.firm_ambiguous, t.c AS cases,
           coalesce(t.total, tb.total, tc.total) AS total
    FROM top0 t
    LEFT JOIN LATERAL (
      SELECT sum(y.case_count)::int AS total FROM lawyer_cause_year_stats y
      WHERE p_court IS NULL AND p_year IS NOT NULL AND y.name = t.name AND y.yr = p_year) tb ON true
    LEFT JOIN LATERAL (
      SELECT sum(s.case_count)::int AS total FROM lawyer_cause_court_stats s
      WHERE p_court IS NOT NULL AND p_year IS NULL AND s.name = t.name AND s.court_name = p_court) tc ON true
  )
  SELECT json_build_object(
    'total_cases', k.total_cases, 'lawyers', k.lawyers,
    'zhelu_cases', k.zhelu_cases, 'zhelu_lawyers', k.zhelu_lawyers,
    'rows', coalesce((SELECT json_agg(json_build_object(
        'rank', t.rank, 'name', t.name, 'firm_name', t.firm_name, 'firm_ambiguous', t.firm_ambiguous,
        'cases', t.cases, 'total', t.total,
        'share', round(t.cases::numeric / nullif(t.total, 0), 4)) ORDER BY t.rank) FROM top t), '[]'::json))
  INTO res FROM kpi k;
  RETURN res;
END $$;
ALTER FUNCTION cause_lawyer_list(text, int, text, int, text) SET statement_timeout = '60s';
ALTER FUNCTION cause_lawyer_list(text, int, text, int, text) SET plan_cache_mode = 'force_custom_plan';
GRANT EXECUTE ON FUNCTION cause_lawyer_list(text, int, text, int, text) TO anon, authenticated;
