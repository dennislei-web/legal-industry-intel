-- 107: 前法官/前檢察官 × 現行律師名冊比對（ex_judicial_lawyers）
--
-- 口徑：judge_month_stats（裁判書法官欄逐月）與 prosecutor_stats（起訴/到庭檢察官）
-- 的姓名 × moj_lawyers 現行名冊交集。純姓名比對，同名風險用三道訊號剔除：
--   1. overlap_years：司法官任期「中段」年份（頭尾轉換年不算）該姓名仍以律師身分
--      出庭的年數 ≥2 → 視為同名兩人（conflict）
--   2. 律師證號民國年落在任期中段（現職司法官不可能中途新領律師證）→ conflict
--   3. 律師首次入冊月（min(scraped_at)，upsert 不覆蓋≈首見）≤ 司法官最後具名月
--      → 司法官還在任時律師已同時在冊（交易型律師無出庭、訊號1測不到的同名）→ conflict
--   4. 年齡檢核：司法官任期起始年時該律師未滿 25 歲（司法官最年輕約 26-27）→ conflict
--      （案例：林敬修，民國 89 年生，被比對到 2000-2012 高院同名法官）
--   5. 領證間隔：律師證號年比司法官最後具名年晚 >5 年（真轉任幾乎 1-2 年內領證）→ uncertain
-- 前端只顯示 confidence in ('high','medium')，並在 tooltip 註明為姓名比對推定。

CREATE TABLE IF NOT EXISTS ex_judicial_lawyers (
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('judge', 'prosecutor')),
  first_yyyymm TEXT,
  last_yyyymm TEXT,
  active_months INT,            -- 檢察官側無逐月資料，為 NULL
  case_count_total BIGINT,
  main_org TEXT,                -- 案量最大的法院/地檢署
  lic_year INT,                 -- 律師證號民國年（同名多證取最早）
  overlap_years INT NOT NULL DEFAULT 0,
  confidence TEXT NOT NULL,     -- high / medium / uncertain / conflict
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (name, kind)
);

CREATE INDEX IF NOT EXISTS idx_ex_judicial_conf ON ex_judicial_lawyers(confidence);

