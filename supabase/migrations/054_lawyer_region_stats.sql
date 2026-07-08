-- 地區 × 年度 律師活動分析（訴訟市場趨勢頁用；判決書口徑=下限、非唯一案件數、同名合併）
-- 地區來源：court_name JOIN courts.region（縣市級，涵蓋 ~95% 案量；士林→台北、分院→所在縣市已對好）
--   排除最高法院/最高行政法院（全國級，避免灌爆台北）
-- lawyer_region_year_stats：物化 (律師×地區×年) 出庭數，refresh_lawyer_region_stats() 重建（掛月更）
--   規模：25k 律師多在 1–3 地區×~10 活躍年 → 稀疏，數十萬列，Micro 安全

CREATE TABLE IF NOT EXISTS lawyer_region_year_stats (
  name       text NOT NULL,
  region     text NOT NULL,
  yr         int  NOT NULL,
  case_count int  NOT NULL,
  PRIMARY KEY (name, region, yr)
);
CREATE INDEX IF NOT EXISTS idx_lrys_region_yr ON lawyer_region_year_stats (region, yr);
CREATE INDEX IF NOT EXISTS idx_lrys_name      ON lawyer_region_year_stats (name);

ALTER TABLE lawyer_region_year_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lrys" ON lawyer_region_year_stats;
CREATE POLICY "auth_read_lrys" ON lawyer_region_year_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_lawyer_region_stats() RETURNS void AS $$
BEGIN
  TRUNCATE lawyer_region_year_stats;
  INSERT INTO lawyer_region_year_stats (name, region, yr, case_count)
  SELECT m.name, c.region, left(m.yyyymm, 4)::int AS yr, sum(m.case_count)::int
  FROM lawyer_month_stats m
  JOIN courts c ON c.name = m.court_name
  WHERE c.region IS NOT NULL
    AND c.court_type NOT IN ('最高法院', '最高行政法院')
  GROUP BY 1, 2, 3;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_lawyer_region_stats() SET statement_timeout = '600s';

-- 地區清單（選擇器用；依案量排序）
CREATE OR REPLACE FUNCTION region_list()
RETURNS TABLE(region text, cases bigint, lawyers bigint) AS $$
  SELECT region, sum(case_count)::bigint, count(DISTINCT name)::bigint
  FROM lawyer_region_year_stats
  GROUP BY region ORDER BY 2 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_list() SET statement_timeout = '30s';

-- 某地區最活躍律師 top-N（p_year 給值=該年，NULL=全期）
CREATE OR REPLACE FUNCTION region_top_lawyers(p_region text, p_year int DEFAULT NULL, p_limit int DEFAULT 20)
RETURNS TABLE(name text, cases bigint) AS $$
  SELECT name, sum(case_count)::bigint AS c
  FROM lawyer_region_year_stats
  WHERE region = p_region AND (p_year IS NULL OR yr = p_year)
  GROUP BY name ORDER BY c DESC, name
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_top_lawyers(text, int, int) SET statement_timeout = '30s';

-- 每年度活躍律師數（p_region NULL=全國；active=該地區年出庭數 >= p_min）
CREATE OR REPLACE FUNCTION region_active_counts(p_region text DEFAULT NULL, p_min int DEFAULT 5)
RETURNS TABLE(yr int, active_lawyers bigint, total_cases bigint) AS $$
  SELECT yr, count(*)::bigint, sum(c)::bigint
  FROM (
    SELECT yr, name, sum(case_count) AS c
    FROM lawyer_region_year_stats
    WHERE (p_region IS NULL OR region = p_region)
    GROUP BY yr, name
  ) s
  WHERE c >= p_min
  GROUP BY yr ORDER BY yr;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_active_counts(text, int) SET statement_timeout = '30s';

-- 初次建置
SELECT refresh_lawyer_region_stats();
