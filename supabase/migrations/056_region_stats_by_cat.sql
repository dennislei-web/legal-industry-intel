-- 地區律師活動：加「案類」維度（民事/刑事/家事/行政/少年/懲戒/其他，即判決書 cats 原生分類）
-- 注意：判決書無「執行」獨立案類（強制執行歸民事）；執行市場總量請看訴訟市場趨勢的官方口徑。
-- 重建 lawyer_region_year_stats 加 cat 欄；RPC 加 p_cat（NULL=全部，保持既有行為）。

DROP FUNCTION IF EXISTS region_top_lawyers(text, int, int);
DROP FUNCTION IF EXISTS region_active_counts(text, int);
DROP TABLE IF EXISTS lawyer_region_year_stats;

CREATE TABLE lawyer_region_year_stats (
  name       text NOT NULL,
  region     text NOT NULL,
  yr         int  NOT NULL,
  cat        text NOT NULL,
  case_count int  NOT NULL,
  PRIMARY KEY (name, region, yr, cat)
);
CREATE INDEX idx_lrys_region_yr_cat ON lawyer_region_year_stats (region, yr, cat);
CREATE INDEX idx_lrys_name          ON lawyer_region_year_stats (name);

ALTER TABLE lawyer_region_year_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lrys" ON lawyer_region_year_stats;
CREATE POLICY "auth_read_lrys" ON lawyer_region_year_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_lawyer_region_stats() RETURNS void AS $$
BEGIN
  TRUNCATE lawyer_region_year_stats;
  INSERT INTO lawyer_region_year_stats (name, region, yr, cat, case_count)
  SELECT m.name, c.region, left(m.yyyymm, 4)::int AS yr, e.key AS cat, sum(e.value::int)
  FROM lawyer_month_stats m
  JOIN courts c ON c.name = m.court_name,
       jsonb_each_text(m.cats) e
  WHERE c.region IS NOT NULL
    AND c.court_type NOT IN ('最高法院', '最高行政法院')
  GROUP BY 1, 2, 3, 4;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_lawyer_region_stats() SET statement_timeout = '600s';

-- 地區清單（跨案類加總；選擇器用）
CREATE OR REPLACE FUNCTION region_list()
RETURNS TABLE(region text, cases bigint, lawyers bigint) AS $$
  SELECT region, sum(case_count)::bigint, count(DISTINCT name)::bigint
  FROM lawyer_region_year_stats
  GROUP BY region ORDER BY 2 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_list() SET statement_timeout = '30s';

-- 某地區最活躍律師 top-N（p_year NULL=全期；p_cat NULL=全部案類）
CREATE OR REPLACE FUNCTION region_top_lawyers(p_region text, p_year int DEFAULT NULL,
                                              p_cat text DEFAULT NULL, p_limit int DEFAULT 20)
RETURNS TABLE(name text, cases bigint) AS $$
  SELECT name, sum(case_count)::bigint AS c
  FROM lawyer_region_year_stats
  WHERE region = p_region
    AND (p_year IS NULL OR yr = p_year)
    AND (p_cat IS NULL OR cat = p_cat)
  GROUP BY name ORDER BY c DESC, name
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_top_lawyers(text, int, text, int) SET statement_timeout = '30s';

-- 每年度活躍律師數（p_region NULL=全國；p_cat NULL=全部案類；active=該地區年出庭 >= p_min）
CREATE OR REPLACE FUNCTION region_active_counts(p_region text DEFAULT NULL, p_min int DEFAULT 5,
                                                p_cat text DEFAULT NULL)
RETURNS TABLE(yr int, active_lawyers bigint, total_cases bigint) AS $$
  SELECT yr, count(*)::bigint, sum(c)::bigint
  FROM (
    SELECT yr, name, sum(case_count) AS c
    FROM lawyer_region_year_stats
    WHERE (p_region IS NULL OR region = p_region)
      AND (p_cat IS NULL OR cat = p_cat)
    GROUP BY yr, name
  ) s
  WHERE c >= p_min
  GROUP BY yr ORDER BY yr;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION region_active_counts(text, int, text) SET statement_timeout = '30s';

SELECT refresh_lawyer_region_stats();
