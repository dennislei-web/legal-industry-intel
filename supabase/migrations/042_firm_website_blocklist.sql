-- ============================================================
-- 042: 官網來源清洗 — 黑名單網域 + 共用 URL 過濾
-- ============================================================
-- 問題：moj_firm_statistics() 直接 LEFT JOIN firm_websites 取 website_url，
--   但 firm_websites（爬蟲每日重灌）夾帶大量「非事務所自有官網」：
--   1. 黃頁／名錄（iyp、findcompany、pro360、518、goodinfo…）
--   2. 律師公會頁（kba、mlba、chbar、twba…）
--   3. 法律媒合／行銷平台（lawplayer、lawchain、interview、law110…）
--   4. 憑證 OID 目錄（zhupiter）、政府/學校/新聞/社群
--   5. 錯配：同一個 URL 被掛到很多家（如 https://zhelu.tw/ 共 81 家）
--   造成前端「有官網 ~1000」嚴重灌水、且官網連結不可信。
--
-- 修法（做在 SQL 端才不會被每日重爬洗掉）：
--   (A) firm_website_blocklist 表：可維護的黑名單網域（之後直接 INSERT 擴充）
--   (B) 重寫 moj_firm_statistics()：JOIN 前先把 firm_websites 過濾成 clean_web
--       - 丟掉 host 命中黑名單的
--       - 丟掉同一 website_url 被 >=2 家 firm_name 共用的（錯配/共用落地頁）
--   清洗後真實自有官網約 418 家（原 ~1000）。
-- ============================================================

-- (A) 黑名單表 -------------------------------------------------
CREATE TABLE IF NOT EXISTS firm_website_blocklist (
  domain   TEXT PRIMARY KEY,   -- 比對 host：host = domain OR host LIKE '%.'||domain
  category TEXT,               -- directory / guild / platform / cert / gov_edu / news_social
  note     TEXT
);

INSERT INTO firm_website_blocklist (domain, category, note) VALUES
  -- 黃頁／企業名錄
  ('iyp.com.tw','directory','中華黃頁'),
  ('findcompany.com.tw','directory','公司名錄'),
  ('pro360.com.tw','directory','發案媒合黃頁'),
  ('121.com.tw','directory','黃頁'),
  ('518.com.tw','directory','人力/黃頁'),
  ('findglocal.com','directory','商家名錄'),
  ('goodinfo.tw','directory','商業資訊'),
  ('findrate.tw','directory','據點查詢'),
  ('cybo.com','directory','yellowpages-zh.cybo.com 名錄'),
  ('suoyouyewu.com','directory','所有業務名錄'),
  ('aiqicha.baidu.com','directory','百度企查'),
  ('hospitals.tw','directory','據點名錄'),
  ('hkfindlawyer.com','directory','找律師名錄'),
  ('iarticlesnet.com','directory','內容農場'),
  ('uptogo.com.tw','directory','商家名錄'),
  ('bussiness.tw','directory','商家名錄'),
  ('twbi.com.tw','directory','商業名錄'),
  ('pttweb.tw','directory','PTT 鏡像'),
  ('buzzdaily.tw','directory','內容農場'),
  ('tw1site.com','directory','yp.tw1site.com 黃頁'),
  ('uhome.tw','directory','cht.uhome.tw 免費架站'),
  ('idv.tw','directory','個人網頁'),
  ('zhupiter.com','cert','憑證 OID 目錄 data./poi.zhupiter.com'),
  -- 律師公會
  ('kba.org.tw','guild','高雄律師公會'),
  ('mlba.org.tw','guild','苗栗律師公會'),
  ('chbar.org.tw','guild','彰化律師公會'),
  ('twba.org.tw','guild','全聯會 nab.twba.org.tw'),
  ('hualienbar-association.org.tw','guild','花蓮律師公會'),
  ('twtoa.org.tw','guild','公會/協會'),
  ('tnnbar.org.tw','guild','台南律師公會'),
  ('tcbar.org.tw','guild','台中律師公會'),
  ('lawlee.org.tw','guild','公會/協會'),
  -- 法律媒合／行銷平台
  ('lawplayer.com','platform','律師媒合平台'),
  ('lawchain.tw','platform','法律鏈媒合'),
  ('interview.tw','platform','諮詢媒合平台'),
  ('law110.com.tw','platform','法律行銷平台'),
  ('law580.com.tw','platform','法律行銷平台'),
  ('ezlawyer.tw','platform','找律師平台'),
  ('ilawyer.com.tw','platform','找律師平台'),
  ('lawhub.com.tw','platform','法律平台'),
  ('law.asia','platform','法律媒體'),
  ('doinglegal.com.tw','platform','法律平台'),
  -- 政府／學校／新聞／社群
  ('gov.tw','gov_edu','政府網站'),
  ('edu.tw','gov_edu','學校（法律系兼任教師頁等）'),
  ('technews.tw','news_social','科技新聞'),
  ('facebook.com','news_social','臉書')
ON CONFLICT (domain) DO NOTHING;

-- (B) 重寫 moj_firm_statistics() -----------------------------
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
  ),
  -- 官網來源清洗：抽 host、丟共用 URL、丟黑名單網域
  website_host AS (
    SELECT
      firm_name,
      website_url,
      lower((regexp_match(website_url, '^https?://([^/]+)'))[1]) AS host
    FROM firm_websites
    WHERE website_url IS NOT NULL AND website_url <> ''
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
