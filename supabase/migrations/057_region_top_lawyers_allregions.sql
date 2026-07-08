-- region_top_lawyers 支援「全部地區」：p_region NULL 時跨地區加總（全國最活躍律師）
-- 同簽名 CREATE OR REPLACE，只改 WHERE 讓 p_region 可為 NULL
CREATE OR REPLACE FUNCTION region_top_lawyers(p_region text DEFAULT NULL, p_year int DEFAULT NULL,
                                              p_cat text DEFAULT NULL, p_limit int DEFAULT 20)
RETURNS TABLE(name text, cases bigint) AS $$
  SELECT name, sum(case_count)::bigint AS c
  FROM lawyer_region_year_stats
  WHERE (p_region IS NULL OR region = p_region)
    AND (p_year IS NULL OR yr = p_year)
    AND (p_cat IS NULL OR cat = p_cat)
  GROUP BY name ORDER BY c DESC, name
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_top_lawyers(text, int, text, int) SET statement_timeout = '30s';
