-- ============================================================
-- 022: 再修 refresh_lawyer_stats() — UPDATE 也需要 WHERE clause
-- ============================================================
-- 021 只改了 DELETE → TRUNCATE，但 UPDATE 仍無 WHERE。
-- Supabase 對 service_role 之外也會擋無 WHERE 的 UPDATE/DELETE。
-- 改法：把 refreshed_at 塞在 INSERT 裡就不用再 UPDATE。
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_lawyer_stats()
RETURNS VOID AS $$
BEGIN
  TRUNCATE lawyer_stats_cache;

  INSERT INTO lawyer_stats_cache (key, value, refreshed_at) VALUES
    ('total', (SELECT COUNT(*) FROM lawyers_combined), now()),
    ('has_moj', (SELECT COUNT(*) FROM lawyers_combined WHERE has_moj = true), now()),
    ('has_twba', (SELECT COUNT(*) FROM lawyers_combined WHERE has_twba = true), now()),
    ('has_lawsnote', (SELECT COUNT(*) FROM lawyers_combined WHERE has_lawsnote = true), now()),
    ('all_three', (SELECT COUNT(*) FROM lawyers_combined WHERE data_source = '三者皆有'), now()),
    ('moj_raw', (SELECT COUNT(*) FROM moj_lawyers), now()),
    ('lawsnote_raw', (SELECT COUNT(*) FROM lawsnote_lawyers), now());
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '300s';

GRANT EXECUTE ON FUNCTION refresh_lawyer_stats() TO anon, authenticated, service_role;

SELECT refresh_lawyer_stats();
