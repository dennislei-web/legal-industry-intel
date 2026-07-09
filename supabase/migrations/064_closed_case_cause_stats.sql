-- 終結案件微資料「案由細分」聚合（closed_case_stats.py 產出，mapping 見 scripts/cause_map.py）
-- 兩層設計（控制列數，Micro compute）：
--   closed_case_cause_stats    月×法院×檔型×種類（mapping 後），供法院比較/年度趨勢
--   closed_case_cause_national 月×檔型×原始案由（全國），供種類鑽取與 mapping 稽核
-- 檔型：民事訴訟/民事非訟/家事訴訟/家事非訟/刑事訴訟（刑事僅地院，cause=法名§條-之N，
-- 計數單位=被告人次（每被告取第一個罪名層列當主要罪名），convicted=科刑人次）

CREATE TABLE IF NOT EXISTS closed_case_cause_stats (
  yyyymm text NOT NULL,
  court_name text NOT NULL,
  file_type text NOT NULL,
  cause_group text NOT NULL,   -- 種類（民訴=官方13類；家非=官方細項；刑=罪章/特別法名）
  case_count int NOT NULL,
  convicted int,               -- 刑事：科刑（有期徒刑/拘役/罰金/無期/死刑）被告人次
  PRIMARY KEY (yyyymm, court_name, file_type, cause_group)
);
CREATE INDEX IF NOT EXISTS idx_cccs_type_group ON closed_case_cause_stats (file_type, cause_group, yyyymm);

CREATE TABLE IF NOT EXISTS closed_case_cause_national (
  yyyymm text NOT NULL,
  file_type text NOT NULL,
  cause text NOT NULL,         -- 正規化原始案由（全形轉半形、去空白）；刑事=法名§條-之N
  cause_group text NOT NULL,
  case_count int NOT NULL,
  convicted int,
  PRIMARY KEY (yyyymm, file_type, cause)
);
CREATE INDEX IF NOT EXISTS idx_cccn_group ON closed_case_cause_national (file_type, cause_group, yyyymm);

ALTER TABLE closed_case_cause_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_cccs" ON closed_case_cause_stats;
CREATE POLICY "auth_read_cccs" ON closed_case_cause_stats FOR SELECT USING (auth.uid() IS NOT NULL);
ALTER TABLE closed_case_cause_national ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_cccn" ON closed_case_cause_national;
CREATE POLICY "auth_read_cccn" ON closed_case_cause_national FOR SELECT USING (auth.uid() IS NOT NULL);

-- 已回填月份（backfill-causes 模式用；cause 表列數大，不走 PostgREST select）
CREATE OR REPLACE FUNCTION closed_case_cause_months()
RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(array_agg(DISTINCT yyyymm), '{}') FROM closed_case_cause_stats;
$$;

-- 年度×種類（全國，前端趨勢圖/卡片牆）。年=西元曆年（yyyymm 前 4 碼）
CREATE OR REPLACE FUNCTION cause_group_yearly(p_file_type text)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.y, t.n DESC), '[]'::json) FROM (
    SELECT left(yyyymm, 4) AS y, cause_group,
           sum(case_count)::int AS n, sum(convicted)::int AS convicted,
           count(DISTINCT yyyymm)::int AS months
    FROM closed_case_cause_stats
    WHERE file_type = p_file_type
    GROUP BY 1, 2) t;
$$;

-- 種類 → 原始案由 top N（全國，鑽取）
CREATE OR REPLACE FUNCTION cause_raw_top(p_file_type text, p_group text, p_year text DEFAULT NULL, p_limit int DEFAULT 30)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
    SELECT cause, sum(case_count)::int AS n, sum(convicted)::int AS convicted
    FROM closed_case_cause_national
    WHERE file_type = p_file_type AND cause_group = p_group
      AND (p_year IS NULL OR left(yyyymm, 4) = p_year)
    GROUP BY cause ORDER BY n DESC LIMIT p_limit) t;
$$;

-- 法院×種類（單年，法院比較）
CREATE OR REPLACE FUNCTION cause_court_matrix(p_file_type text, p_year text, p_group text DEFAULT NULL)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.n DESC), '[]'::json) FROM (
    SELECT court_name, cause_group, sum(case_count)::int AS n
    FROM closed_case_cause_stats
    WHERE file_type = p_file_type AND left(yyyymm, 4) = p_year
      AND (p_group IS NULL OR cause_group = p_group)
    GROUP BY 1, 2) t;
$$;

GRANT EXECUTE ON FUNCTION closed_case_cause_months() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_group_yearly(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_raw_top(text, text, text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_court_matrix(text, text, text) TO anon, authenticated;
