-- ============================================================
-- moj_firm_statistics: 將分所合併到主事務所
-- ============================================================
-- 原本 RPC 用 office_normalized 完全匹配做 GROUP BY，導致
-- "喆律法律事務所" / "喆律法律事務所新竹所" / "喆律法律事務所-台南分所"
-- 被視為 3 個不同事務所。
--
-- 本次用 regex 擷取到第一個「法律事務所」或「律師事務所」為止
-- 作為 canonical firm_key，分所自動歸到主所。
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
  WITH normalized AS (
    -- 將 "喆律法律事務所新竹所" / "喆律法律事務所-台南分所" 等分所
    -- 標準化為 "喆律法律事務所"
    SELECT
      name,
      lic_no,
      main_region,
      guild_names,
      CASE
        WHEN office_normalized ~ '(法律事務所|律師事務所)'
          THEN REGEXP_REPLACE(office_normalized, '^(.+?(?:法律|律師)事務所).*$', '\1')
        ELSE office_normalized
      END AS firm_key
    FROM moj_lawyers
    WHERE office_normalized IS NOT NULL AND office_normalized <> ''
  ),
  firm_lawyers AS (
    SELECT
      firm_key AS firm_name,
      COUNT(*)::BIGINT AS lawyer_count,
      MODE() WITHIN GROUP (ORDER BY main_region) AS main_region,
      ARRAY_AGG(DISTINCT g) FILTER (WHERE g IS NOT NULL) AS guild_names
    FROM normalized
    LEFT JOIN LATERAL UNNEST(guild_names) AS g ON TRUE
    GROUP BY firm_key
  ),
  firm_cases AS (
    SELECT
      firm_name,
      ROUND(AVG(case_count_5yr)::numeric, 0) AS avg_cases
    FROM lawsnote_lawyers
    WHERE firm_name IS NOT NULL AND case_count_5yr IS NOT NULL
    GROUP BY firm_name
  ),
  firm_cases_norm AS (
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
