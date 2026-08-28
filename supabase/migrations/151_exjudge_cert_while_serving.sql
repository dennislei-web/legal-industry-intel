-- 151: 修正訊號 2 誤殺「在職先領證、退場後執業」的真轉任司法官
--
-- 問題：mig 107/143 的訊號 2 假設「現職司法官不可能中途新領律師證」→ 領證年落在
-- 任期中段一律 conflict。但律師法第 3 條允許司法官憑資格「請領律師證書」（領證
-- ≠ 登錄執業），大量法官/檢察官在退場前數年先領證備轉。這批真轉任全被 conflict
-- 剔除，退場法官頁「轉任律師」欄嚴重低報（24 月窗實測：劉嶽承/伯衡、呂明坤/
-- 呂明坤律師事務所、謝靜恒/靜恒法律事務所、梁堯銘/梁堯銘律師事務所、李正紀/
-- 元通、黃秀敏/聯發科——同名開所、年齡吻合，全是被誤殺的真轉任）。
--
-- 修正：領證年在任期內不再單獨 conflict，改為——
--   * 無執業重疊（overlap=0）且案量/月數達門檻 → 'medium'（在職領證備轉推定）
--   * 有 1 年重疊或活躍度不足 → 'uncertain'（維持不上前端）
-- 真同名衝突仍由其餘訊號把關：執業重疊 ≥2 年 conflict、名冊首見 ≤ 最後具名月
-- conflict（在任時律師已在冊）、年齡不合 conflict。訊號順序改為先驗這三道，
-- 最後才輪到領證時點分流。檢察官側同步修正（有效卸任 = 最後具名 - 36 個月）。
--
-- 其餘邏輯（gazette 讓位、firm_name、overrides 收尾）與 mig 143 相同。

CREATE OR REPLACE FUNCTION refresh_ex_judicial_lawyers()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  DELETE FROM ex_judicial_lawyers WHERE source = 'judgment';

  -- 法官側（具名＝裁判當下）
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
           WHEN ml.first_seen_ym <= jm.l THEN 'conflict'
           WHEN ml.byr IS NOT NULL AND ml.byr < 200
                AND left(jm.f, 4)::int - (1911 + ml.byr) < 25 THEN 'conflict'
           WHEN ml.lic_year IS NOT NULL
                AND (1911 + ml.lic_year) > left(jm.f, 4)::int
                AND (1911 + ml.lic_year) < left(jm.l, 4)::int THEN
             CASE WHEN COALESCE(ov.n, 0) = 0 AND jm.months >= 6 AND jm.total >= 10
                  THEN 'medium' ELSE 'uncertain' END
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
           WHEN ml.first_seen_ym <= to_char(to_date(pm.l, 'YYYYMM') - interval '36 months', 'YYYYMM') THEN 'conflict'
           WHEN ml.byr IS NOT NULL AND ml.byr < 200
                AND left(pm.f, 4)::int - (1911 + ml.byr) < 25 THEN 'conflict'
           WHEN ml.lic_year IS NOT NULL
                AND (1911 + ml.lic_year) > left(pm.f, 4)::int
                AND (1911 + ml.lic_year) < left(pm.l, 4)::int - 3 THEN
             CASE WHEN COALESCE(ov.n, 0) = 0 AND pm.total >= 10
                  THEN 'medium' ELSE 'uncertain' END
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

  -- gazette 列 firm_name 同步
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
