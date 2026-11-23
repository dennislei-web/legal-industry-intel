-- 295：新增「檢視者」角色 viewer（2026-11-23）
-- 需求：給同仁一個帳號，看得到管理員才有的頁面（喆律戰情各分頁、系統＞資料來源、事務所 modal 的田野筆記／官網對照），
--       但看不到「010 合作律師」，也不能管帳號、不能改資料。
--
-- 為什麼不直接給 role='admin' 再把 010 分頁藏起來：
--   · admin_reset_password()／admin-users Edge Function 讓 admin 能重設任何人的密碼——auth 池與喆律儀表板共用，
--     等於能拿到任何帳號（含儀表板管理員）。
--   · is_bullying_admin() 把 user_profiles.role='admin' 也當成職場霸凌戰情室的管理員；cn_insights 同理。
--   · admin 可直接改 user_profiles（含自己的列），任何「admin 但少看一頁」的旗標都能自己拿掉。
--   所以另立角色：讀取放行、寫入與帳號管理一律不給。
--
-- 做法：
--   1. user_profiles.role 允許 'viewer'。
--   2. is_intel_viewer()＝role 是 admin 或 viewer 且未停用。is_intel_admin() 不動（仍只認 admin）。
--   3. 情報站管理員頁面讀的 13 張表，SELECT policy 改用 is_intel_viewer()。寫入 policy 全部不動。
--   4. firm_area_ranking()／firm_area_specialists() 內的 is_intel_admin() 換成 is_intel_viewer()（都是唯讀）。
--
-- 刻意不放行（viewer 讀不到）：
--   · law010_lawyer_summary（view 內寫死 role='admin'，mig 075）——010 合作律師
--   · user_profiles 全表、intel_usage_daily、intel_usage_summary()——帳號管理頁
--   · moj_search_harvest——沒有頁面在讀
--   · labor_comp_series 的非公開列——頁面走 labor_comp_series_get()，本來就只回公開列
--   · cn_insights——中國律所站的表，不屬於本站
--
-- 套用方式：Management API／SQL Editor／supabase db query 皆可。套前先確認 pg_stat_activity 沒有長 refresh
--   （ALTER POLICY 要拿表的排他鎖；lock_timeout 5 秒，拿不到就整筆 rollback）。可重複套用。
BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. 角色值 -------------------------------------------------------------------------------------------
ALTER TABLE public.user_profiles DROP CONSTRAINT IF EXISTS user_profiles_role_check;
ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_role_check CHECK (role = ANY (ARRAY['admin'::text, 'viewer'::text, 'user'::text]));

COMMENT ON COLUMN public.user_profiles.role IS
  'admin＝全部（含帳號管理、010 合作律師、寫入）；viewer＝管理員頁面唯讀，不含 010 合作律師與帳號管理（mig 295）；user＝一般頁面';

-- 2. 讀取用的角色判斷 -----------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_intel_viewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role IN ('admin', 'viewer') AND is_active IS NOT FALSE
  );
$$;
-- 與 is_intel_admin() 同一組授權：有兩條 policy 是 roles=public，anon 查表時也會評估（anon 一律回 false）
REVOKE ALL ON FUNCTION public.is_intel_viewer() FROM public;
GRANT EXECUTE ON FUNCTION public.is_intel_viewer() TO anon, authenticated, service_role;

-- 3. 管理員頁面的讀取 policy --------------------------------------------------------------------------
-- 合夥人訪談筆記（＋薪資分析頁的面試筆記市場帶）
ALTER POLICY field_note_dimensions_admin_read  ON public.field_note_dimensions  USING (public.is_intel_viewer());
ALTER POLICY field_note_overviews_admin_read   ON public.field_note_overviews   USING (public.is_intel_viewer());
ALTER POLICY firm_field_facts_admin_read       ON public.firm_field_facts       USING (public.is_intel_viewer());
ALTER POLICY firm_field_notes_admin_read       ON public.firm_field_notes       USING (public.is_intel_viewer());
ALTER POLICY interview_market_bands_admin_read ON public.interview_market_bands USING (public.is_intel_viewer());
-- 產業深度報告／事務所版圖官網欄／事務所 modal 官網對照
ALTER POLICY auth_read_firm_analysis_facts     ON public.firm_analysis_facts    USING (public.is_intel_viewer());
ALTER POLICY firm_area_cases_admin_read        ON public.firm_area_cases        USING (public.is_intel_viewer());
ALTER POLICY admin_read_firm_collab_groups     ON public.firm_collab_groups     USING (public.is_intel_viewer());
ALTER POLICY firm_site_facts_admin_read        ON public.firm_site_facts        USING (public.is_intel_viewer());
-- 產業觀察
ALTER POLICY industry_watch_reports_admin_read ON public.industry_watch_reports USING (public.is_intel_viewer());
-- 併購觀察名單
ALTER POLICY ip_watchlist_admin_read           ON public.ip_watchlist           USING (public.is_intel_viewer());
-- 喆律校友會（寫入的三條 admin policy 不動）
ALTER POLICY zhelu_alumni_admin_read           ON public.zhelu_alumni           USING (public.is_intel_viewer());
-- 法律產業薪資分析：喆律池級年資帶（儀表板側的 has_salary_access() 照舊）
ALTER POLICY hr_pay_bands_select               ON public.hr_pay_bands
  USING (public.has_salary_access() OR public.is_intel_viewer());

-- 4. 兩支唯讀 RPC：函數本體原樣保留，只換角色判斷（pg_get_functiondef 會帶回 SECURITY DEFINER 與 SET，授權不受影響）----
DO $$
DECLARE
  r record;
  v_def text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('firm_area_ranking', 'firm_area_specialists')
  LOOP
    v_def := pg_get_functiondef(r.oid);
    IF position('public.is_intel_admin()' IN v_def) > 0 THEN
      EXECUTE replace(v_def, 'public.is_intel_admin()', 'public.is_intel_viewer()');
    ELSIF position('public.is_intel_viewer()' IN v_def) = 0 THEN
      RAISE EXCEPTION '% 內找不到 is_intel_admin()／is_intel_viewer()，函數已被改寫，請人工確認', r.proname;
    END IF;
  END LOOP;
END $$;

COMMIT;
