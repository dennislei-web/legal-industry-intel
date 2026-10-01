-- ============================================================
-- 237: refresh_firm_map_cache 的 DELETE 補 WHERE（pg-safeupdate 地雷）
-- ============================================================
-- 症狀：moj-office-refresh.yml 每日以 PostgREST RPC 呼叫 refresh_firm_map_cache，
-- 自 2026-08-31 接上排程的第一次起就一律 HTTP 400：
--   {"code":"21000","message":"DELETE requires a WHERE clause"}
-- workflow 把 4xx 當 non-fatal warning，firm_map_default_cache 因此一個月沒更新
-- （max(refreshed_at) 停在 2026-09-02 06:20 UTC＝mig 190 檔尾的首刷），事務所版圖
-- 預設載入不含之後才上傳的月份（如 2026-09-21 上傳的 202607）。
--
-- 原因：PostgREST 連線用的 authenticator role 帶
--   session_preload_libraries=safeupdate
-- 無 WHERE 的 DELETE／UPDATE 在 parse 階段就被擋。這是 session 層 hook，
-- SECURITY DEFINER 換了執行身分也照擋。`supabase db query --linked` 走
-- Management API（postgres role、不載 safeupdate），所以 mig 178／190 檔尾的
-- SELECT refresh_firm_map_cache() 會成功、排程卻天天失敗——
-- 「直連跑過」不代表「PostgREST 路徑會過」。
--
-- 修法：函數內容與 mig 190 完全相同，只把 DELETE 補上 WHERE true（語意不變）。
-- 刻意不在檔尾首刷：驗證要走 PostgREST RPC 才測得到 safeupdate 路徑。
--
-- 附記（2026-10-01 實測，PostgREST v14.4）：本函數通常跑 6～7 秒，但不時超過
-- authenticator 的 statement_timeout=8s（抽查 CI 11 次有 3 次，最長 18.6 秒），
-- RPC 卻不會被砍——PostgREST 會把函數層 SET statement_timeout 提升（hoist）成
-- 交易層設定，所以下面那行 SET 不是裝飾、不可拿掉。前提是 schema cache 已載到
-- 該設定：剛 CREATE／ALTER 完的數十秒內仍沿用舊值（要立刻生效就
-- NOTIFY pgrst, 'reload schema'）。

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

  -- WHERE true 不可省：PostgREST 路徑載入 pg-safeupdate，無 WHERE 的 DELETE 會回 400
  DELETE FROM firm_map_default_cache WHERE true;
  INSERT INTO firm_map_default_cache (rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, refreshed_at)
  SELECT rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, refreshed_at FROM _fresh_map;
END;
$$;

GRANT EXECUTE ON FUNCTION refresh_firm_map_cache() TO service_role;
