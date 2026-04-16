-- ============================================================
-- 021: 修 refresh_lawyer_stats() — DELETE 改 TRUNCATE 避免
-- Supabase "DELETE requires a WHERE clause" 限制
-- + 加 statement_timeout 避免 CF 521
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_lawyer_stats()
RETURNS VOID AS $$
BEGIN
  TRUNCATE lawyer_stats_cache;

  INSERT INTO lawyer_stats_cache (key, value) VALUES
    ('total', (SELECT COUNT(*) FROM lawyers_combined)),
    ('has_moj', (SELECT COUNT(*) FROM lawyers_combined WHERE has_moj = true)),
    ('has_twba', (SELECT COUNT(*) FROM lawyers_combined WHERE has_twba = true)),
    ('has_lawsnote', (SELECT COUNT(*) FROM lawyers_combined WHERE has_lawsnote = true)),
    ('all_three', (SELECT COUNT(*) FROM lawyers_combined WHERE data_source = '三者皆有')),
    ('moj_raw', (SELECT COUNT(*) FROM moj_lawyers)),
    ('lawsnote_raw', (SELECT COUNT(*) FROM lawsnote_lawyers));

  UPDATE lawyer_stats_cache SET refreshed_at = now();
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '300s';

GRANT EXECUTE ON FUNCTION refresh_lawyer_stats() TO anon, authenticated, service_role;

-- 立即執行一次
SELECT refresh_lawyer_stats();
