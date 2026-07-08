-- 市場趨勢 + 律師年度案型（Phase A + B；零回填，全部彙總現成資料）
-- A. market_year_trend()：官方 court_case_stats → 各案類逐年「一審新收」市場總量
--    口徑（已對 114 基準：民訴188,772 / 刑訴260,236 / 家事183,028 / 行政14,782）：
--      民事訴訟 = 地院·民事·民事訴訟(proc_l2)      民事非訟/民事執行另列（脈絡，非訴訟）
--      刑事訴訟 = 地院·刑事·訴訟·第一審            家事 = 地院·家事(全部,以非訟為主)
--      行政訴訟 = 高等行政法院·訴訟(地方+高等庭一審)  少年 = 地院·少年
--    注意：legacy 併類「民事(100年以前含家事)/刑事(102年以前含少年)」在 DB 為 0 列，資料已正規化到乾淨案類
-- B. lawyer_year_trend(name)：該律師逐年×案型（判決書口徑=下限、非唯一案件數、同名合併）
--    lawyer_growth()：近3年 vs 前3年案量變化排行（by_year，市場結構訊號）

CREATE OR REPLACE FUNCTION market_year_trend()
RETURNS TABLE(year_ad int, segment text, new_cases bigint) AS $$
  SELECT (year_tw + 1911) AS year_ad, seg, sum(nc)::bigint
  FROM (
    SELECT year_tw, new_cases AS nc,
      CASE
        WHEN case_category='民事' AND court_level='地方法院' AND proc_l1='民事' AND proc_l2='民事訴訟' THEN '民事訴訟'
        WHEN case_category='民事' AND court_level='地方法院' AND proc_l1='民事' AND proc_l2='民事非訟' THEN '民事非訟'
        WHEN case_category='民事' AND court_level='地方法院' AND proc_l1='民執' AND proc_l2='執行'   THEN '民事執行'
        WHEN case_category='刑事' AND court_level='地方法院' AND proc_l1='訴訟' AND proc_l2='第一審' THEN '刑事訴訟'
        WHEN case_category='家事' AND court_level='地方法院'                                        THEN '家事'
        WHEN case_category='少年' AND court_level='地方法院'                                        THEN '少年'
        WHEN case_category='行政訴訟' AND court_level='高等行政法院' AND proc_l1='訴訟'             THEN '行政訴訟'
        ELSE NULL END AS seg
    FROM court_case_stats
  ) x
  WHERE seg IS NOT NULL AND nc > 0
  GROUP BY 1, 2
  ORDER BY 1, 2;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION market_year_trend() SET statement_timeout = '30s';

-- 該律師逐年×案型：{ "2020": {"民事":30,"刑事":10}, ... }（走 idx_lms_name，per-lawyer 安全）
CREATE OR REPLACE FUNCTION lawyer_year_trend(p_name text)
RETURNS jsonb AS $$
  SELECT COALESCE(jsonb_object_agg(yr, cats), '{}'::jsonb)
  FROM (
    SELECT yr, jsonb_object_agg(k, v) AS cats
    FROM (
      SELECT left(m.yyyymm, 4) AS yr, e.key AS k, sum(e.value::int) AS v
      FROM lawyer_month_stats m, jsonb_each_text(m.cats) e
      WHERE m.name = p_name
      GROUP BY 1, 2
    ) s GROUP BY yr
  ) t;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lawyer_year_trend(text) SET statement_timeout = '30s';

-- 律師案量變化排行：近3年(anchor 起往前3年) vs 前3年；回最大變動者（升/降都收）
CREATE OR REPLACE FUNCTION lawyer_growth(p_anchor int DEFAULT 2024, p_min int DEFAULT 15, p_limit int DEFAULT 40)
RETURNS TABLE(name text, recent int, prior int, delta int, growth_pct numeric, top_cat text) AS $$
  WITH b AS (
    SELECT s.name, s.cats_all,
      ( COALESCE((s.by_year->>(p_anchor)::text)::int, 0)
      + COALESCE((s.by_year->>((p_anchor-1))::text)::int, 0)
      + COALESCE((s.by_year->>((p_anchor-2))::text)::int, 0)) AS recent,
      ( COALESCE((s.by_year->>((p_anchor-3))::text)::int, 0)
      + COALESCE((s.by_year->>((p_anchor-4))::text)::int, 0)
      + COALESCE((s.by_year->>((p_anchor-5))::text)::int, 0)) AS prior
    FROM lawyer_judgment_stats s
    WHERE s.by_year IS NOT NULL
      AND COALESCE((s.by_year->>(p_anchor)::text)::int,0)
        + COALESCE((s.by_year->>((p_anchor-1))::text)::int,0)
        + COALESCE((s.by_year->>((p_anchor-2))::text)::int,0) >= p_min
  )
  SELECT b.name, b.recent, b.prior, (b.recent - b.prior) AS delta,
    CASE WHEN b.prior > 0 THEN round((b.recent - b.prior) * 100.0 / b.prior, 0) ELSE NULL END,
    (SELECT e.key FROM jsonb_each_text(b.cats_all) e ORDER BY e.value::int DESC LIMIT 1)
  FROM b
  ORDER BY abs(b.recent - b.prior) DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lawyer_growth(int, int, int) SET statement_timeout = '30s';
