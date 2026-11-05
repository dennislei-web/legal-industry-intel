-- 269：情報站自己的兩張表也別再「登入即可讀」（2026-11-05）
-- user_profiles：一般使用者只讀自己那列（登入時查角色），admin 讀全部（帳號管理頁走 admin-users Edge Function，service_role）。
-- firm_analysis_facts：產業深度報告是 admin-only tab，DB 也只給 admin（寫入走 service key 腳本）。
-- 兩站共用 auth 池的背景與儀表板側修法見 lawyer-dashboard-clean/supabase/migrations/20261105170000_rls_zhelu_user_gate.sql
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.is_intel_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = 'admin' AND is_active IS NOT FALSE
  );
$$;
REVOKE ALL ON FUNCTION public.is_intel_admin() FROM public;
GRANT EXECUTE ON FUNCTION public.is_intel_admin() TO anon, authenticated, service_role;

ALTER POLICY auth_read_profiles ON public.user_profiles USING (id = auth.uid() OR public.is_intel_admin());
ALTER POLICY admin_update_profiles ON public.user_profiles USING (public.is_intel_admin());
ALTER POLICY admin_insert_profiles ON public.user_profiles WITH CHECK (public.is_intel_admin());
ALTER POLICY auth_read_firm_analysis_facts ON public.firm_analysis_facts USING (public.is_intel_admin());

COMMIT;
