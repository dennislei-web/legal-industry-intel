-- ============================================================
-- 013: 修正 moj_firm_statistics 中 Lawsnote firm_name 正規化
-- ============================================================
-- 問題：lawsnote_lawyers.firm_name 常包含超長描述，例如
--   "謙聖國際法律事務所主持律師南北各大酒店法律顧問..."
-- 導致 JOIN 事務所名稱時匹配失敗，avg_cases 為 null。
--
-- 修正：對 lawsnote firm_name 也做同樣的 regex 正規化，
-- 擷取到第一個「法律事務所」或「律師事務所」為止。
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
  -- 對 lawsnote 的 firm_name 做同樣的正規化
  lawsnote_normalized AS (
    SELECT
      CASE
        WHEN firm_name ~ '(法律事務所|律師事務所)'
          THEN REGEXP_REPLACE(firm_name, '^(.+?(?:法律|律師)事務所).*$', '\1')
        ELSE REPLACE(firm_name, ' ', '')
      END AS firm_name_clean,
      case_count_5yr
    FROM lawsnote_lawyers
    WHERE firm_name IS NOT NULL AND case_count_5yr IS NOT NULL
  ),
  firm_cases AS (
    SELECT
      firm_name_clean AS firm_name,
      SUM(case_count_5yr) AS total_cases
    FROM lawsnote_normalized
    GROUP BY firm_name_clean
  )
  SELECT
    fl.firm_name,
    fl.lawyer_count,
    fl.main_region,
    fl.guild_names,
    -- 平均案件數 = Lawsnote 總案件數 ÷ MOJ 律師人數
    CASE WHEN fc.total_cases IS NOT NULL AND fl.lawyer_count > 0
      THEN ROUND(fc.total_cases::numeric / fl.lawyer_count, 0)
      ELSE NULL
    END AS avg_cases,
    fw.website_url
  FROM firm_lawyers fl
  LEFT JOIN firm_cases fc ON fc.firm_name = fl.firm_name
  LEFT JOIN firm_websites fw ON (
    fw.firm_name = fl.firm_name
    OR REPLACE(fw.firm_name, ' ', '') = fl.firm_name
  )
  ORDER BY fl.lawyer_count DESC;
$$;

GRANT EXECUTE ON FUNCTION moj_firm_statistics() TO anon, authenticated;

-- 刷新 cache (一般 table，非 materialized view)
TRUNCATE moj_firm_stats_cache;
INSERT INTO moj_firm_stats_cache (firm_name, lawyer_count, main_region, avg_cases, website_url, refreshed_at)
SELECT firm_name, lawyer_count, main_region, avg_cases, website_url, now()
FROM moj_firm_statistics();
