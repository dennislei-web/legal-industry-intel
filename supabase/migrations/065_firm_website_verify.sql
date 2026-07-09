-- ============================================================
-- 065: 官網清洗回歸修復 + 官網驗證機制
-- ============================================================
-- 背景：042 在 moj_firm_statistics() 加過官網清洗（blocklist + 共用 URL 過濾，
--   有官網 ~1000→428）；048 換官方 avg_cases 口徑時「重寫整個函數」把清洗段
--   弄丟，退回直接 LEFT JOIN firm_websites → 雜訊官網全數回歸（cache 1073）。
--
-- 本次修法：
--   (A) firm_websites 加 verified / verified_at 欄：
--       官網成立條件 = 該網域「首頁」看得到事務所主名（verify_firm_websites.py
--       重驗既有資料；scrape_firm_websites.py 之後寫入前就先驗）
--   (B) blocklist 擴充本輪實測新雜訊網域（黃頁/新聞/公會/媒合）
--   (C) 重寫 moj_firm_statistics() = 048 官方 avg_cases 口徑
--       + 042 clean_web 清洗 + verified IS TRUE + 外國 TLD 過濾
--
-- ⚠️⚠️ 日後再重寫 moj_firm_statistics() 時，務必保留 clean_web 官網清洗段！
--     （048 弄丟過一次，本檔就是在還這筆債）
-- ============================================================

-- (A) 驗證欄位 ------------------------------------------------
ALTER TABLE firm_websites
  ADD COLUMN IF NOT EXISTS verified BOOLEAN,
  ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ;

-- (B) blocklist 擴充 ------------------------------------------
INSERT INTO firm_website_blocklist (domain, category, note) VALUES
  -- 黃頁／企業名錄／商家目錄
  ('tw66.com.tw','directory','中華黃頁 tw66'),
  ('web66.tw','directory','中華黃頁 web66'),
  ('web66.com.tw','directory','中華黃頁 web66'),
  ('jetbean.com.tw','directory','黃頁建站'),
  ('business.com.tw','directory','商業名錄'),
  ('opengovtw.com','directory','政府開放資料鏡像（地政士名錄）'),
  ('worldorgs.com','directory','商家目錄'),
  ('hotfrog.com.tw','directory','商家目錄'),
  ('iredpage.com','directory','紅頁名錄'),
  ('adabo4.com','directory','商家名錄'),
  ('comptw.com','directory','公司名錄'),
  ('coinflows.com','directory','公司名錄'),
  ('taiwanbuying.com.tw','directory','商家名錄'),
  ('sobay.com.tw','directory','商家名錄'),
  ('zaubee.com','directory','商家目錄'),
  ('nicelife.com.tw','directory','商家名錄'),
  ('workin.tw','directory','求職名錄'),
  ('goodjob.life','directory','薪資職場評價'),
  ('salary.tw','directory','薪資查詢'),
  ('pttcareers.com','directory','職場名錄'),
  ('cake.me','directory','求職平台'),
  ('magento.com.tw','directory','商店名錄'),
  ('bounbang.com','directory','商家名錄'),
  ('siteindices.com','directory','網站分析頁'),
  ('law-answer.com','platform','法律問答名錄'),
  ('lawdata.com.tw','platform','法源法律網'),
  ('coconala.com','platform','日本媒合平台'),
  ('lawyerhubhk.com','platform','香港律師名錄'),
  ('linelawyer.com','platform','法律行銷平台'),
  ('hualienlawyer.tw','platform','花蓮律師行銷站'),
  ('angle.com.tw','platform','元照出版'),
  -- 新聞／媒體／社群／內容站
  ('ltn.com.tw','news_social','自由時報'),
  ('udn.com','news_social','聯合報系（含 blog.udn.com）'),
  ('cna.com.tw','news_social','中央社'),
  ('newtalk.tw','news_social','新頭殼'),
  ('cnews.com.tw','news_social','匯流新聞網'),
  ('ithome.com.tw','news_social','iThome'),
  ('cmmedia.com.tw','news_social','信傳媒'),
  ('kknews.cc','news_social','每日頭條'),
  ('163.com','news_social','網易'),
  ('line.me','news_social','LINE Today'),
  ('apple.com','news_social','Apple Podcasts'),
  ('plurk.com','news_social','噗浪'),
  ('pttweb.cc','news_social','PTT 鏡像'),
  ('cxc.today','news_social','社群頁'),
  ('podaily.tw','news_social','內容站'),
  ('around5pm.com','news_social','內容站'),
  ('haven.tw','news_social','內容站'),
  ('cofacts.tw','news_social','謠言查證'),
  ('belle.tw','news_social','Podcast 內容站'),
  ('imary.com.tw','news_social','內容站'),
  ('wahpd.tw','news_social','社群頁'),
  ('mbalib.com','news_social','MBA 智庫'),
  ('newton.com.tw','news_social','中文百科'),
  ('lawfaq.cn','news_social','中國法律問答'),
  -- 公會／公部門／NGO（律師個人頁、講師頁）
  ('ilanbar.org.tw','guild','宜蘭律師公會'),
  ('ylba.org.tw','guild','雲林律師公會'),
  ('laf.org.tw','gov_edu','法律扶助基金會'),
  ('lre.org.tw','gov_edu','法律白話文/民間司改相關'),
  ('cahr.org.tw','gov_edu','人權協會'),
  ('mlmpf.org.tw','gov_edu','基金會'),
  ('ncafroc.org.tw','gov_edu','國藝會'),
  ('icaa.org.tw','gov_edu','會計師公會'),
  ('smecf.org.tw','gov_edu','中小企業輔導基金會'),
  ('tca.org.tw','gov_edu','台北市電腦公會'),
  ('chcland.org.tw','gov_edu','彰化地政相關公會'),
  ('jrf.org.tw','gov_edu','司改會'),
  ('dset.tw','gov_edu','研究智庫')
ON CONFLICT (domain) DO NOTHING;

-- (C) 重寫 moj_firm_statistics() ------------------------------
-- = 048 官方 avg_cases 口徑 + 042 官網清洗 + verified 過濾
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
