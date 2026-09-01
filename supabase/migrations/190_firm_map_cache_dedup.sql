-- ============================================================
-- 190: 事務所版圖預設快取補去重欄（mig 189 配套）
-- ============================================================
-- firm_court_ranking v3 多了 dup_cases/dedup_cases；預設組合走的
-- firm_map_default_cache（mig 178）同步補欄，否則預設載入永遠名目。

ALTER TABLE firm_map_default_cache
  ADD COLUMN IF NOT EXISTS dup_cases BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dedup_cases BIGINT;

CREATE OR REPLACE FUNCTION refresh_firm_map_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $$
BEGIN
  CREATE TEMP TABLE _fresh_map ON COMMIT DROP AS
  SELECT rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, now() AS refreshed_at
  FROM firm_court_ranking(NULL, NULL, NULL);

  DELETE FROM firm_map_default_cache;
  INSERT INTO firm_map_default_cache (rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, refreshed_at)
  SELECT rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, refreshed_at FROM _fresh_map;
END;
$$;

GRANT EXECUTE ON FUNCTION refresh_firm_map_cache() TO service_role;

-- 立即刷一次（dup cache 未填時 dedup=cases，前端 fallback 名目呈現，無害）
SELECT refresh_firm_map_cache();
