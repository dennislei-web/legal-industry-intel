-- ============================================================
-- 256: refresh_* 重建函式收回 PUBLIC／anon／authenticated 執行權
-- ============================================================
-- 起因（2026-11-03，mig 255 順帶發現）：public schema 22 支 refresh_* 函式中，
--   19 支 PUBLIC／anon 可執行、2 支（refresh_firm_court_dup／refresh_firm_dedup_stats）
--   任何登入帳號可執行。前端公開金鑰寫在公開 repo 的 index.html，等於任何人都能觸發
--   TRUNCATE＋整表重算（佔 DB 資源，重建期間讀取會被鎖住等待）。
--   成因：Supabase 對新函式預設明確 GRANT anon／authenticated，舊 migration 多半只寫
--   GRANT service_role、沒有 REVOKE；`REVOKE ... FROM public` 也收不掉這兩條明確授權。
--
-- 盤點呼叫者（2026-11-03，全部 C:\projects 專案＋DB）：
--   GitHub Actions：35 處全用 secrets.SUPABASE_SERVICE_KEY（judgment-stats-monthly 等會寫入
--     只有讀取政策的 RLS 表且成功，證明是 service_role）；.github/scripts/refresh-rpcs.sh 同。
--   本機腳本：scripts/.env 的 SUPABASE_SERVICE_KEY（sb_secret＝service_role）。
--   巢狀呼叫：refresh_lawyer_cause_stats 等 SECURITY DEFINER（擁有者 postgres）內 PERFORM，不受影響。
--   前端（legal-industry-intel／lawyer-dashboard／bullying-intel）：沒有任何 rpc('refresh_*')，
--     index.html 只在註解與註腳文字提到函式名。pg_cron：無相關排程。其他函式：無引用。
--
-- 做法：對 public.refresh_* 全部（含參數版、排除 trigger 函式）REVOKE PUBLIC／anon／authenticated，
--   GRANT service_role。之後新增 refresh_* 函式要在同一個 migration 裡同樣 REVOKE（見 CLAUDE.md）。
--   刻意不改 ALTER DEFAULT PRIVILEGES：讀取用 RPC 有些靠預設授權給 anon／authenticated，改了會無聲壞掉。

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND left(p.proname, 8) = 'refresh_'
      AND p.prorettype <> 'trigger'::regtype
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
