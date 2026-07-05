-- 法院詳情整合聚合 RPC（前端法院 modal 用，一次回傳三組年度序列）
-- official_yearly：官方各案類年度新收/終結（court_case_stats）
-- official_lit_closed_yearly：官方「訴訟程序」年度終結（proc_l1 訴訟/刑事案件，供對照裁判書公開量）
-- judgment_yearly：裁判書抽出的年度件數（judge_month_stats）

CREATE OR REPLACE FUNCTION court_detail_stats(p_court text)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
SELECT json_build_object(
  'official_yearly', (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.year_tw), '[]'::json) FROM (
      SELECT year_tw, case_category,
             sum(new_cases)::int AS new_cases, sum(closed_cases)::int AS closed_cases
      FROM court_case_stats WHERE court_name = p_court
      GROUP BY year_tw, case_category) t),
  'official_lit_closed_yearly', (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.year_tw), '[]'::json) FROM (
      SELECT year_tw, sum(closed_cases)::int AS closed_cases
      FROM court_case_stats
      WHERE court_name = p_court AND proc_l1 IN ('訴訟', '刑事案件')
      GROUP BY year_tw) t),
  'judgment_yearly', (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.y), '[]'::json) FROM (
      SELECT left(yyyymm, 4) AS y, sum(case_count)::int AS judgments
      FROM judge_month_stats WHERE court_name = p_court
      GROUP BY 1) t)
);
$$;

GRANT EXECUTE ON FUNCTION court_detail_stats(text) TO anon, authenticated;
