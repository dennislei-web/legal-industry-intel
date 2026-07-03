-- 裁判書開放資料 → 法官統計
-- judge_month_stats：judgment_stats.py 每月上傳的 (法官×法院×月) 聚合
-- judge_judgment_stats：RPC 彙總後供前端讀取（案件數/案類分布/審理天數估算/首判月）

CREATE TABLE IF NOT EXISTS judge_month_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  court_name text NOT NULL,
  yyyymm text NOT NULL,
  case_count int NOT NULL,
  sum_days bigint NOT NULL DEFAULT 0,
  n_days int NOT NULL DEFAULT 0,
  cats jsonb,
  UNIQUE (name, court_name, yyyymm)
);
CREATE INDEX IF NOT EXISTS idx_jms_name_court ON judge_month_stats (name, court_name);
CREATE INDEX IF NOT EXISTS idx_jms_yyyymm ON judge_month_stats (yyyymm);

CREATE TABLE IF NOT EXISTS judge_judgment_stats (
  name text NOT NULL,
  court_name text NOT NULL,
  case_count_total int,
  case_count_by_year jsonb,
  case_type_distribution jsonb,
  avg_processing_days numeric,
  first_yyyymm text,
  refreshed_at timestamptz DEFAULT now(),
  PRIMARY KEY (name, court_name)
);

ALTER TABLE judge_month_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE judge_judgment_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_jms" ON judge_month_stats;
CREATE POLICY "auth_read_jms" ON judge_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "auth_read_jjs" ON judge_judgment_stats;
CREATE POLICY "auth_read_jjs" ON judge_judgment_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_judge_judgment_stats() RETURNS void AS $$
BEGIN
  TRUNCATE judge_judgment_stats;
  INSERT INTO judge_judgment_stats
    (name, court_name, case_count_total, case_count_by_year,
     case_type_distribution, avg_processing_days, first_yyyymm, refreshed_at)
  SELECT g.name, g.court_name, g.total,
    (SELECT jsonb_object_agg(t.y, t.c) FROM (
       SELECT left(m2.yyyymm, 4) AS y, sum(m2.case_count) AS c
       FROM judge_month_stats m2
       WHERE m2.name = g.name AND m2.court_name = g.court_name
       GROUP BY 1) t),
    (SELECT jsonb_object_agg(t2.k, t2.v) FROM (
       SELECT e.key AS k, sum((e.value)::text::int) AS v
       FROM judge_month_stats m3, jsonb_each(m3.cats) e
       WHERE m3.name = g.name AND m3.court_name = g.court_name
       GROUP BY e.key) t2),
    CASE WHEN g.nd > 0 THEN round(g.sd::numeric / g.nd, 0) END,
    g.first_ym, now()
  FROM (
    SELECT name, court_name, sum(case_count)::int AS total,
           sum(sum_days) AS sd, sum(n_days) AS nd, min(yyyymm) AS first_ym
    FROM judge_month_stats GROUP BY name, court_name
  ) g;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
