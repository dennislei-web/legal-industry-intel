-- ============================================================
-- 017: lawyer_stats_cache - KPI 快取表
-- ============================================================
-- 問題：lawyers_combined 是 VIEW，每次 count(*) 都要即時計算
-- overview + 律師 tab 總共 7+ 次全表掃描，極慢
-- 解法：建一個 stats cache 表，定期刷新

CREATE TABLE IF NOT EXISTS lawyer_stats_cache (
  key TEXT PRIMARY KEY,
  value BIGINT NOT NULL DEFAULT 0,
  refreshed_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE lawyer_stats_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_lawyer_stats" ON lawyer_stats_cache
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 刷新函數
CREATE OR REPLACE FUNCTION refresh_lawyer_stats()
RETURNS VOID AS $$
BEGIN
  -- 清空並重建
  DELETE FROM lawyer_stats_cache;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION refresh_lawyer_stats() TO anon, authenticated;

-- 初始填充
SELECT refresh_lawyer_stats();
