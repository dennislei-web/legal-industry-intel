-- 261：領域律師版圖四磚隨年度切換（原「領域判決件數／供給律師數／喆律該領域案量」三磚寫死近 5 年滾動，
--   年度下拉只動名單與 TOP1 磚，使用者切年看不到大數字變化；2026-11-04）
--   cause_group_year_kpi(p_group, p_year)：該種類×該年的 判決件數／供給律師數／喆律案量／喆律律師數
--   口徑同 cause_supply_stats（mig 093）與 lawyer_cause_court_stats（mig 182）：
--   律師端計數（一案多律師重複計）、事務所歸戶走 lawyers_combined 唯一名（同名多筆不歸戶、不算喆律）
--   全表歸戶 CTE 實測 150 ms，不另物化；p_year NULL 時前端沿用原近 5 年路徑，本函式不處理
CREATE OR REPLACE FUNCTION cause_group_year_kpi(p_group text, p_year int)
RETURNS TABLE (total_cases bigint, lawyers bigint, zhelu_cases bigint, zhelu_lawyers bigint) AS $$
  WITH y AS (
    SELECT name, case_count FROM lawyer_cause_year_stats
    WHERE cause_group = p_group AND yr = p_year
  ), firm AS (
    SELECT name, min(firm_name) AS firm_name, count(*) AS n
    FROM lawyers_combined WHERE firm_name IS NOT NULL GROUP BY name
  ), j AS (
    SELECT y.name, y.case_count, (f.n = 1 AND f.firm_name LIKE '%喆律%') AS is_zhelu
    FROM y LEFT JOIN firm f USING (name)
  )
  SELECT coalesce(sum(case_count), 0)::bigint,
         count(*)::bigint,
         coalesce(sum(case_count) FILTER (WHERE is_zhelu), 0)::bigint,
         count(*) FILTER (WHERE is_zhelu)::bigint
  FROM j;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_group_year_kpi(text, int) SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_group_year_kpi(text, int) TO anon, authenticated;
