-- 各地區供需總表：以「活躍律師」為分母的供需比
-- 一次回傳所有地區指定年度的活躍律師數（active = 該地區該年公開裁判書出庭 >= p_min 案，
-- 與 region_active_counts 同口徑），供前端與公會執業數並列比較。
CREATE OR REPLACE FUNCTION region_active_by_region(p_year int DEFAULT NULL, p_min int DEFAULT 5,
                                                   p_cat text DEFAULT NULL)
RETURNS TABLE(region text, active_lawyers bigint) AS $$
  SELECT region, count(*)::bigint
  FROM (
    SELECT region, name, sum(case_count) AS c
    FROM lawyer_region_year_stats
    WHERE (p_year IS NULL OR yr = p_year)
      AND (p_cat IS NULL OR cat = p_cat)
    GROUP BY region, name
  ) s
  WHERE c >= p_min
  GROUP BY region;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_active_by_region(int, int, text) SET statement_timeout = '30s';
