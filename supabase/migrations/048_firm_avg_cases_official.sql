-- 048: 事務所平均案件數改官方口徑（Lawsnote 下架收尾）
-- avg_cases 分子從 lawsnote_lawyers.case_count_5yr 換成 lawyer_judgment_stats.cases_5yr
-- （公開裁判書近 5 年出庭數，下限估計）；律師→事務所走 moj 名冊姓名唯一對應
-- （同名多筆不計，口徑與 firm_court_ranking / lawyers_with_stats 一致）。
-- 分母維持 MOJ 律師人數不變；firm_key 正規化沿用 013。

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
  -- 官方裁判書出庭數：MOJ 名冊姓名唯一者才歸戶（同名多筆＝歸屬不明，不計）
  uniq_names AS (
    SELECT name, MIN(firm_key) AS firm_key
    FROM normalized
    GROUP BY name
    HAVING COUNT(*) = 1
  ),
  firm_cases AS (
    SELECT
      u.firm_key AS firm_name,
      SUM(s.cases_5yr) AS total_cases
    FROM uniq_names u
    JOIN lawyer_judgment_stats s ON s.name = u.name
    GROUP BY u.firm_key
  )
  SELECT
    fl.firm_name,
    fl.lawyer_count,
    fl.main_region,
    fl.guild_names,
    -- 平均案件數 = 官方近 5 年出庭總數 ÷ MOJ 律師人數
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
