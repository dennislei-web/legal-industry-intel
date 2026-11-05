-- 271：SECURITY DEFINER 產業統計 RPC 收回匿名（anon）EXECUTE，只留登入使用者與後端（2026-11-05）
-- 背景：mig 270 已把產業 view／表收成登入後才可讀，但 116 支 SECURITY DEFINER RPC 仍對 anon 開放。
--   網頁原始碼裡的 anon key（公開金鑰）不登入就能 POST /rest/v1/rpc/<fn> 讀到產業統計，其中
--   cause_top_lawyers／region_top_lawyers／firm_flow_lawyers 這類還回律師姓名（改前實測 200 有資料）。
--   資料本身來自公開來源、嚴重度低，但站有登入閘，就不該讓匿名直打。
--
-- 為什麼要 REVOKE ... FROM PUBLIC, anon：函數建立時預設 PUBLIC 有 EXECUTE，Supabase 另外還對 anon、authenticated、
--   service_role 各有明列 grant（ACL 形如 =X/postgres,anon=X/postgres,...）。只 REVOKE FROM anon 沒用（PUBLIC 那條仍成立），
--   所以兩者一起收，再明列 GRANT authenticated, service_role 維持原有的登入使用者與後端權限。
--
-- 與 lawyer-dashboard 共用同一個 DB，所以不整批收；逐支確認呼叫端（情報站 public/index.html、lawyer-dashboard-clean、
--   bullying-intel、cn-lawfirm-intel、legal-industry-intel/scripts、各 Apps Script、RLS policy／view／trigger 內的引用）後分四組：
--   · 收回 anon（本檔 A～D 組，共 97 支）
--   · 刻意保留匿名（19 支，見檔尾註解）：
--       - moj_harvest_submit：書籤助手頁 public/tools/moj-harvest.html 是無登入靜態頁，只能靠它寫入
--       - speaking_calendar_ingest／speaking_calendar_sync：bullying-intel 的 Google Apps Script 只持 anon key＋專用 token
--         （函數內驗 b2b_sync_tokens 的 sha256，沒 token 回 invalid token），不能收
--       - 16 支「權限判斷」函數（is_admin／get_my_role／is_zhelu_user 等）：127 條 RLS policy 以 roles=public 呼叫它們，
--         anon 查這些表時 policy 會評估；收掉會讓匿名請求從「回 0 列」變成 permission denied 報錯，影響範圍不明。
--         它們只回呼叫者自己的角色布林值（anon 一律 false／NULL／空），不洩資料。
--
-- 套用方式：Management API／SQL Editor 皆可；不用 NOTIFY pgrst（REVOKE／GRANT 的 DDL event trigger 會自己觸發 schema reload）。
--   套前先確認 pg_stat_activity 沒有長 refresh（見 reference_postgrest_schema_reload_lock_outage）。
BEGIN;
SET LOCAL lock_timeout = '5s';

