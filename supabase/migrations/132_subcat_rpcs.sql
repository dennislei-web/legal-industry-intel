-- Phase 2 細分專庭 RPC × 3（字別模式；讀 jcase_category_map，mig 131）
-- 口徑：
--   名單/佔比＝judge_month_jcase 法官人次 ÷ judge_month_stats 總人次（單位一致）
--   年度量/法院榜＝court_month_jcase 案件數（每案一次，含未抽到法官者；分母=全部有字別文件）
--   結案天數＝該月該類佔比 >= 0.8 的法官月估算（同 mig 126 手法），回樣本數供前端做門檻

CREATE OR REPLACE FUNCTION subcat_judge_stats(p_category text)
RETURNS TABLE (name text, court_name text, total_cases bigint, cat_cases bigint,
               cat_share numeric, avg_days numeric, first_ym text, last_ym text) AS $$
  WITH mp AS (SELECT prefix, exclude FROM jcase_category_map WHERE category = p_category),
  c AS (
    SELECT j.name, j.court_name, sum(j.n) AS cc, min(j.yyyymm) AS fym, max(j.yyyymm) AS lym
    FROM judge_month_jcase j
    WHERE EXISTS (SELECT 1 FROM mp WHERE NOT exclude AND j.jcase LIKE prefix || '%')
      AND NOT EXISTS (SELECT 1 FROM mp WHERE exclude AND j.jcase LIKE prefix || '%')
      AND j.court_name <> '未知法院' AND char_length(j.name) >= 2 AND j.name NOT LIKE '%法官%'
    GROUP BY 1, 2
    HAVING sum(j.n) >= 3
  ),
  t AS (
    SELECT s.name, s.court_name, sum(s.case_count) AS tot,
           round(sum(s.sum_days)::numeric / nullif(sum(s.n_days), 0), 0) AS days
    FROM judge_month_stats s
    WHERE s.yyyymm >= '202001'
    GROUP BY 1, 2
  )
  SELECT c.name, c.court_name, coalesce(t.tot, c.cc)::bigint, c.cc::bigint,
         round(c.cc::numeric / nullif(t.tot, 0), 3), t.days, c.fym, c.lym
  FROM c LEFT JOIN t USING (name, court_name)
  ORDER BY c.cc DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION subcat_judge_stats(text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION subcat_judge_stats(text) TO anon, authenticated;

-- 年度序列（案件數口徑；days_n=結案天數估算的樣本案量，前端 < 門檻顯示「樣本不足」）
CREATE OR REPLACE FUNCTION subcat_cases_by_year(p_category text)
RETURNS TABLE (year text, cat_cases bigint, total_cases bigint,
               months int, ok_months int, cat_avg_days numeric, days_n bigint) AS $$
  WITH mp AS (SELECT prefix, exclude FROM jcase_category_map WHERE category = p_category),
  cm AS (
    SELECT yyyymm,
           sum(n) FILTER (WHERE EXISTS (SELECT 1 FROM mp WHERE NOT exclude AND jcase LIKE prefix || '%')
                          AND NOT EXISTS (SELECT 1 FROM mp WHERE exclude AND jcase LIKE prefix || '%')) AS cc,
           sum(n) AS tot
    FROM court_month_jcase
    GROUP BY yyyymm
  ),
  jm AS (  -- 法官月：該類人次
    SELECT j.name, j.court_name, j.yyyymm, sum(j.n) AS cc
    FROM judge_month_jcase j
    WHERE EXISTS (SELECT 1 FROM mp WHERE NOT exclude AND j.jcase LIKE prefix || '%')
      AND NOT EXISTS (SELECT 1 FROM mp WHERE exclude AND j.jcase LIKE prefix || '%')
    GROUP BY 1, 2, 3
  ),
  d AS (  -- 專責法官月（該類佔比 >= 0.8）的結案天數樣本
    SELECT s.yyyymm, sum(s.sum_days) AS sd, sum(s.n_days) AS nd
    FROM judge_month_stats s JOIN jm
      ON s.name = jm.name AND s.court_name = jm.court_name AND s.yyyymm = jm.yyyymm
    WHERE jm.cc::numeric / nullif(s.case_count, 0) >= 0.8
    GROUP BY 1
  )
  SELECT left(cm.yyyymm, 4),
         coalesce(sum(cm.cc), 0)::bigint,
         sum(cm.tot)::bigint,
         count(*)::int,
         count(*)::int,
         round(sum(d.sd)::numeric / nullif(sum(d.nd), 0), 0),
         coalesce(sum(d.nd), 0)::bigint
  FROM cm LEFT JOIN d USING (yyyymm)
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION subcat_cases_by_year(text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION subcat_cases_by_year(text) TO anon, authenticated;

-- 未滿年同期比（同 mig 128 手法，案件數口徑）
CREATE OR REPLACE FUNCTION subcat_same_period_stats(p_category text)
RETURNS TABLE (year text, upto_month int, cat_cases bigint, cat_avg_days numeric) AS $$
  WITH mp AS (SELECT prefix, exclude FROM jcase_category_map WHERE category = p_category),
  mx AS (SELECT right(max(yyyymm), 2) AS mm FROM court_month_jcase),
  cm AS (
    SELECT yyyymm,
           sum(n) FILTER (WHERE EXISTS (SELECT 1 FROM mp WHERE NOT exclude AND jcase LIKE prefix || '%')
                          AND NOT EXISTS (SELECT 1 FROM mp WHERE exclude AND jcase LIKE prefix || '%')) AS cc
    FROM court_month_jcase
    WHERE right(yyyymm, 2) <= (SELECT mm FROM mx)
    GROUP BY yyyymm
  ),
  jm AS (
    SELECT j.name, j.court_name, j.yyyymm, sum(j.n) AS cc
    FROM judge_month_jcase j
    WHERE right(j.yyyymm, 2) <= (SELECT mm FROM mx)
      AND EXISTS (SELECT 1 FROM mp WHERE NOT exclude AND j.jcase LIKE prefix || '%')
      AND NOT EXISTS (SELECT 1 FROM mp WHERE exclude AND j.jcase LIKE prefix || '%')
    GROUP BY 1, 2, 3
  ),
  d AS (
    SELECT s.yyyymm, sum(s.sum_days) AS sd, sum(s.n_days) AS nd
    FROM judge_month_stats s JOIN jm
      ON s.name = jm.name AND s.court_name = jm.court_name AND s.yyyymm = jm.yyyymm
    WHERE jm.cc::numeric / nullif(s.case_count, 0) >= 0.8
    GROUP BY 1
  )
  SELECT left(cm.yyyymm, 4),
         max(right(cm.yyyymm, 2))::int,
         coalesce(sum(cm.cc), 0)::bigint,
         round(sum(d.sd)::numeric / nullif(sum(d.nd), 0), 0)
  FROM cm LEFT JOIN d USING (yyyymm)
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION subcat_same_period_stats(text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION subcat_same_period_stats(text) TO anon, authenticated;
