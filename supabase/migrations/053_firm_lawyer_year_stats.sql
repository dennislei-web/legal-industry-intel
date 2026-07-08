-- 事務所 modal「官方訴訟戰力」年份切換用：
--   firm_lawyer_year_stats(p_names) → 每年一列（合計出庭 / 有出庭律師數 / 案類 / 法院版圖 / 各律師出庭數），
--   前端拿到後直接渲染，Top1/Top3 依賴度由 lawyers jsonb client-side 排序取得。
-- 口徑：僅公開裁判書下限估計；呼叫端只傳「名冊唯一同名」律師名（與 5 年版一致，同名不計入）；
--       法院版圖＝按「律師該年主場法院」加權彙總（同 5 年版 top_court 口徑）。
-- 形狀：每年一列（≤30 列）而非 律師×年，避免 PostgREST max-rows=1000 截斷與 RPC .range() 每頁重跑。
-- 效能：走 idx_lms_name（031），一家所通常 <300 名。

DROP FUNCTION IF EXISTS firm_lawyer_year_stats(text[]);
CREATE FUNCTION firm_lawyer_year_stats(p_names text[])
RETURNS TABLE (yr text, total int, n_lawyers int, cats jsonb, courts jsonb, lawyers jsonb) AS $$
  WITH base AS (
    SELECT m.name, left(m.yyyymm, 4) AS y, m.court_name, m.case_count, m.cats
    FROM lawyer_month_stats m
    WHERE m.name = ANY(p_names)
  ), per AS (      -- 律師 × 年
    SELECT b.name, b.y, sum(b.case_count)::int AS c
    FROM base b GROUP BY 1, 2
  ), tc AS (       -- 律師 × 年 主場法院
    SELECT DISTINCT ON (s.name, s.y) s.name, s.y, s.court_name
    FROM (SELECT b.name, b.y, b.court_name, sum(b.case_count) AS c
          FROM base b GROUP BY 1, 2, 3) s
    ORDER BY s.name, s.y, s.c DESC
  ), catyr AS (    -- 年 × 案類
    SELECT s.y, jsonb_object_agg(s.k, s.v) AS cats FROM (
      SELECT b.y, e.key AS k, sum((e.value)::int) AS v
      FROM base b, jsonb_each_text(b.cats) e GROUP BY 1, 2
    ) s GROUP BY s.y
  ), courtyr AS (  -- 年 × 法院（按律師主場法院加權）
    SELECT s.y, jsonb_object_agg(s.court_name, s.c) AS courts FROM (
      SELECT p.y, t.court_name, sum(p.c) AS c
      FROM per p JOIN tc t ON t.name = p.name AND t.y = p.y
      GROUP BY 1, 2
    ) s GROUP BY s.y
  ), lawyr AS (    -- 年 × 律師出庭數
    SELECT p.y, jsonb_object_agg(p.name, p.c) AS lawyers,
           sum(p.c)::int AS total, count(*)::int AS n
    FROM per p GROUP BY p.y
  )
  SELECT l.y, l.total, l.n, catyr.cats, courtyr.courts, l.lawyers
  FROM lawyr l
  LEFT JOIN catyr   ON catyr.y = l.y
  LEFT JOIN courtyr ON courtyr.y = l.y
  ORDER BY l.y DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION firm_lawyer_year_stats(text[]) SET statement_timeout = '60s';
