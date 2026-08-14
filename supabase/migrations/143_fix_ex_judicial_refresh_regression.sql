-- 143: 修復 mig 141 重寫 refresh_ex_judicial_lawyers() 時的三項 regression
--
-- mig 141 是從 mig 107 的舊版函式改寫（加 gazette 語意），漏掉 108/109 的後續修正：
--   1. firm_name（mig 109）：refresh 時從 moj_lawyers.office_normalized 帶入。
--      遺失後全部 judgment 列 firm_name=NULL → 事務所名錄 ⚖️ 徽章、法檢轉任×事務所圖
--      的自動比對側整批漏人（協合 3 位前法官、平安恩慈沈宜生/王仁貴/鄭光婷等）。
--   2. 檢察官具名遞延 36 個月（mig 108）：起訴書具名滯後於離任，conflict 判定須以
--      「最後具名 - 36 個月」為有效卸任；遺失後真前檢察官被誤標 conflict 剔除。
--   3. ex_judicial_overrides 人工白名單套用（mig 108/109）：refresh 收尾要套
--      confirm→high / reject→conflict；遺失後人工修正在每次 refresh 被洗掉。
--
-- 本檔 = mig 141 的 gazette 語意（只刪 judgment 側、ON CONFLICT 讓位規則）
--        ＋ mig 109 的完整訊號邏輯（firm_name / 遞延 / overrides）。

CREATE OR REPLACE FUNCTION refresh_ex_judicial_lawyers()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  DELETE FROM ex_judicial_lawyers WHERE source = 'judgment';

  -- 法官側（具名＝裁判當下，維持嚴格訊號）
  WITH ml AS (
    SELECT name, min(NULLIF(substring(lic_no from '^\(?(\d{2,3})'), '')::int) AS lic_year,
           to_char(min(scraped_at), 'YYYYMM') AS first_seen_ym,
           max(birth_year) AS byr,  -- 同名取最年輕（任一同名者年齡不合即視為 ambiguous）
           (array_agg(office_normalized ORDER BY updated_at DESC)
              FILTER (WHERE office_normalized IS NOT NULL))[1] AS firm
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
     main_org, lic_year, overlap_years, confidence, firm_name, source)
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
         ml.firm, 'judgment'
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
    firm_name = EXCLUDED.firm_name,
    source = 'judgment',
    refreshed_at = now()
  WHERE EXCLUDED.confidence IN ('high', 'medium');
  -- gazette 列僅在 judgment 訊號為高/中信心時讓位；uncertain/conflict 殘訊號不搶位

  -- 檢察官側（起訴具名遞延：有效卸任 = 最後具名 - 36 個月）
  WITH ml AS (
    SELECT name, min(NULLIF(substring(lic_no from '^\(?(\d{2,3})'), '')::int) AS lic_year,
           to_char(min(scraped_at), 'YYYYMM') AS first_seen_ym,
           max(birth_year) AS byr,
           (array_agg(office_normalized ORDER BY updated_at DESC)
              FILTER (WHERE office_normalized IS NOT NULL))[1] AS firm
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
     main_org, lic_year, overlap_years, confidence, firm_name, source)
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
         END,
         ml.firm, 'judgment'
  FROM pm
  JOIN ml ON ml.name = pm.name
  LEFT JOIN porg ON porg.name = pm.name
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS n FROM lj
    WHERE lj.name = pm.name
      AND lj.y > left(pm.f, 4)::int AND lj.y < left(pm.l, 4)::int - 3
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
    firm_name = EXCLUDED.firm_name,
    source = 'judgment',
    refreshed_at = now()
  WHERE EXCLUDED.confidence IN ('high', 'medium');
  -- gazette 列僅在 judgment 訊號為高/中信心時讓位；uncertain/conflict 殘訊號不搶位

  -- gazette 列 firm_name 同步（mig 141 缺口：候選皆現行名冊律師，卻沒帶事務所 →
  -- 名錄 ⚖️ 徽章與法檢轉任圖漏 gazette 人；每次 refresh 順帶更新換所）
  UPDATE ex_judicial_lawyers e
  SET firm_name = ml.firm
  FROM (
    SELECT name, (array_agg(office_normalized ORDER BY updated_at DESC)
                    FILTER (WHERE office_normalized IS NOT NULL))[1] AS firm
    FROM moj_lawyers GROUP BY name
  ) ml
  WHERE e.source = 'gazette' AND ml.name = e.name AND ml.firm IS NOT NULL;

  -- 人工 override 最後套用（confirm→high / reject→conflict）
  UPDATE ex_judicial_lawyers e
  SET confidence = o.confidence_override
  FROM ex_judicial_overrides o
  WHERE e.name = o.name AND e.kind = o.kind;
$fn$;

SELECT refresh_ex_judicial_lawyers();
