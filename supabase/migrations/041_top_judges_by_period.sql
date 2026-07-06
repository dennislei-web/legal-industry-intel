-- 041: 案件量 TOP 法官按期間查詢（前端總覽頁年度切換用）
-- 從 judge_month_stats 依 yyyymm 區間聚合，前端再做名冊過濾後取前 10

CREATE OR REPLACE FUNCTION top_judges_by_period(p_from text, p_to text, p_limit int DEFAULT 60)
RETURNS TABLE(name text, court_name text, case_count bigint)
LANGUAGE sql STABLE
SET statement_timeout = '30s'
AS $$
  SELECT m.name, m.court_name, sum(m.case_count) AS case_count
  FROM judge_month_stats m
  WHERE m.yyyymm >= p_from AND m.yyyymm <= p_to
  GROUP BY m.name, m.court_name
  ORDER BY 3 DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION top_judges_by_period(text, text, int) TO authenticated, service_role;