ALTER TABLE ex_judicial_lawyers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ex_judicial" ON ex_judicial_lawyers;
CREATE POLICY "auth_read_ex_judicial" ON ex_judicial_lawyers
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_ex_judicial_lawyers()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  DELETE FROM ex_judicial_lawyers;

  -- 法官側
  WITH ml AS (
    SELECT name, min(NULLIF(substring(lic_no from '^\(?(\d{2,3})'), '')::int) AS lic_year,
           to_char(min(scraped_at), 'YYYYMM') AS first_seen_ym,
           max(birth_year) AS byr  -- 同名取最年輕（任一同名者年齡不合即視為 ambiguous）
    FROM moj_lawyers
    GROUP BY name
  ),
  jm AS (
    SELECT name,
           min(yyyymm) AS f, max(yyyymm) AS l,
           count(DISTINCT yyyymm)::int AS months,
           sum(case_count)::bigint AS total
    FROM judge_month_stats
    GROUP BY name
  ),
  jorg AS (
    SELECT DISTINCT ON (name) name, court_name AS main_org
    FROM (
      SELECT name, court_name, sum(case_count) AS cc
      FROM judge_month_stats GROUP BY name, court_name
    ) t
    ORDER BY name, cc DESC
  ),
  lj AS (
    SELECT s.name, (e.key)::int AS y
    FROM lawyer_judgment_stats s, jsonb_each_text(s.by_year) e
    WHERE (e.value)::int > 0
  )
  INSERT INTO ex_judicial_lawyers
    (name, kind, first_yyyymm, last_yyyymm, active_months, case_count_total,
     main_org, lic_year, overlap_years, confidence)
  SELECT jm.name, 'judge', jm.f, jm.l, jm.months, jm.total,
         jorg.main_org, ml.lic_year, COALESCE(ov.n, 0),
         CASE
           WHEN COALESCE(ov.n, 0) >= 2 THEN 'conflict'
           WHEN ml.lic_year IS NOT NULL
                AND (1911 + ml.lic_year) > left(jm.f, 4)::int
                AND (1911 + ml.lic_year) < left(jm.l, 4)::int THEN 'conflict'
           WHEN ml.first_seen_ym <= jm.l THEN 'conflict'
           WHEN ml.byr IS NOT NULL AND ml.byr < 200
                AND left(jm.f, 4)::int - (1911 + ml.byr) < 25 THEN 'conflict'
           WHEN ml.lic_year IS NOT NULL
                AND (1911 + ml.lic_year) > left(jm.l, 4)::int + 5 THEN 'uncertain'
           WHEN jm.months < 6 OR jm.total < 10 THEN 'uncertain'
           WHEN COALESCE(ov.n, 0) = 1 THEN 'medium'
           ELSE 'high'
         END
  FROM jm
  JOIN ml ON ml.name = jm.name
  LEFT JOIN jorg ON jorg.name = jm.name
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS n FROM lj
    WHERE lj.name = jm.name
      AND lj.y > left(jm.f, 4)::int AND lj.y < left(jm.l, 4)::int
  ) ov ON true;

  -- 檢察官側
  WITH ml AS (
    SELECT name, min(NULLIF(substring(lic_no from '^\(?(\d{2,3})'), '')::int) AS lic_year,
           to_char(min(scraped_at), 'YYYYMM') AS first_seen_ym,
           max(birth_year) AS byr  -- 同名取最年輕（任一同名者年齡不合即視為 ambiguous）
    FROM moj_lawyers
    GROUP BY name
  ),
  pm AS (
    SELECT name,
           min(first_yyyymm) AS f, max(last_yyyymm) AS l,
           sum(case_count_total)::bigint AS total
    FROM prosecutor_stats
    GROUP BY name
  ),
  porg AS (
    SELECT DISTINCT ON (name) name, office_name AS main_org
    FROM prosecutor_stats
    ORDER BY name, case_count_total DESC
  ),
  lj AS (
    SELECT s.name, (e.key)::int AS y
    FROM lawyer_judgment_stats s, jsonb_each_text(s.by_year) e
    WHERE (e.value)::int > 0
  )
  INSERT INTO ex_judicial_lawyers
    (name, kind, first_yyyymm, last_yyyymm, active_months, case_count_total,
     main_org, lic_year, overlap_years, confidence)
  SELECT pm.name, 'prosecutor', pm.f, pm.l, NULL, pm.total,
         porg.main_org, ml.lic_year, COALESCE(ov.n, 0),
         CASE
           WHEN COALESCE(ov.n, 0) >= 2 THEN 'conflict'
           WHEN ml.lic_year IS NOT NULL
                AND (1911 + ml.lic_year) > left(pm.f, 4)::int
                AND (1911 + ml.lic_year) < left(pm.l, 4)::int THEN 'conflict'
           WHEN ml.first_seen_ym <= pm.l THEN 'conflict'
           WHEN ml.byr IS NOT NULL AND ml.byr < 200
                AND left(pm.f, 4)::int - (1911 + ml.byr) < 25 THEN 'conflict'
           WHEN ml.lic_year IS NOT NULL
                AND (1911 + ml.lic_year) > left(pm.l, 4)::int + 5 THEN 'uncertain'
           WHEN pm.total < 10 THEN 'uncertain'
           WHEN COALESCE(ov.n, 0) = 1 THEN 'medium'
           ELSE 'high'
         END
  FROM pm
  JOIN ml ON ml.name = pm.name
  LEFT JOIN porg ON porg.name = pm.name
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS n FROM lj
    WHERE lj.name = pm.name
      AND lj.y > left(pm.f, 4)::int AND lj.y < left(pm.l, 4)::int
  ) ov ON true;
$fn$;

SELECT refresh_ex_judicial_lawyers();
