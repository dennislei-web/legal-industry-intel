-- 家事律師版圖「按年」cache：支援前端年度切換檢視
-- 口徑同 migration 040/049（2020-01 起、公開裁判書、家事字別自 cats 辨識），僅多 year 維度。
-- 年切片門檻 HAVING >= 1（5 年合計表維持 >= 3 不變）；單年資料量實測 3.5k-5.7k 律師列。
-- refresh_family_lawyer_stats()（migration 049）擴充為連年表一起刷新，
-- judgment_stats.py 月更呼叫點不用改。

CREATE TABLE IF NOT EXISTS family_lawyer_year_cache (
  name text NOT NULL,
  year text NOT NULL,
  family_cases bigint NOT NULL,
  total_cases bigint NOT NULL,
  family_share numeric,
  n_courts int,
  top_court text,
  firm_name text,
  firm_ambiguous boolean,
  refreshed_at timestamptz DEFAULT now(),
  PRIMARY KEY (name, year)
);
CREATE INDEX IF NOT EXISTS idx_flyc_year_fam ON family_lawyer_year_cache (year, family_cases DESC, name);

CREATE TABLE IF NOT EXISTS family_lawyer_by_court_year_cache (
  name text NOT NULL,
  court_name text NOT NULL,
  year text NOT NULL,
  family_cases bigint NOT NULL,
  refreshed_at timestamptz DEFAULT now(),
  PRIMARY KEY (name, court_name, year)
);
CREATE INDEX IF NOT EXISTS idx_flbcy_year_fam ON family_lawyer_by_court_year_cache (year, family_cases DESC, name, court_name);

ALTER TABLE family_lawyer_year_cache ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_flyc" ON family_lawyer_year_cache;
CREATE POLICY "auth_read_flyc" ON family_lawyer_year_cache FOR SELECT USING (auth.uid() IS NOT NULL);

ALTER TABLE family_lawyer_by_court_year_cache ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_flbcy" ON family_lawyer_by_court_year_cache;
CREATE POLICY "auth_read_flbcy" ON family_lawyer_by_court_year_cache FOR SELECT USING (auth.uid() IS NOT NULL);

-- 按年版 family_lawyer_stats（口徑同 migration 040，多 year 維度、門檻 >= 1）
CREATE OR REPLACE FUNCTION family_lawyer_stats_by_year()
RETURNS TABLE (name text, year text, family_cases bigint, total_cases bigint, family_share numeric,
               n_courts int, top_court text, firm_name text, firm_ambiguous boolean) AS $$
  WITH per AS (
    SELECT name, left(yyyymm, 4) AS yr, court_name,
           sum(coalesce((cats->>'家事')::int, 0)) AS fam,
           sum(case_count) AS tot
    FROM lawyer_month_stats
    WHERE yyyymm >= '202001'
    GROUP BY 1, 2, 3
  ), agg AS (
    SELECT name, yr, sum(fam) AS fam, sum(tot) AS tot,
           (count(*) FILTER (WHERE fam > 0))::int AS n_courts
    FROM per GROUP BY 1, 2
    HAVING sum(fam) >= 1
  ), topc AS (
    SELECT DISTINCT ON (name, yr) name, yr, court_name
    FROM per WHERE fam > 0
    ORDER BY name, yr, fam DESC
  ), firm AS (
    SELECT name, min(firm_name) AS firm_name, count(*) AS n
    FROM lawyers_combined
    WHERE firm_name IS NOT NULL
    GROUP BY name
  )
  SELECT a.name, a.yr, a.fam::bigint, a.tot::bigint,
         round(a.fam::numeric / nullif(a.tot, 0), 3),
         a.n_courts, t.court_name,
         CASE WHEN f.n = 1 THEN f.firm_name END,
         coalesce(f.n, 0) > 1
  FROM agg a
  LEFT JOIN topc t ON t.name = a.name AND t.yr = a.yr
  LEFT JOIN firm f ON f.name = a.name
  ORDER BY a.yr, a.fam DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION family_lawyer_stats_by_year() SET statement_timeout = '300s';

CREATE OR REPLACE FUNCTION family_lawyer_by_court_by_year()
RETURNS TABLE (name text, court_name text, year text, family_cases bigint) AS $$
  SELECT name, court_name, left(yyyymm, 4) AS yr,
         sum(coalesce((cats->>'家事')::int, 0))::bigint AS fam
  FROM lawyer_month_stats
  WHERE yyyymm >= '202001'
  GROUP BY 1, 2, 3
  HAVING sum(coalesce((cats->>'家事')::int, 0)) >= 1
  ORDER BY 3, 4 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION family_lawyer_by_court_by_year() SET statement_timeout = '300s';

-- 前端年度下拉用：年 cache 現有的年度清單
CREATE OR REPLACE FUNCTION family_lawyer_years()
RETURNS TABLE (year text) AS $$
  SELECT DISTINCT year FROM family_lawyer_year_cache ORDER BY 1 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 擴充 049 的 refresh：5 年合計 + 按年四張表一次刷新（ETL 呼叫點名稱不變）
CREATE OR REPLACE FUNCTION refresh_family_lawyer_stats() RETURNS void AS $$
BEGIN
  TRUNCATE family_lawyer_stats_cache;
  INSERT INTO family_lawyer_stats_cache
    (name, family_cases, total_cases, family_share, n_courts,
     top_court, last_ym, firm_name, firm_ambiguous, refreshed_at)
  SELECT s.*, now() FROM family_lawyer_stats() s;

  TRUNCATE family_lawyer_by_court_cache;
  INSERT INTO family_lawyer_by_court_cache (name, court_name, family_cases, refreshed_at)
  SELECT s.*, now() FROM family_lawyer_by_court() s;

  TRUNCATE family_lawyer_year_cache;
  INSERT INTO family_lawyer_year_cache
    (name, year, family_cases, total_cases, family_share, n_courts,
     top_court, firm_name, firm_ambiguous, refreshed_at)
  SELECT s.*, now() FROM family_lawyer_stats_by_year() s;

  TRUNCATE family_lawyer_by_court_year_cache;
  INSERT INTO family_lawyer_by_court_year_cache (name, court_name, year, family_cases, refreshed_at)
  SELECT s.*, now() FROM family_lawyer_by_court_by_year() s;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_family_lawyer_stats() SET statement_timeout = '600s';

-- 立即填一次資料
SELECT refresh_family_lawyer_stats();