-- (A) 情報站 public/index.html 登入後才呼叫的 RPC（72 支）-------------------------------------------
REVOKE EXECUTE ON FUNCTION
    public.amount_rep_curve(text,text),
    public.cat_cases_by_year(text,text,integer),
    public.cat_judge_stats(text,text),
    public.cat_judge_stats_json(text,text),
    public.cat_same_period_stats(text,text),
    public.cause_court_list(text,text),
    public.cause_court_matrix(text,text,text),
    public.cause_group_list(),
    public.cause_group_yearly(text),
    public.cause_group_yearly_crim(),
    public.cause_lawyer_list(text,integer,text,integer,text),
    public.cause_raw_top(text,text,text,integer),
    public.cause_rep_yearly(text),
    public.cause_sub_group_list(),
    public.cause_supply_stats(text),
    public.cause_top_lawyers(text,integer,integer),
    public.cause_top_lawyers_cat(text,integer),
    public.cause_year_list(),
    public.change_regions(bigint[]),
    public.court_detail_stats(text),
    public.ex_judicial_overview_stats(),
    public.firm_cause_court_ranking(text,text,text,integer,integer),
    public.firm_cause_ranking(text,integer,integer),
    public.firm_cause_sub_ranking(text,text,integer,integer),
    public.firm_court_ranking(text,text,integer),
    public.firm_flow_lawyers(text,integer),
    public.firm_flow_overview(integer),
    public.firm_lawyer_year_stats(text[]),
    public.firm_turnover_stats(),
    public.gov_agency_stickiness(),
    public.gov_sticky_pairs(integer,integer),
    public.gov_tender_amount_buckets(),
    public.gov_tender_bid_dist(),
    public.gov_tender_unit_top(integer),
    public.gov_tender_year_stats(),
    public.gov_tender_yearly_amount(),
    public.gov_top_lawyers(integer,text),
    public.inhouse_recent_moves(integer,integer),
    public.inhouse_summary(),
    public.inhouse_top_employers(text,integer),
    public.jstat_overview_stats(),
    public.judge_case_kpis(),
    public.judge_cause_summary(text,text,integer),
    public.judge_copanel_circle(text,text,text,text),
    public.judge_court_statistics(),
    public.judge_days_by_year(),
    public.judge_pair_summary(text,text,integer),
    public.labor_comp_series_get(text),
    public.labor_seniority_dist(),
    public.lawyer_cohort_retention(),
    public.lawyer_firm_size_dist(),
    public.lawyer_growth(integer,integer,integer),
    public.lawyer_pair_summary(text,integer),
    public.lawyer_supply_stats(),
    public.lawyer_year_trend(text),
    public.lms_court_list(),
    public.lms_year_list(),
    public.market_line_stats(),
    public.market_year_trend(),
    public.moj_firm_statistics(),
    public.official_avg_cases(),
    public.prosecutor_active_by_office(),
    public.prosecutor_active_summary(),
    public.prosecutor_cases_by_year(),
    public.prosecutor_office_statistics(),
    public.region_active_by_region(integer,integer,text),
    public.region_active_counts(text,integer,text),
    public.region_distribution(),
    public.region_top_lawyers(text,integer,text,integer),
    public.subcat_cases_by_year(text),
    public.subcat_judge_stats_json(text),
    public.subcat_same_period_stats(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
    public.amount_rep_curve(text,text),
    public.cat_cases_by_year(text,text,integer),
    public.cat_judge_stats(text,text),
    public.cat_judge_stats_json(text,text),
    public.cat_same_period_stats(text,text),
    public.cause_court_list(text,text),
    public.cause_court_matrix(text,text,text),
    public.cause_group_list(),
    public.cause_group_yearly(text),
    public.cause_group_yearly_crim(),
    public.cause_lawyer_list(text,integer,text,integer,text),
    public.cause_raw_top(text,text,text,integer),
    public.cause_rep_yearly(text),
    public.cause_sub_group_list(),
    public.cause_supply_stats(text),
    public.cause_top_lawyers(text,integer,integer),
    public.cause_top_lawyers_cat(text,integer),
    public.cause_year_list(),
    public.change_regions(bigint[]),
    public.court_detail_stats(text),
    public.ex_judicial_overview_stats(),
    public.firm_cause_court_ranking(text,text,text,integer,integer),
    public.firm_cause_ranking(text,integer,integer),
    public.firm_cause_sub_ranking(text,text,integer,integer),
    public.firm_court_ranking(text,text,integer),
    public.firm_flow_lawyers(text,integer),
    public.firm_flow_overview(integer),
    public.firm_lawyer_year_stats(text[]),
    public.firm_turnover_stats(),
    public.gov_agency_stickiness(),
    public.gov_sticky_pairs(integer,integer),
    public.gov_tender_amount_buckets(),
    public.gov_tender_bid_dist(),
    public.gov_tender_unit_top(integer),
    public.gov_tender_year_stats(),
    public.gov_tender_yearly_amount(),
    public.gov_top_lawyers(integer,text),
    public.inhouse_recent_moves(integer,integer),
    public.inhouse_summary(),
    public.inhouse_top_employers(text,integer),
    public.jstat_overview_stats(),
    public.judge_case_kpis(),
    public.judge_cause_summary(text,text,integer),
    public.judge_copanel_circle(text,text,text,text),
    public.judge_court_statistics(),
    public.judge_days_by_year(),
    public.judge_pair_summary(text,text,integer),
    public.labor_comp_series_get(text),
    public.labor_seniority_dist(),
    public.lawyer_cohort_retention(),
    public.lawyer_firm_size_dist(),
    public.lawyer_growth(integer,integer,integer),
    public.lawyer_pair_summary(text,integer),
    public.lawyer_supply_stats(),
    public.lawyer_year_trend(text),
    public.lms_court_list(),
    public.lms_year_list(),
    public.market_line_stats(),
    public.market_year_trend(),
    public.moj_firm_statistics(),
    public.official_avg_cases(),
    public.prosecutor_active_by_office(),
    public.prosecutor_active_summary(),
    public.prosecutor_cases_by_year(),
    public.prosecutor_office_statistics(),
    public.region_active_by_region(integer,integer,text),
    public.region_active_counts(text,integer,text),
    public.region_distribution(),
    public.region_top_lawyers(text,integer,text,integer),
    public.subcat_cases_by_year(text),
    public.subcat_judge_stats_json(text),
    public.subcat_same_period_stats(text)
  TO authenticated, service_role;

-- (B) 其餘統計／查詢 RPC：目前 repo 與腳本都找不到匿名呼叫端（closed_case_* 等由 ETL 腳本以 service_role 呼叫）（18 支）---
REVOKE EXECUTE ON FUNCTION
    public.cause_court_top_lawyers(text,text,integer),
    public.cause_group_year_kpi(text,integer),
    public.closed_case_amount_months(),
    public.closed_case_cause_months(),
    public.closed_case_rep_months(text),
    public.expertise_top10(),
    public.family_cases_by_year(),
    public.family_judge_stats(),
    public.firm_open_close(),
    public.firm_statistics(),
    public.lawsnote_avg_cases(),
    public.moj_guild_statistics(),
    public.moj_region_distribution(),
    public.office_regions(text[]),
    public.recent_news_queries(integer),
    public.region_list(),
    public.search_paper_chunks(text,integer),
    public.subcat_judge_stats(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
    public.cause_court_top_lawyers(text,text,integer),
    public.cause_group_year_kpi(text,integer),
    public.closed_case_amount_months(),
    public.closed_case_cause_months(),
    public.closed_case_rep_months(text),
    public.expertise_top10(),
    public.family_cases_by_year(),
    public.family_judge_stats(),
    public.firm_open_close(),
    public.firm_statistics(),
    public.lawsnote_avg_cases(),
    public.moj_guild_statistics(),
    public.moj_region_distribution(),
    public.office_regions(text[]),
    public.recent_news_queries(integer),
    public.region_list(),
    public.search_paper_chunks(text,integer),
    public.subcat_judge_stats(text)
  TO authenticated, service_role;

-- (C) 後台／內部輔助函數：admin_reset_password 只有儀表板登入後的 admin 頁呼叫（函數內另驗 admin）；
--     assert_zhelu_user／get_my_lawyer_id 只被其他 SECURITY DEFINER 函數內部呼叫；
--     lawyer_profiles_log_revision 是 trigger 函數、rls_auto_enable 是 event trigger 函數（trigger 執行時不檢查 EXECUTE）（5 支）---
REVOKE EXECUTE ON FUNCTION
    public.admin_reset_password(uuid,text),
    public.assert_zhelu_user(),
    public.get_my_lawyer_id(),
    public.lawyer_profiles_log_revision(),
    public.rls_auto_enable()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
    public.admin_reset_password(uuid,text),
    public.assert_zhelu_user(),
    public.get_my_lawyer_id(),
    public.lawyer_profiles_log_revision(),
    public.rls_auto_enable()
  TO authenticated, service_role;

-- (D) 維護用函數：內部沒有任何身分檢查、會改資料（DELETE／UPDATE judge_month_stats 等），
--     只有 ETL 腳本以 service_role 呼叫（judgment_stats.py），前端與儀表板都沒有呼叫端。
--     連 authenticated 一起收，只留 service_role（兩站共用 auth 池，登入帳號不一定是喆律同仁）（2 支）---
REVOKE EXECUTE ON FUNCTION
    public.clean_judge_name_truncations(),
    public.merge_dirty_court_names(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
    public.clean_judge_name_truncations(),
    public.merge_dirty_court_names(text)
  TO service_role;

-- 自我檢查：收完之後 A～D 組 97 支 anon 必須失去 EXECUTE；A～C 組 authenticated／service_role 仍可執行；
--           保留匿名的 19 支 anon 仍可執行。任何一條不成立就整筆回滾。
DO $$
DECLARE
  revoked text[] := ARRAY[
    'amount_rep_curve',
    'cat_cases_by_year',
    'cat_judge_stats',
    'cat_judge_stats_json',
    'cat_same_period_stats',
    'cause_court_list',
    'cause_court_matrix',
    'cause_group_list',
    'cause_group_yearly',
    'cause_group_yearly_crim',
    'cause_lawyer_list',
    'cause_raw_top',
    'cause_rep_yearly',
    'cause_sub_group_list',
    'cause_supply_stats',
    'cause_top_lawyers',
    'cause_top_lawyers_cat',
    'cause_year_list',
    'change_regions',
    'court_detail_stats',
    'ex_judicial_overview_stats',
    'firm_cause_court_ranking',
    'firm_cause_ranking',
    'firm_cause_sub_ranking',
    'firm_court_ranking',
    'firm_flow_lawyers',
    'firm_flow_overview',
    'firm_lawyer_year_stats',
    'firm_turnover_stats',
    'gov_agency_stickiness',
    'gov_sticky_pairs',
    'gov_tender_amount_buckets',
    'gov_tender_bid_dist',
    'gov_tender_unit_top',
    'gov_tender_year_stats',
    'gov_tender_yearly_amount',
    'gov_top_lawyers',
    'inhouse_recent_moves',
    'inhouse_summary',
    'inhouse_top_employers',
    'jstat_overview_stats',
    'judge_case_kpis',
    'judge_cause_summary',
    'judge_copanel_circle',
    'judge_court_statistics',
    'judge_days_by_year',
    'judge_pair_summary',
    'labor_comp_series_get',
    'labor_seniority_dist',
    'lawyer_cohort_retention',
    'lawyer_firm_size_dist',
    'lawyer_growth',
    'lawyer_pair_summary',
    'lawyer_supply_stats',
    'lawyer_year_trend',
    'lms_court_list',
    'lms_year_list',
    'market_line_stats',
    'market_year_trend',
    'moj_firm_statistics',
    'official_avg_cases',
    'prosecutor_active_by_office',
    'prosecutor_active_summary',
    'prosecutor_cases_by_year',
    'prosecutor_office_statistics',
    'region_active_by_region',
    'region_active_counts',
    'region_distribution',
    'region_top_lawyers',
    'subcat_cases_by_year',
    'subcat_judge_stats_json',
    'subcat_same_period_stats',
    'cause_court_top_lawyers',
    'cause_group_year_kpi',
    'closed_case_amount_months',
    'closed_case_cause_months',
    'closed_case_rep_months',
    'expertise_top10',
    'family_cases_by_year',
    'family_judge_stats',
    'firm_open_close',
    'firm_statistics',
    'lawsnote_avg_cases',
    'moj_guild_statistics',
    'moj_region_distribution',
    'office_regions',
    'recent_news_queries',
    'region_list',
    'search_paper_chunks',
    'subcat_judge_stats',
    'admin_reset_password',
    'assert_zhelu_user',
    'get_my_lawyer_id',
    'lawyer_profiles_log_revision',
    'rls_auto_enable',
    'clean_judge_name_truncations',
    'merge_dirty_court_names'
  ];
  kept text[] := ARRAY[
    'moj_harvest_submit',
    'speaking_calendar_ingest',
    'speaking_calendar_sync',
    'can_view_all',
    'can_view_all_revenue',
    'can_view_mgmt',
    'get_my_department_ids',
    'get_my_role',
    'has_law010_access',
    'has_salary_access',
    'hr_hides_shareholders',
    'hr_name_visible',
    'is_admin',
    'is_bullying_admin',
    'is_intel_admin',
    'is_profile_owner',
    'is_zhelu_user',
    'mkt_has_access',
    'seminar_has_access'
  ];
  bad text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = ANY(revoked) AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'mig 271：仍有 anon 可執行的函數：%', bad; END IF;

  SELECT string_agg(p.proname, ', ') INTO bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = ANY(revoked) AND p.proname <> ALL(ARRAY['clean_judge_name_truncations','merge_dirty_court_names'])
    AND NOT (has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE'));
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'mig 271：authenticated／service_role 失去 EXECUTE：%', bad; END IF;

  SELECT string_agg(p.proname, ', ') INTO bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = ANY(kept) AND NOT has_function_privilege('anon', p.oid, 'EXECUTE');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'mig 271：應保留匿名的函數被收掉了：%', bad; END IF;
END $$;

COMMIT;

-- 保留匿名的 19 支（供日後查閱；若之後把 RLS policy 的 roles 從 public 改成 authenticated，16 支權限判斷函數也可再收）：
--   moj_harvest_submit, speaking_calendar_ingest, speaking_calendar_sync,
--   can_view_all, can_view_all_revenue, can_view_mgmt, get_my_department_ids, get_my_role, has_law010_access, has_salary_access, hr_hides_shareholders, hr_name_visible, is_admin, is_bullying_admin, is_intel_admin, is_profile_owner, is_zhelu_user, mkt_has_access, seminar_has_access
--
-- 慣例：postgres 擁有者在 public 建的新函數，預設仍會對 PUBLIC／anon 開放 EXECUTE。之後新增 SECURITY DEFINER RPC 時，
--   同一份 migration 補 REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION ... TO authenticated, service_role;
