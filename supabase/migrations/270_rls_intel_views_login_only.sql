-- 270：情報站產業 view／表收成「登入後才可讀」，匿名（anon key）一律讀不到（2026-11-05）
-- 背景：public schema 的產業 view 沒設 security_invoker（以 postgres／bypassrls 執行）又 GRANT 給 anon，
--   網頁原始碼裡的 anon key 不登入就能 GET /rest/v1/lawyers_combined（含法務部名冊 email／電話／地址）。
--   另有 8 張表 policy 是 USING (true)、2 張 tipo_* 表 roles 明列 anon。資料本身是公開來源、嚴重度低，
--   但站有登入閘，就不該讓匿名直打。兩站共用 auth 池的背景見 lawyer-dashboard-clean 的
--   20261105170000_rls_zhelu_user_gate.sql 與本 repo mig 269（喆律內部表與 11 支喆律 view 已另案處理）。
--
-- 刻意保留匿名的兩樣（書籤助手頁 public/tools/moj-harvest.html 是靜態頁、只拿 anon key、沒有登入流程）：
--   · view moj_harvest_progress：頁面用 anon key 讀進度（只有查詢字串＋筆數／時間聚合，不含姓名證號）。
--     依賴 moj_harvest_queries（RLS 開、無 policy）與 moj_search_harvest（admin-only 讀），
--     必須以 owner 執行才讀得到，所以不能設 security_invoker。
--   · RPC moj_harvest_submit（SECURITY DEFINER，頁面唯一的寫入入口）：本 migration 不動它的 EXECUTE。
--   直接對 moj_search_harvest 的 anon INSERT 是多餘的（頁面走 RPC），順手收掉，避免繞過 RPC 的格式檢查直接灌表。
--
-- 不在本 migration 範圍：SECURITY DEFINER 的產業統計 RPC（cause_*／firm_*／region_*／gov_* 等約百支）
--   目前 anon 仍可呼叫，需另案逐支確認呼叫端後收回 EXECUTE。
--
-- 套用方式：Management API／SQL Editor 皆可；不用 NOTIFY pgrst（ALTER VIEW／ALTER POLICY／REVOKE 的
--   DDL event trigger 會自己觸發 schema reload）。套前先確認 pg_stat_activity 沒有長 refresh。
BEGIN;
SET LOCAL lock_timeout = '5s';

-- (A) 以 owner 身分執行的產業 view：改 security_invoker（走呼叫者的 RLS）＋收回 anon ----------
-- 底層表的 SELECT policy 都是 auth.uid() IS NOT NULL（或 authenticated＋true），登入者讀到的列數不變。
ALTER VIEW public.firm_indep_directorships       SET (security_invoker = true);
ALTER VIEW public.ind_firm_size_distribution     SET (security_invoker = true);
ALTER VIEW public.ind_lawyer_region_distribution SET (security_invoker = true);
ALTER VIEW public.ind_yearly_new_lawyers         SET (security_invoker = true);
ALTER VIEW public.indep_director_lawyer_matches  SET (security_invoker = true);
ALTER VIEW public.judges_combined                SET (security_invoker = true);
ALTER VIEW public.lawyers_combined               SET (security_invoker = true);
ALTER VIEW public.lawyers_with_stats             SET (security_invoker = true);
ALTER VIEW public.moj_solo_firm_lawyers          SET (security_invoker = true);

REVOKE SELECT ON public.firm_indep_directorships       FROM anon;
REVOKE SELECT ON public.ind_firm_size_distribution     FROM anon;
REVOKE SELECT ON public.ind_lawyer_region_distribution FROM anon;
REVOKE SELECT ON public.ind_yearly_new_lawyers         FROM anon;
REVOKE SELECT ON public.indep_director_lawyer_matches  FROM anon;
REVOKE SELECT ON public.judges_combined                FROM anon;
REVOKE SELECT ON public.lawyers_combined               FROM anon;
REVOKE SELECT ON public.lawyers_with_stats             FROM anon;
REVOKE SELECT ON public.moj_solo_firm_lawyers          FROM anon;

-- (B) 本來就是 security_invoker、但仍 GRANT 給 anon 的 view：只收回 anon -------------------------
REVOKE SELECT ON public.cn_firm_latest_signals     FROM anon;
REVOKE SELECT ON public.field_note_overview_status FROM anon;
REVOKE SELECT ON public.firm_dedup_totals          FROM anon;
REVOKE SELECT ON public.gov_firm_stats             FROM anon;
REVOKE SELECT ON public.gov_lawyer_tenders         FROM anon;

