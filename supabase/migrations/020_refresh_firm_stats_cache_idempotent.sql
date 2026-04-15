-- ============================================================
-- 020: refresh_firm_stats_cache RPC 改為 idempotent UPSERT
-- ============================================================
-- 問題：原 RPC（直接在 Supabase Dashboard 定義，未進 migrations）用
--   TRUNCATE moj_firm_stats_cache; INSERT ... SELECT FROM moj_firm_statistics();
-- 整段在單一 transaction 內，TRUNCATE 取得 ACCESS EXCLUSIVE lock，
-- 加上 SELECT 跑全表 regex 聚合，常超過 100s → Cloudflare 521 → workflow
-- step "Refresh firm stats cache" 用 curl -sk 不檢查狀態，假裝成功，後續
-- step 接著查 Supabase 拿到空 body 炸掉。
--
-- 修法：
-- 1. 確保 firm_name 上有 UNIQUE constraint（UPSERT 需要）
-- 2. 改用 temp table → UPSERT → DELETE 已消失的事務所
--    避免 TRUNCATE 鎖表，前端讀取永遠有資料
-- 3. SET statement_timeout = '600s' 讓 server 端撐過 CF 100s 上限
--    （搭配 workflow fire-and-forget pattern）
-- ============================================================

-- (1) 確保 firm_name UNIQUE（UPSERT 必要條件）
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'moj_firm_stats_cache'::regclass
      AND contype = 'u'
      AND conkey = ARRAY[
        (SELECT attnum FROM pg_attribute
          WHERE attrelid = 'moj_firm_stats_cache'::regclass
            AND attname = 'firm_name')
      ]
  ) THEN
    ALTER TABLE moj_firm_stats_cache
      ADD CONSTRAINT moj_firm_stats_cache_firm_name_key UNIQUE (firm_name);
  END IF;
END $$;

-- (2) 重寫 RPC
CREATE OR REPLACE FUNCTION refresh_firm_stats_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $$
BEGIN
  -- Staging：先把新統計算到 temp table，避免 cache 被長時間鎖
  CREATE TEMP TABLE _fresh_stats ON COMMIT DROP AS
  SELECT firm_name, lawyer_count, main_region, avg_cases, website_url, now() AS refreshed_at
  FROM moj_firm_statistics();

  -- UPSERT：已存在的 row 更新欄位，新事務所插入
  INSERT INTO moj_firm_stats_cache
    (firm_name, lawyer_count, main_region, avg_cases, website_url, refreshed_at)
  SELECT firm_name, lawyer_count, main_region, avg_cases, website_url, refreshed_at
  FROM _fresh_stats
  ON CONFLICT (firm_name) DO UPDATE SET
    lawyer_count  = EXCLUDED.lawyer_count,
    main_region   = EXCLUDED.main_region,
    avg_cases     = EXCLUDED.avg_cases,
    website_url   = EXCLUDED.website_url,
    refreshed_at  = EXCLUDED.refreshed_at;

  -- 移除已不存在的事務所（合併、改名等情況）
  DELETE FROM moj_firm_stats_cache c
  WHERE NOT EXISTS (
    SELECT 1 FROM _fresh_stats f WHERE f.firm_name = c.firm_name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION refresh_firm_stats_cache() TO anon, authenticated, service_role;
