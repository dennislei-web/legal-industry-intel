-- 官方裁判書律師彙總表：取代 Lawsnote case_count_5yr
-- lawyer_judgment_stats：refresh_lawyer_judgment_stats() 從 lawyer_month_stats（265 萬列）
--   按律師名彙總：近 5 年（滾動 60 個月，錨定資料最新月）案件數/案類/法院、全期總量/逐年趨勢
-- lawyers_with_stats：lawyers_combined 不動，包一層 LEFT JOIN 供律師列表換資料源
--   （保住 PostgREST 伺服器端排序/分頁；同名多筆時彙總值會重複掛在每一筆，屬已知口徑限制）
-- 口徑：僅公開裁判書，案件量為下限估計，適合相對比較

CREATE TABLE IF NOT EXISTS lawyer_judgment_stats (
  name text PRIMARY KEY,
  cases_5yr int NOT NULL DEFAULT 0,
  cases_total int NOT NULL,
  cats_5yr jsonb,
  cats_all jsonb,
  by_year jsonb,
  top_court_5yr text,
  n_courts_5yr int NOT NULL DEFAULT 0,
  first_yyyymm text,
  last_yyyymm text,
  refreshed_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ljs_cases5 ON lawyer_judgment_stats (cases_5yr DESC);

ALTER TABLE lawyer_judgment_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ljs" ON lawyer_judgment_stats;
CREATE POLICY "auth_read_ljs" ON lawyer_judgment_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_lawyer_judgment_stats() RETURNS void AS $$
DECLARE cutoff text;
BEGIN
  -- 近 5 年 = 資料最新月往前推 59 個月（含當月共 60 個月）
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM')
    INTO cutoff FROM lawyer_month_stats;

  TRUNCATE lawyer_judgment_stats;

  WITH tot AS (
    SELECT name, sum(case_count)::int AS cases_total,
           min(yyyymm) AS first_ym, max(yyyymm) AS last_ym
    FROM lawyer_month_stats GROUP BY name
  ), r5 AS (
    SELECT name, sum(case_count)::int AS c, count(DISTINCT court_name)::int AS nc
    FROM lawyer_month_stats WHERE yyyymm >= cutoff GROUP BY name
  ), cat5 AS (
    SELECT name, jsonb_object_agg(k, v) AS cats FROM (
      SELECT m.name, e.key AS k, sum((e.value)::int) AS v
      FROM lawyer_month_stats m, jsonb_each_text(m.cats) e
      WHERE m.yyyymm >= cutoff GROUP BY 1, 2
    ) s GROUP BY name
  ), cata AS (
    SELECT name, jsonb_object_agg(k, v) AS cats FROM (
      SELECT m.name, e.key AS k, sum((e.value)::int) AS v
      FROM lawyer_month_stats m, jsonb_each_text(m.cats) e
      GROUP BY 1, 2
    ) s GROUP BY name
  ), yr AS (
    SELECT name, jsonb_object_agg(y, c) AS by_year FROM (
      SELECT name, left(yyyymm, 4) AS y, sum(case_count) AS c
      FROM lawyer_month_stats GROUP BY 1, 2
    ) s GROUP BY name
  ), tc AS (
    SELECT DISTINCT ON (name) name, court_name FROM (
      SELECT name, court_name, sum(case_count) AS c
      FROM lawyer_month_stats WHERE yyyymm >= cutoff GROUP BY 1, 2
    ) s ORDER BY name, c DESC
  )
  INSERT INTO lawyer_judgment_stats
    (name, cases_5yr, cases_total, cats_5yr, cats_all, by_year,
     top_court_5yr, n_courts_5yr, first_yyyymm, last_yyyymm, refreshed_at)
  SELECT t.name, coalesce(r5.c, 0), t.cases_total,
         cat5.cats, cata.cats, yr.by_year,
         tc.court_name, coalesce(r5.nc, 0), t.first_ym, t.last_ym, now()
  FROM tot t
  LEFT JOIN r5   USING (name)
  LEFT JOIN cat5 USING (name)
  LEFT JOIN cata USING (name)
  LEFT JOIN yr   USING (name)
  LEFT JOIN tc   USING (name);
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_lawyer_judgment_stats() SET statement_timeout = '600s';

-- 律師列表用：lawyers_combined + 官方統計（Lawsnote case_count_5yr 由 official_cases_5yr 取代）
CREATE OR REPLACE VIEW lawyers_with_stats AS
SELECT c.*,
       s.cases_5yr    AS official_cases_5yr,
       s.cases_total  AS official_cases_total,
       s.cats_5yr     AS official_cats_5yr,
       s.top_court_5yr AS official_top_court,
       s.n_courts_5yr AS official_n_courts,
       s.last_yyyymm  AS official_last_ym,
       -- 名冊同名多筆時，官方統計（按姓名彙總）是多人合併值，前端須標註
       count(*) OVER (PARTITION BY c.name) > 1 AS name_ambiguous
FROM lawyers_combined c
LEFT JOIN lawyer_judgment_stats s USING (name);

-- 總覽 KPI：官方口徑的每律師近 5 年平均案件數（僅計有出庭紀錄者，對齊 lawsnote_avg_cases 口徑）
CREATE OR REPLACE FUNCTION official_avg_cases() RETURNS numeric AS $$
  SELECT round(avg(cases_5yr), 1) FROM lawyer_judgment_stats WHERE cases_5yr > 0;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