-- (C) materialized view 不支援 security_invoker（讀取不走 RLS），只能收回 anon ------------------
REVOKE SELECT ON public.corp_firm_ranking_mv    FROM anon;
REVOKE SELECT ON public.corp_lawyer_ranking_mv  FROM anon;
REVOKE SELECT ON public.corp_unrepresented_mv   FROM anon;

-- (D) policy 為 USING (true) 的表（roles=public，匿名可讀）→ 登入才可讀，並收回 anon 的表級 SELECT ---
ALTER POLICY read_blc  ON public.business_line_causes USING (auth.uid() IS NOT NULL);
ALTER POLICY read_bly  ON public.business_line_yearly USING (auth.uid() IS NOT NULL);
ALTER POLICY read_cgc  ON public.cause_group_causes   USING (auth.uid() IS NOT NULL);
ALTER POLICY read_ccs  ON public.clerk_court_snapshot USING (auth.uid() IS NOT NULL);
ALTER POLICY read_ces  ON public.clerk_exam_stats     USING (auth.uid() IS NOT NULL);
ALTER POLICY read_css  ON public.clerk_staff_stats    USING (auth.uid() IS NOT NULL);
ALTER POLICY read_eps  ON public.exam_pipeline_stats  USING (auth.uid() IS NOT NULL);
ALTER POLICY "allow read" ON public.lawyer_name_aliases USING (auth.uid() IS NOT NULL);

-- roles 明列 anon 的兩張 tipo 表：連 policy 對象一併改成 authenticated
ALTER POLICY tipo_agent_stats_read ON public.tipo_agent_stats TO authenticated USING (auth.uid() IS NOT NULL);
ALTER POLICY tipo_firm_stats_read  ON public.tipo_firm_stats  TO authenticated USING (auth.uid() IS NOT NULL);

REVOKE SELECT ON public.business_line_causes FROM anon;
REVOKE SELECT ON public.business_line_yearly FROM anon;
REVOKE SELECT ON public.cause_group_causes   FROM anon;
REVOKE SELECT ON public.clerk_court_snapshot FROM anon;
REVOKE SELECT ON public.clerk_exam_stats     FROM anon;
REVOKE SELECT ON public.clerk_staff_stats    FROM anon;
REVOKE SELECT ON public.exam_pipeline_stats  FROM anon;
REVOKE SELECT ON public.lawyer_name_aliases  FROM anon;
REVOKE SELECT ON public.tipo_agent_stats     FROM anon;
REVOKE SELECT ON public.tipo_firm_stats      FROM anon;

-- (E) policy 對象本來就只有 authenticated、但條件寫 true 的表：統一成 auth.uid() IS NOT NULL（行為不變，
--     之後掃 policy 不會再把它們列為「條件為 true」）------------------------------------------
ALTER POLICY corp_lawyer_pairs_read   ON public.corp_lawyer_pairs         USING (auth.uid() IS NOT NULL);
ALTER POLICY corp_litigants_read      ON public.corp_litigants            USING (auth.uid() IS NOT NULL);
ALTER POLICY gov_tender_firms_auth_read ON public.gov_tender_firms        USING (auth.uid() IS NOT NULL);
ALTER POLICY gov_tenders_auth_read    ON public.gov_tenders               USING (auth.uid() IS NOT NULL);
ALTER POLICY idp_auth_read            ON public.indep_director_profiles   USING (auth.uid() IS NOT NULL);
ALTER POLICY lid_auth_read            ON public.lawyer_indep_directorships USING (auth.uid() IS NOT NULL);
ALTER POLICY lci_auth_read            ON public.listed_company_insiders   USING (auth.uid() IS NOT NULL);

-- (F) 書籤助手收成表：頁面只走 RPC moj_harvest_submit（SECURITY DEFINER），不需要 anon 直接 INSERT ----
ALTER POLICY harvest_insert_any ON public.moj_search_harvest TO authenticated WITH CHECK (auth.uid() IS NOT NULL);
ALTER POLICY harvest_insert_any ON public.moj_search_harvest RENAME TO harvest_insert_authenticated;
REVOKE INSERT ON public.moj_search_harvest FROM anon;
REVOKE USAGE, SELECT ON SEQUENCE public.moj_search_harvest_id_seq FROM anon;

-- (G) 自我檢查：除了書籤助手的進度 view，不得再有 anon 可讀的 view／materialized view ----------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')
    AND has_table_privilege('anon', c.oid, 'SELECT')
    AND c.relname <> 'moj_harvest_progress';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION '仍有 anon 可讀的 view：%', bad;
  END IF;
END $$;

COMMIT;
