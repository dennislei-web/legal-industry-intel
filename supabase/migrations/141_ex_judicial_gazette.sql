-- 141: 前法官/檢察官公報回補線（gazette 訊號）
--
-- 背景：裁判書署名資料 2000 年才全量（1996-1999 僅最高法院系統 2 院），此前退場
-- 轉律師的司法官在 mig 107 五訊號比對是系統性零覆蓋。本線以候選名單（現行名冊、
-- 民國 89 前領證、領證年齡 >=38）逐名查政大「中華民國政府官職資料庫」
-- (gpost.lib.nccu.edu.tw，總統府公報任免令)，萃取「曾任推事/法官/檢察官」事實層。
-- 案件量統計無源可補（裁判書未電子化），只回補經歷；來源逐筆存公報期數＋PDF 連結。
-- 產線：scripts/exjudge_gazette_backfill.py（crawl → classify 消歧 → upload）。
--
-- 設計：
--   1. ex_judicial_gazette_events：任免令逐筆（經歷卡時間軸用）
--   2. ex_judicial_lawyers 加 source 欄（judgment=裁判書署名比對 / gazette=公報考據），
--      既有徽章/切換 pill/tooltip 前端不用改就會帶出 gazette 人
--   3. refresh_ex_judicial_lawyers() 只重算 judgment 側、保留 gazette 列；
--      同一人若日後長出「高/中信心」署名訊號，judgment 版以 ON CONFLICT 覆蓋 gazette 版；
--      uncertain/conflict 殘訊號不搶位（院長/檢察長少具名，公報任免鏈是較強證據）

CREATE TABLE IF NOT EXISTS ex_judicial_gazette_events (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('judge', 'prosecutor')),
  action TEXT NOT NULL,                 -- 任 / 免
  reason TEXT,                          -- 任命 / 另有任用 / 呈請辭職...
  order_date_roc TEXT,                  -- 命令日期（民國 yyy-mm-dd 字串，照公報原樣）
  org TEXT NOT NULL,                    -- 機關｜官/職等｜職務 全文
  gazette TEXT,                         -- 公報期數（如 總統府(民國37年後)No.4552）
  pdf_url TEXT,                         -- 公報原稿 PDF
  source TEXT NOT NULL DEFAULT 'gpost',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (name, kind, action, order_date_roc, org)
);

CREATE INDEX IF NOT EXISTS idx_exj_gazette_name ON ex_judicial_gazette_events(name);

ALTER TABLE ex_judicial_gazette_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_exj_gazette" ON ex_judicial_gazette_events;
CREATE POLICY "auth_read_exj_gazette" ON ex_judicial_gazette_events
  FOR SELECT USING (auth.uid() IS NOT NULL);

ALTER TABLE ex_judicial_lawyers
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'judgment';

-- 重建 refresh：只動 judgment 側，gazette 列常駐；衝突時 judgment 覆蓋（訊號較豐）
CREATE OR REPLACE FUNCTION refresh_ex_judicial_lawyers()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  DELETE FROM ex_judicial_lawyers WHERE source = 'judgment';

  -- 法官側
  WITH ml AS (
    SELECT name, min(NULLIF(substring(lic_no from '^\(?(\d{2,3})'), '')::int) AS lic_year,
           to_char(min(scraped_at), 'YYYYMM') AS first_seen_ym,
           max(birth_year) AS byr
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
     main_org, lic_year, overlap_years, confidence, source)
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
         END,
         'judgment'
  FROM jm
  JOIN ml ON ml.name = jm.name
  LEFT JOIN jorg ON jorg.name = jm.name
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS n FROM lj
    WHERE lj.name = jm.name
      AND lj.y > left(jm.f, 4)::int AND lj.y < left(jm.l, 4)::int
  ) ov ON true
  ON CONFLICT (name, kind) DO UPDATE SET
    first_yyyymm = EXCLUDED.first_yyyymm,
    last_yyyymm = EXCLUDED.last_yyyymm,
    active_months = EXCLUDED.active_months,
    case_count_total = EXCLUDED.case_count_total,
    main_org = EXCLUDED.main_org,
    lic_year = EXCLUDED.lic_year,
    overlap_years = EXCLUDED.overlap_years,
    confidence = EXCLUDED.confidence,
    source = 'judgment',
    refreshed_at = now()
  WHERE EXCLUDED.confidence IN ('high', 'medium');
  -- gazette 列僅在 judgment 訊號為高/中信心時讓位；uncertain/conflict 殘訊號不搶位
  -- （例：院長/檢察長少具名 → 署名僅零星月份被降 uncertain，公報任免鏈反而是較強證據）

  -- 檢察官側
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
     main_org, lic_year, overlap_years, confidence, source)
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
         END,
         'judgment'
  FROM pm
  JOIN ml ON ml.name = pm.name
  LEFT JOIN porg ON porg.name = pm.name
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS n FROM lj
    WHERE lj.name = pm.name
      AND lj.y > left(pm.f, 4)::int AND lj.y < left(pm.l, 4)::int
  ) ov ON true
  ON CONFLICT (name, kind) DO UPDATE SET
    first_yyyymm = EXCLUDED.first_yyyymm,
    last_yyyymm = EXCLUDED.last_yyyymm,
    active_months = EXCLUDED.active_months,
    case_count_total = EXCLUDED.case_count_total,
    main_org = EXCLUDED.main_org,
    lic_year = EXCLUDED.lic_year,
    overlap_years = EXCLUDED.overlap_years,
    confidence = EXCLUDED.confidence,
    source = 'judgment',
    refreshed_at = now()
  WHERE EXCLUDED.confidence IN ('high', 'medium');
  -- gazette 列僅在 judgment 訊號為高/中信心時讓位；uncertain/conflict 殘訊號不搶位
  -- （例：院長/檢察長少具名 → 署名僅零星月份被降 uncertain，公報任免鏈反而是較強證據）
$fn$;
