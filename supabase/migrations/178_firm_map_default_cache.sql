-- ============================================================
-- 178: 事務所版圖預設組合快取
-- ============================================================
-- 問題：事務所總覽的「事務所版圖」預設載入（全部案類×全部法院×近5年）
-- 每次都現場跑 firm_court_ranking() 聚合整個 lawyer_month_stats（實測 4.5s+），
-- 加上三個下拉 RPC 串行 await，使用者要等近 10 秒才看得到排行。
-- 解法：預設組合結果落地快取表（日更 workflow 刷新），前端預設讀表秒開；
-- 使用者選了任何篩選才走 RPC 現算。

CREATE TABLE IF NOT EXISTS firm_map_default_cache (
  rank INT PRIMARY KEY,
  firm_name TEXT NOT NULL,
  cases BIGINT NOT NULL,
  lawyer_count INT NOT NULL,
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE firm_map_default_cache ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_firm_map_default" ON firm_map_default_cache;
CREATE POLICY "auth_read_firm_map_default" ON firm_map_default_cache
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 刷新函數：staging temp table → DELETE+INSERT（同 020 手法，避免 TRUNCATE 長鎖）
CREATE OR REPLACE FUNCTION refresh_firm_map_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $$
BEGIN
  CREATE TEMP TABLE _fresh_map ON COMMIT DROP AS
  SELECT rank, firm_name, cases, lawyer_count, now() AS refreshed_at
  FROM firm_court_ranking(NULL, NULL, NULL);

  DELETE FROM firm_map_default_cache;
  INSERT INTO firm_map_default_cache (rank, firm_name, cases, lawyer_count, refreshed_at)
  SELECT rank, firm_name, cases, lawyer_count, refreshed_at FROM _fresh_map;
END;
$$;

GRANT EXECUTE ON FUNCTION refresh_firm_map_cache() TO service_role;

-- 首刷（migration 內直接填，前端立刻有資料）
SELECT refresh_firm_map_cache();
