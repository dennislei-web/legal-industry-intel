-- ============================================================
-- 079: 除名律師偵測（名冊查無 → 推定除名）
-- ============================================================
-- 問題：律師從 MOJ 名冊除名後，API 查無資料，moj_office_refresh.py 的 miss
--   分支一律當「查無/網路抖動」跳過不動 → 舊列永遠殘留、state_desc 停在
--   「正常」，事務所人數統計、modal 律師清單、lawyers_combined 都含已除名
--   律師（實證：高琬晴 114臺檢證字第18741號，API 全格式變體回空）。
--
-- 設計（保守，不 DELETE——歷史/異動紀錄都掛在 lic_no 上）：
--   * dereg_candidate_at：第一次「確定查無」（HTTP 200 空 data / 404，
--     已排除網路抖動）的時間；先記候選，不動 state
--   * 下一輪分片（>= 3 天後）仍確定查無 → 確認除名：deregistered_at=now()、
--     state_desc 改「名冊查無（推定除名）」→ trigger moj_lawyers_log_change
--     自動記 state_change 進 moj_lawyer_changes（異動追蹤頁免改就看得到）
--   * 之後任何一輪又查得到（重新登錄）→ 自動清除兩欄、還原 API 現值（自癒）
--   * 偵測/標記邏輯在 scripts/moj_office_refresh.py（--check 查狀態、
--     --mark-dereg 人工三次確認後單筆標記）
--
-- 統計口徑：moj_firm_statistics()（事務所人數/平均案件數）與
--   moj_solo_firm_lawyers（一人所所長推定）排除 deregistered_at IS NOT NULL。
--   lawyers_combined 不動（除名者仍可查到、狀態欄自然顯示新 state_desc）。

-- (A) 欄位 ----------------------------------------------------
ALTER TABLE moj_lawyers
  ADD COLUMN IF NOT EXISTS dereg_candidate_at TIMESTAMPTZ,  -- 第一次確定查無（待下輪確認）
  ADD COLUMN IF NOT EXISTS deregistered_at    TIMESTAMPTZ;  -- 確認除名時間

-- (B) 一人所 view 排除已除名 ----------------------------------
-- （口徑同 mig 060，只加 deregistered_at 過濾；例如二人所走了一位且已除名，
--   剩下那位「正常」律師即成一人所所長）
CREATE OR REPLACE VIEW moj_solo_firm_lawyers AS
SELECT
  coalesce(substring(office_normalized FROM '^.+?(?:法律|律師)事務所'), office_normalized) AS firm_key,
  min(name) AS name,
  min(office_normalized) AS firm_name
FROM moj_lawyers
WHERE office_normalized LIKE '%事務所%'
  AND deregistered_at IS NULL
GROUP BY 1
HAVING count(*) = 1 AND min(state_desc) = '正常';

-- (C) 重寫 moj_firm_statistics() ------------------------------
-- = 065 全文照抄，僅在 normalized CTE 加 deregistered_at IS NULL
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
