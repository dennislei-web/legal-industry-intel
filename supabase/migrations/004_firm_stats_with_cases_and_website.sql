-- ============================================================
-- 補回 moj_firm_statistics 的 avg_cases 與 website_url 欄位
-- ============================================================
-- Regression fix: 原 RPC 只用 moj_lawyers，失去了
-- - Lawsnote 的平均案件數 (case_count_5yr)
-- - firm_websites 的官網 URL
-- 本 migration LEFT JOIN 補回兩個欄位
-- ============================================================

DROP FUNCTION IF EXISTS moj_firm_statistics();

CREATE FUNCTION moj_firm_statistics()
RETURNS TABLE (
  firm_name TEXT,
  lawyer_count BIGINT,
  main_region TEXT,
  guild_names TEXT[],
  avg_cases NUMERIC,
  website_url TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH firm_lawyers AS (
    SELECT
      office_normalized AS firm_name,
      COUNT(*)::BIGINT AS lawyer_count,
      MODE() WITHIN GROUP (ORDER BY main_region) AS main_region,
      ARRAY_AGG(DISTINCT g) FILTER (WHERE g IS NOT NULL) AS guild_names
    FROM moj_lawyers
    LEFT JOIN LATERAL UNNEST(guild_names) AS g ON TRUE
    WHERE office_normalized IS NOT NULL AND office_normalized <> ''
    GROUP BY office_normalized
  ),
  firm_cases AS (
    -- Lawsnote 的案件數（原始 firm_name）
    SELECT
      firm_name,
      ROUND(AVG(case_count_5yr)::numeric, 0) AS avg_cases
    FROM lawsnote_lawyers
    WHERE firm_name IS NOT NULL AND case_count_5yr IS NOT NULL
    GROUP BY firm_name
  ),
  firm_cases_norm AS (
    -- Lawsnote 的案件數（去空白後作為 fallback 配對）
    SELECT
      REPLACE(firm_name, ' ', '') AS firm_name,
      ROUND(AVG(case_count_5yr)::numeric, 0) AS avg_cases
    FROM lawsnote_lawyers
    WHERE firm_name IS NOT NULL AND case_count_5yr IS NOT NULL
    GROUP BY REPLACE(firm_name, ' ', '')
  )
  SELECT
    fl.firm_name,
    fl.lawyer_count,
    fl.main_region,
    fl.guild_names,
    COALESCE(fc.avg_cases, fcn.avg_cases) AS avg_cases,
    fw.website_url
  FROM firm_lawyers fl
  LEFT JOIN firm_cases fc ON fc.firm_name = fl.firm_name
  LEFT JOIN firm_cases_norm fcn ON fcn.firm_name = fl.firm_name
  LEFT JOIN firm_websites fw ON (
    fw.firm_name = fl.firm_name
    OR REPLACE(fw.firm_name, ' ', '') = fl.firm_name
  )
  ORDER BY fl.lawyer_count DESC;
$$;

GRANT EXECUTE ON FUNCTION moj_firm_statistics() TO anon, authenticated;
