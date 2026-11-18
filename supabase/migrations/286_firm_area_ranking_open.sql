-- ============================================================
-- 286: 事務所版圖「依業務領域」開放給一般登入帳號（官網主打欄仍只給管理員）
-- ============================================================
-- 需求（雷 2026-11-18）：mig 285 的領域切法原本整支只給管理員。件數與佔比來自公開裁判書，
--   和「依法院案由」的排名（firm_cause_ranking 等，登入即可看）是同一份素材，開放給一般帳號；
--   官網主打欄來自 firm_site_facts（競爭情報，admin-only），維持只給管理員。
--
-- 做法：firm_area_ranking 簽名、回傳欄不變（CREATE OR REPLACE，不必 DROP）。
--   · 不再整支擋非管理員；仍只 GRANT authenticated（匿名打不到，同 mig 271 的原則）。
--   · 非管理員的 has_site／is_focus 一律回 NULL（不是 false——false 會被讀成「沒主打」）。
--   其餘不動：底層兩張表沒有 policy、firm_area_rank_core 不對外、firm_area_cases（事務所詳情
--   「官網對照」分頁）仍是 admin-only。
-- ============================================================

CREATE OR REPLACE FUNCTION firm_area_ranking(
  p_area      text,
  p_court     text DEFAULT NULL,
  p_year      int  DEFAULT NULL,
  p_sort      text DEFAULT 'cases',   -- cases＝依件數、share＝依佔比
  p_min_cases int  DEFAULT 30,        -- 只在依佔比時生效
  p_limit     int  DEFAULT 100,
  p_pin       text DEFAULT NULL)
RETURNS TABLE (
  rank int, ord int, firm_name text, cases bigint, total_cases bigint, share numeric,
  lawyer_count int, has_site boolean, is_focus boolean, n_firms int, in_list boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin boolean := public.is_intel_admin();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.rank, c.ord, c.firm_name, c.cases, c.total_cases, c.share, c.lawyer_count,
         CASE WHEN v_admin THEN c.has_site END,
         CASE WHEN v_admin THEN c.is_focus END,
         c.n_firms, c.in_list
  FROM firm_area_rank_core(
    p_area, p_court, p_year, COALESCE(p_sort, 'cases'), COALESCE(p_min_cases, 30),
    LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000), p_pin) c;
END $$;
REVOKE EXECUTE ON FUNCTION firm_area_ranking(text, text, int, text, int, int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION firm_area_ranking(text, text, int, text, int, int, text) TO authenticated;
