-- court_case_stats 加入訴訟程序別第 2 層（proc_l2）
-- 原因：地院「民事」的 l1 只分 民事/民執，真正的「民事訴訟」在 l2
--（114 年地院：民事訴訟 18.9 萬 vs 民事非訟 83.7 萬 vs 民執執行 204.6 萬）
-- 表全量重灌（judicial_official_stats.py 重跑 parse+upload），約 40 萬列

TRUNCATE court_case_stats;
ALTER TABLE court_case_stats ADD COLUMN IF NOT EXISTS proc_l2 text NOT NULL DEFAULT '';
ALTER TABLE court_case_stats DROP CONSTRAINT IF EXISTS court_case_stats_year_tw_month_court_name_case_category_pro_key;
ALTER TABLE court_case_stats ADD CONSTRAINT ccs_unique_key
  UNIQUE (year_tw, month, court_name, case_category, proc_l1, proc_l2);

-- 更新法院詳情 RPC：訴訟終結口徑改用 l2
-- 訴訟 = 民事(l2=民事訴訟) + 刑事(l1=訴訟，含附民/上訴) + 家事(l1=訴訟)
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
      WHERE court_name = p_court
        AND ((case_category = '民事' AND proc_l2 = '民事訴訟')
          OR (case_category IN ('刑事', '家事') AND proc_l1 = '訴訟'))
      GROUP BY year_tw) t),
  'judgment_yearly', (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.y), '[]'::json) FROM (
      SELECT left(yyyymm, 4) AS y, sum(case_count)::int AS judgments
      FROM judge_month_stats WHERE court_name = p_court
      GROUP BY 1) t)
);
$$;

GRANT EXECUTE ON FUNCTION court_detail_stats(text) TO anon, authenticated;
