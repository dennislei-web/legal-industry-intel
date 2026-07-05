-- 檢察官總覽頁：年度具名案件量趨勢 RPC
-- 從 prosecutor_month_stats 按年彙總（months<12 前端標 *，表示該年裁判書未回填滿）

CREATE OR REPLACE FUNCTION prosecutor_cases_by_year()
RETURNS TABLE (year text, cases bigint, prosecutors bigint, months int) AS $$
  SELECT left(yyyymm, 4),
         sum(case_count)::bigint,
         count(DISTINCT name)::bigint,
         count(DISTINCT yyyymm)::int
  FROM prosecutor_month_stats
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION prosecutor_cases_by_year() TO anon, authenticated;
