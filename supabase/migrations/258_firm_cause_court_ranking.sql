-- ============================================================
-- 258: 事務所版圖——選了案由種類／子類也能篩法院（firm_cause_court_ranking）
-- ============================================================
-- 需求（雷 2026-11-03，截圖「民事／損害賠償／全部子類」時法院下拉變灰）：
--   選了案由種類後法院不能選。
-- 起因：2026-07 的案由種類排名（firm_cause_ranking，Phase B）讀 lawyer_cause_stats，只有全國口徑，
--   前端選了種類就鎖住法院下拉；mig 255／257 的子類沿用同一路徑，也跟著鎖。
--   mig 182（2026-09）已建 lawyer_cause_court_stats（律師×法院×種類，近 5 年），但事務所版圖一直沒接上。
--
-- 做法（不建新物化表）：
--   近 5 年×種類×法院 → 讀 lawyer_cause_court_stats（現成）。
--   選了單一年度或子類 → 先用法院縮小範圍，再從 lawyer_month_stats 即時展開 causes 計算。
--     實測最壞情況（臺北地院，近 5 年 10.9 萬列，含 Management API 往返）：
--     其他民法×2025 4.8 秒（冷快取）、損害賠償／交通事故×近 5 年 2.9 秒、其他民法×近 5 年 1.6 秒。
--   不建表的理由：年度×法院約 85 萬列、子類×法院約 85 萬列，合計約 200 MB，DB 已 6.5 GB。
--     即時算也讓子類規則（cause_group_map.sub_group generated column）一改就生效，不必等月更重建。
--   兩個來源用同一個查詢的 UNION ALL，各自以 use_pre 擋住；plpgsql 第一次執行用 custom plan，
--   不走的那支會變成 One-Time Filter: false，不會去掃。
--
-- 口徑：與 firm_cause_ranking／firm_cause_sub_ranking 相同——名目（律師人次）、事務所歸戶同一個 firm CTE、
--   年度＝整個西元年（與 firm_court_ranking、lawyer_cause_year_stats 同）、近 5 年＝max(yyyymm) 往回 59 個月。
--   法院只有 38 個機關層級，簡易庭的案件併在所屬地方法院，不能單選簡易庭。
-- 效能地雷：JOIN cause_group_map 要維持 hash join；別改成 k.key = ANY(陣列) 或 ?|（mig 255 實測超過 120 秒）。
--
-- 驗證（套用後）：
--   select * from firm_cause_court_ranking('損害賠償', '臺灣臺中地方法院') limit 3;  -- 莊子賢 477、嵩宬 182、真亮 179
--   各法院加總＝全國：sum over lms_court_list() 的喆律件數＝firm_cause_ranking／firm_cause_sub_ranking 的喆律件數

CREATE OR REPLACE FUNCTION firm_cause_court_ranking(
  p_group text, p_court text, p_sub text DEFAULT NULL, p_year int DEFAULT NULL, p_limit int DEFAULT 1000)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $$
#variable_conflict use_column
DECLARE
  use_pre boolean := (p_sub IS NULL AND p_year IS NULL);
  lo text;
  hi text;
BEGIN
  IF p_group IS NULL OR p_court IS NULL THEN RETURN; END IF;

  IF p_year IS NOT NULL THEN
    lo := p_year::text || '01';
    hi := p_year::text || '12';
  ELSIF NOT use_pre THEN
    SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM'), max(yyyymm)
      INTO lo, hi FROM lawyer_month_stats WHERE causes IS NOT NULL;
  END IF;

  RETURN QUERY
  WITH per AS (
    SELECT s.name, s.case_count::bigint AS c
    FROM lawyer_cause_court_stats s
    WHERE use_pre AND s.cause_group = p_group AND s.court_name = p_court
    UNION ALL
    SELECT l.name, sum((k.value)::int)::bigint AS c
    FROM lawyer_month_stats l
    CROSS JOIN LATERAL jsonb_each_text(l.causes) k
    JOIN cause_group_map m ON m.ck = k.key AND m.cause_group = p_group
    WHERE NOT use_pre
      AND l.court_name = p_court AND l.causes IS NOT NULL AND l.yyyymm BETWEEN lo AND hi
      AND (p_sub IS NULL OR m.sub_group = p_sub)
    GROUP BY l.name
  ), firm AS (  -- 歸戶口徑＝firm_cause_ranking／firm_court_ranking 的 firm CTE
    SELECT lc.name, min(coalesce(substring(lc.firm_name from '^(.*?事務所)'), lc.firm_name)) AS fname,
           count(*) AS n
    FROM lawyers_combined lc
    WHERE lc.firm_name IS NOT NULL AND lc.firm_name NOT LIKE '%未提供%'
    GROUP BY lc.name
  ), agg AS (
    SELECT f.fname, sum(p.c)::bigint AS cs, count(*)::int AS lcnt
    FROM per p JOIN firm f ON f.name = p.name
    WHERE f.n = 1
    GROUP BY f.fname
  )
  SELECT (row_number() OVER (ORDER BY a.cs DESC, a.fname))::int, a.fname, a.cs, a.lcnt
  FROM agg a
  ORDER BY a.cs DESC, a.fname
  LIMIT p_limit;
END $$;

REVOKE EXECUTE ON FUNCTION firm_cause_court_ranking(text, text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION firm_cause_court_ranking(text, text, text, int, int) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
