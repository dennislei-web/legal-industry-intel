-- 裁判書開放資料 → 檢察官統計（架構比照 025 法官統計）
-- prosecutor_month_stats：judgment_stats.py 每月上傳的 (檢察官×地檢署×月) 聚合
--（檢察官姓名/所屬檢察署從刑事裁判書「公訴人…檢察署檢察官」「本案經檢察官○○○提起公訴」等段落萃取）
-- prosecutor_stats：RPC 彙總後供前端讀取（案件數/案類分布/起始月）

CREATE TABLE IF NOT EXISTS prosecutor_month_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  office_name text NOT NULL,
  yyyymm text NOT NULL,
  case_count int NOT NULL,
  cats jsonb,
  UNIQUE (name, office_name, yyyymm)
);
CREATE INDEX IF NOT EXISTS idx_pms_name_office ON prosecutor_month_stats (name, office_name);
CREATE INDEX IF NOT EXISTS idx_pms_yyyymm ON prosecutor_month_stats (yyyymm);

CREATE TABLE IF NOT EXISTS prosecutor_stats (
  name text NOT NULL,
  office_name text NOT NULL,
  case_count_total int,
  case_count_by_year jsonb,
  case_type_distribution jsonb,
  first_yyyymm text,
  last_yyyymm text,
  refreshed_at timestamptz DEFAULT now(),
  PRIMARY KEY (name, office_name)
);

ALTER TABLE prosecutor_month_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE prosecutor_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_pms" ON prosecutor_month_stats;
CREATE POLICY "auth_read_pms" ON prosecutor_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "auth_read_ps" ON prosecutor_stats;
CREATE POLICY "auth_read_ps" ON prosecutor_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_prosecutor_stats() RETURNS void AS $$
BEGIN
  TRUNCATE prosecutor_stats;
  INSERT INTO prosecutor_stats
    (name, office_name, case_count_total, case_count_by_year,
     case_type_distribution, first_yyyymm, last_yyyymm, refreshed_at)
  SELECT g.name, g.office_name, g.total,
    (SELECT jsonb_object_agg(t.y, t.c) FROM (
       SELECT left(m2.yyyymm, 4) AS y, sum(m2.case_count) AS c
       FROM prosecutor_month_stats m2
       WHERE m2.name = g.name AND m2.office_name = g.office_name
       GROUP BY 1) t),
    (SELECT jsonb_object_agg(t2.k, t2.v) FROM (
       SELECT e.key AS k, sum((e.value)::text::int) AS v
       FROM prosecutor_month_stats m3, jsonb_each(m3.cats) e
       WHERE m3.name = g.name AND m3.office_name = g.office_name
       GROUP BY e.key) t2),
    g.first_ym, g.last_ym, now()
  FROM (
    SELECT name, office_name, sum(case_count)::int AS total,
           min(yyyymm) AS first_ym, max(yyyymm) AS last_ym
    FROM prosecutor_month_stats GROUP BY name, office_name
  ) g;
END $$ LANGUAGE plpgsql SECURITY DEFINER;

-- 地檢署層級統計（前端檢察官頁圖表用）
CREATE OR REPLACE FUNCTION prosecutor_office_statistics()
RETURNS TABLE (office_name text, prosecutor_count bigint, total_cases bigint, avg_cases numeric)
LANGUAGE sql SECURITY DEFINER
AS $$
  SELECT office_name,
         count(*)::bigint,
         sum(case_count_total)::bigint,
         round(avg(case_count_total), 0)
  FROM prosecutor_stats
  GROUP BY office_name
  ORDER BY count(*) DESC;
$$;

GRANT EXECUTE ON FUNCTION prosecutor_office_statistics() TO anon, authenticated;

-- 資料來源登記
INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('裁判書檢察官統計', 'https://opendata.judicial.gov.tw/', '司法院裁判書開放資料 - 刑事裁判書萃取檢察官（起訴/蒞庭）統計', 'prosecutors', 'judgment_stats', 'monthly')
ON CONFLICT (name) DO NOTHING;
