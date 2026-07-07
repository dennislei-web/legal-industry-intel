-- 家事律師版圖 cache 表：取代前端直呼 family_lawyer_stats/by_court RPC
-- 背景：PostgREST 對 RPC 的 .range() 分頁是「每頁重新執行整個函數」，
--   family_lawyer_stats 5,828 列 + by_court 8,161 列 = 15 頁 × 每頁 2-4 秒全表聚合，
--   家事律師 tab 載入 30 秒起跳。materialize 成表後前端分頁走索引，毫秒級。
-- refresh_family_lawyer_stats()：TRUNCATE + INSERT（重用既有 RPC 的查詢邏輯），
--   由 judgment_stats.py refresh_stats() 月更一併呼叫（同 refresh_lawyer_judgment_stats 模式）

CREATE TABLE IF NOT EXISTS family_lawyer_stats_cache (
  name text PRIMARY KEY,
  family_cases bigint NOT NULL,
  total_cases bigint NOT NULL,
  family_share numeric,
  n_courts int,
  top_court text,
  last_ym text,
  firm_name text,
  firm_ambiguous boolean,
  refreshed_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_flsc_fam ON family_lawyer_stats_cache (family_cases DESC, name);

CREATE TABLE IF NOT EXISTS family_lawyer_by_court_cache (
  name text NOT NULL,
  court_name text NOT NULL,
  family_cases bigint NOT NULL,
  refreshed_at timestamptz DEFAULT now(),
  PRIMARY KEY (name, court_name)
);
CREATE INDEX IF NOT EXISTS idx_flbc_fam ON family_lawyer_by_court_cache (family_cases DESC, name, court_name);

ALTER TABLE family_lawyer_stats_cache ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_flsc" ON family_lawyer_stats_cache;
CREATE POLICY "auth_read_flsc" ON family_lawyer_stats_cache FOR SELECT USING (auth.uid() IS NOT NULL);

ALTER TABLE family_lawyer_by_court_cache ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_flbc" ON family_lawyer_by_court_cache;
CREATE POLICY "auth_read_flbc" ON family_lawyer_by_court_cache FOR SELECT USING (auth.uid() IS NOT NULL);

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
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_family_lawyer_stats() SET statement_timeout = '300s';

-- 立即填一次資料
SELECT refresh_family_lawyer_stats();
