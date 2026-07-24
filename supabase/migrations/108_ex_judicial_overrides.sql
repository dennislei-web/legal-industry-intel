-- 108: ex_judicial 人工 override 白名單 ＋ 檢察官側遞延容忍修正
--
-- 兩個修正（源自喆律許致維/方心瑜誤殺、林敬修誤標的實測）：
-- 1. 檢察官遞延：起訴檢察官在卸任後數年仍具名於裁判書（案件審理期），
--    「最後具名月」天生高估卸任時點 → 檢察官側的重疊/證號中段/首見月三訊號
--    一律改用「有效卸任 = 最後具名 - 36 個月」判斷。法官具名為裁判當下，無此問題，維持嚴格。
-- 2. ex_judicial_overrides 人工白名單：使用者確認的事實直接覆寫 confidence
--    （confirm→high / reject→conflict），refresh 後套用，不會被重算洗掉。

CREATE TABLE IF NOT EXISTS ex_judicial_overrides (
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('judge', 'prosecutor')),
  confidence_override TEXT NOT NULL CHECK (confidence_override IN ('high', 'conflict')),
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (name, kind)
);

ALTER TABLE ex_judicial_overrides ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ex_judicial_ovr" ON ex_judicial_overrides;
CREATE POLICY "auth_read_ex_judicial_ovr" ON ex_judicial_overrides
  FOR SELECT USING (auth.uid() IS NOT NULL);

INSERT INTO ex_judicial_overrides (name, kind, confidence_override, note) VALUES
  ('許致維', 'prosecutor', 'high', '使用者確認為檢察官轉任（喆律，112 領證）'),
  ('方心瑜', 'prosecutor', 'high', '使用者確認為檢察官轉任（喆律，113 領證）'),
  ('林敬修', 'judge', 'conflict', '喆律林敬修民國 89 年生，與 2000-2012 高院同名法官非同一人')
ON CONFLICT (name, kind) DO UPDATE
  SET confidence_override = EXCLUDED.confidence_override, note = EXCLUDED.note;

CREATE OR REPLACE FUNCTION refresh_ex_judicial_lawyers()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  DELETE FROM ex_judicial_lawyers;

  -- 法官側（具名＝裁判當下，維持嚴格訊號）
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

  -- 檢察官側（起訴具名遞延：有效卸任 = 最後具名 - 36 個月）
  WITH ml AS (
    SELECT name, min(NULLIF(substring(lic_no from '^\(?(\d{2,3})'), '')::int) AS lic_year,
           to_char(min(scraped_at), 'YYYYMM') AS first_seen_ym,
           max(birth_year) AS byr
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
                AND (1911 + ml.lic_year) < left(pm.l, 4)::int - 3 THEN 'conflict'
           WHEN ml.first_seen_ym <= to_char(to_date(pm.l, 'YYYYMM') - interval '36 months', 'YYYYMM') THEN 'conflict'
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
      AND lj.y > left(pm.f, 4)::int AND lj.y < left(pm.l, 4)::int - 3
  ) ov ON true;

  -- 人工 override 最後套用（confirm→high / reject→conflict）
  UPDATE ex_judicial_lawyers e
  SET confidence = o.confidence_override
  FROM ex_judicial_overrides o
  WHERE e.name = o.name AND e.kind = o.kind;
$fn$;

SELECT refresh_ex_judicial_lawyers();
