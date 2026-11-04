-- 262：領域律師版圖整併——一組篩選（種類×年度×法院）出一份名單
--   雷 2026-11-04：「有點亂，可以整合一下嗎，用法院、年分、類型篩選然後出一份名單就好」
--   cause_lawyer_list(p_group, p_year, p_court, p_limit) → json
--     {total_cases, lawyers, zhelu_cases, zhelu_lawyers, rows:[{rank,name,firm_name,firm_ambiguous,cases,total,share}]}
--   四條路徑（同一函式內以參數切換，plan_cache_mode 強制 custom plan 讓死分支被折掉）：
--     全國×近 5 年＝lawyer_cause_stats（mig 070/093）
--     全國×年    ＝lawyer_cause_year_stats（mig 098）
--     法院×近 5 年＝lawyer_cause_court_stats（mig 182）
--     法院×年    ＝lawyer_month_stats 即時算（同 mig 258 作法；最大法院單年 EXPLAIN 0.3～1 秒）
--   口徑：律師端計數（一案多律師重複計）、公開裁判書＝下限；事務所歸戶 lawyers_combined 唯一名（同名多筆不歸戶、不算喆律）
--   專注度 share＝該領域件數 ÷ 該律師同範圍（同法院或全國、同期間）全部出庭件數，只對回傳的 TOP N 列計算
--   本頁原用的 cause_top_lawyers／cause_group_year_kpi／cause_court_top_lawyers 函式保留（案由供需等頁仍用）
CREATE INDEX IF NOT EXISTS idx_lccs_name_court ON lawyer_cause_court_stats (name, court_name);

CREATE OR REPLACE FUNCTION cause_lawyer_list(p_group text, p_year int DEFAULT NULL, p_court text DEFAULT NULL, p_limit int DEFAULT 250)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lo text; hi text; res json;
BEGIN
  IF p_group IS NULL THEN RETURN json_build_object('rows', '[]'::json); END IF;
  IF p_year IS NOT NULL THEN lo := p_year::text || '01'; hi := p_year::text || '12'; END IF;

  WITH per AS (
    SELECT s.name, (s.by_group->>p_group)::int AS c, s.cases_5yr AS total
    FROM lawyer_cause_stats s
    WHERE p_court IS NULL AND p_year IS NULL AND coalesce((s.by_group->>p_group)::int, 0) > 0
    UNION ALL
    SELECT y.name, y.case_count, NULL::int
    FROM lawyer_cause_year_stats y
    WHERE p_court IS NULL AND p_year IS NOT NULL AND y.cause_group = p_group AND y.yr = p_year
    UNION ALL
    SELECT s.name, s.case_count, NULL::int
    FROM lawyer_cause_court_stats s
    WHERE p_court IS NOT NULL AND p_year IS NULL AND s.cause_group = p_group AND s.court_name = p_court
    UNION ALL
    SELECT d.name, d.c, d.total FROM (
      SELECT l.name,
             sum((k.value)::int) FILTER (WHERE coalesce(m.cause_group, split_part(k.key, '|', 1)) = p_group)::int AS c,
             sum((k.value)::int)::int AS total
      FROM lawyer_month_stats l
      CROSS JOIN LATERAL jsonb_each_text(l.causes) k
      LEFT JOIN cause_group_map m ON m.ck = k.key
      WHERE p_court IS NOT NULL AND p_year IS NOT NULL
        AND l.court_name = p_court AND l.yyyymm BETWEEN lo AND hi AND l.causes IS NOT NULL
      GROUP BY l.name
    ) d WHERE d.c > 0
  ), firm AS (
    SELECT lc.name, min(lc.firm_name) AS firm_name, count(*) AS n
    FROM lawyers_combined lc WHERE lc.firm_name IS NOT NULL GROUP BY lc.name
  ), j AS (
    SELECT p.name, p.c, p.total,
           CASE WHEN f.n = 1 THEN f.firm_name END AS firm_name,
           coalesce(f.n, 0) > 1 AS firm_ambiguous,
           (f.n = 1 AND f.firm_name LIKE '%喆律%') AS is_zhelu
    FROM per p LEFT JOIN firm f ON f.name = p.name
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
ALTER FUNCTION cause_lawyer_list(text, int, text, int) SET statement_timeout = '60s';
ALTER FUNCTION cause_lawyer_list(text, int, text, int) SET plan_cache_mode = 'force_custom_plan';
GRANT EXECUTE ON FUNCTION cause_lawyer_list(text, int, text, int) TO anon, authenticated;
