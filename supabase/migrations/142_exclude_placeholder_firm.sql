-- ============================================================
-- 142: 事務所統計排除官方佔位字串「律師未顯示」
-- ============================================================
-- 問題：法務部 lawyerbc 名冊中，律師未登錄（或不公開）所屬事務所時，
--   office 欄位回傳字面值「律師未顯示」。moj_firm_statistics() 只排除
--   NULL/空字串，66 位此類律師被 GROUP BY 成一間虛構「事務所」，
--   在事務所名錄以 66 人排到第 5 名（主持律師「-」、無成立年份）。
--
-- 修法：normalized CTE 加排除該佔位字串。這些律師本人不受影響，
--   仍在律師名錄；只是不再被虛構成一間所。
--   moj_solo_firm_lawyers 不需改（LIKE '%事務所%' 天然排除）。
--
-- = 079 全文照抄，僅 normalized CTE 加一條 WHERE
-- ⚠️⚠️ 日後再重寫本函數時，務必保留 clean_web 官網清洗段！（048 弄丟過一次）
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
      AND office_normalized <> '律師未顯示'  -- 142: 官方佔位字串不是事務所
      AND deregistered_at IS NULL   -- 079: 已除名者不計入事務所統計
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
  ),
  -- 官網清洗（042 引入、048 曾弄丟、065 恢復——重寫函數時務必保留本段）：
  --   verified = 首頁含所名（website_verify.py 驗過才 TRUE）
  --   再疊 blocklist / 共用 URL / 外國 TLD 三道防線
  website_host AS (
    SELECT
      firm_name,
      website_url,
      lower((regexp_match(website_url, '^https?://([^/]+)'))[1]) AS host
    FROM firm_websites
    WHERE website_url IS NOT NULL AND website_url <> ''
      AND verified IS TRUE
  ),
  shared_urls AS (             -- 同一 URL 被 >=2 家共用 = 錯配/共用落地頁
    SELECT website_url
    FROM website_host
    GROUP BY website_url
    HAVING COUNT(DISTINCT firm_name) >= 2
  ),
  clean_web AS (
    SELECT DISTINCT ON (wh.firm_name) wh.firm_name, wh.website_url
    FROM website_host wh
    WHERE wh.website_url NOT IN (SELECT website_url FROM shared_urls)
      AND wh.host IS NOT NULL
      AND wh.host !~ '\.(jp|cn|kr|hk|mo|br|ru|in|vn|th|my)$'
      AND NOT EXISTS (
        SELECT 1 FROM firm_website_blocklist b
        WHERE wh.host = b.domain OR wh.host LIKE '%.' || b.domain
      )
    ORDER BY wh.firm_name, wh.website_url
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
  LEFT JOIN clean_web fw ON (
    fw.firm_name = fl.firm_name
    OR REPLACE(fw.firm_name, ' ', '') = fl.firm_name
  )
  ORDER BY fl.lawyer_count DESC;
$$;

GRANT EXECUTE ON FUNCTION moj_firm_statistics() TO anon, authenticated;
