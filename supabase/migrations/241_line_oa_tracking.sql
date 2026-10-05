-- ============================================================
-- 事務所 LINE 官方帳號追蹤（mig 241，2026-10-06）
-- line_oa_accounts：帳號名冊（官網 LINE 連結解析／競品追蹤表匯入／搜尋發現）
-- line_oa_daily：每日好友數快照（scripts/line_oa_daily.py，line-oa-daily.yml 每日排程）
--
-- 資料來源＝page.line.me/<id> 的 __NEXT_DATA__：
--   account.profile.badgeType='certified' → 認證帳號（藍盾）
--   account.accountInfo.friendCount       → 好友數（帳號關閉「顯示好友數」時 JSON 仍有值）
-- 只有認證帳號有公開主頁；未認證帳號只回「Add LINE friend」空殼頁 → 拿不到人數（is_certified=false）。
-- friendCount 是淨好友數：日差＝新增−封鎖，真正的新增／封鎖數只有帳號擁有者後台看得到。
-- ============================================================

CREATE TABLE IF NOT EXISTS line_oa_accounts (
  search_id     text PRIMARY KEY,      -- 查詢用 ID（小寫、不含 @），抓 page.line.me/<search_id>
  basic_id      text,                  -- 主頁回報的基本 ID（@xxxx），跨來源去重用
  premium_id    text,                  -- 付費專屬 ID
  display_name  text,
  firm_name     text,                  -- 對應 moj 名冊事務所名（firm_key 口徑）；非事務所帳號為 NULL
  brand_group   text,                  -- 同集團多品牌（例：喆律）
  category      text,
  is_certified  boolean,               -- NULL＝尚未檢查
  source        text,                  -- website / tracker_sheet / web_search / manual
  source_url    text,
  excluded      boolean NOT NULL DEFAULT false,  -- 非法律帳號、重複帳號
  note          text,
  first_seen    date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Taipei')::date,
  last_checked_at timestamptz,
  last_status   text                   -- ok / no_page / error:<type>
);
CREATE INDEX IF NOT EXISTS line_oa_accounts_firm_idx ON line_oa_accounts (firm_name);

CREATE TABLE IF NOT EXISTS line_oa_daily (
  search_id    text NOT NULL REFERENCES line_oa_accounts(search_id) ON UPDATE CASCADE ON DELETE CASCADE,
  snap_date    date NOT NULL,          -- 台北日期
  friend_count integer NOT NULL,
  source       text NOT NULL DEFAULT 'scraper',  -- scraper / tracker_sheet（2026-09-29~10-05 匯入）
  fetched_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (search_id, snap_date)
);

ALTER TABLE line_oa_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE line_oa_daily ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_line_oa_accounts" ON line_oa_accounts;
CREATE POLICY "auth_read_line_oa_accounts" ON line_oa_accounts FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "auth_read_line_oa_daily" ON line_oa_daily;
CREATE POLICY "auth_read_line_oa_daily" ON line_oa_daily FOR SELECT USING (auth.uid() IS NOT NULL);

-- 事務所排名：每帳號取最新快照，與「最新日 −1／−7／−30 天當日或之前最近一筆」相減；
-- 某帳號缺比較點時該帳號不計入該欄差額（*_n 標出計入幾個帳號）。
CREATE OR REPLACE FUNCTION line_oa_firm_ranking()
RETURNS TABLE (
  firm_name text, accounts int, friends bigint, latest_date date,
  d1 bigint, d7 bigint, d30 bigint, d7_n int, d30_n int, first_date date
)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  WITH acc AS (
    SELECT a.search_id, a.firm_name FROM line_oa_accounts a
    WHERE NOT a.excluded AND a.firm_name IS NOT NULL
  ), lat AS (
    SELECT DISTINCT ON (d.search_id) d.search_id, d.snap_date, d.friend_count
    FROM line_oa_daily d JOIN acc USING (search_id)
    ORDER BY d.search_id, d.snap_date DESC
  ), cmp AS (
    SELECT l.search_id, l.snap_date, l.friend_count,
      (SELECT friend_count FROM line_oa_daily x WHERE x.search_id = l.search_id
         AND x.snap_date <= l.snap_date - 1 ORDER BY x.snap_date DESC LIMIT 1) AS c1,
      (SELECT friend_count FROM line_oa_daily x WHERE x.search_id = l.search_id
         AND x.snap_date <= l.snap_date - 7 ORDER BY x.snap_date DESC LIMIT 1) AS c7,
      (SELECT friend_count FROM line_oa_daily x WHERE x.search_id = l.search_id
         AND x.snap_date <= l.snap_date - 30 ORDER BY x.snap_date DESC LIMIT 1) AS c30,
      (SELECT min(snap_date) FROM line_oa_daily x WHERE x.search_id = l.search_id) AS f
    FROM lat l
  )
  SELECT acc.firm_name, count(*)::int, sum(c.friend_count)::bigint, max(c.snap_date),
         sum(c.friend_count - c.c1)::bigint, sum(c.friend_count - c.c7)::bigint,
         sum(c.friend_count - c.c30)::bigint,
         count(c.c7)::int, count(c.c30)::int, min(c.f)
  FROM cmp c JOIN acc USING (search_id)
  GROUP BY acc.firm_name
  ORDER BY 3 DESC;
$$;
GRANT EXECUTE ON FUNCTION line_oa_firm_ranking() TO authenticated;

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency, is_active, notes)
SELECT '事務所 LINE 官方帳號', 'https://page.line.me/',
       'LINE 官方帳號公開主頁 → 認證盾牌＋每日好友數（line_oa_accounts / line_oa_daily）',
       'firms', 'line_oa_daily', 'daily', true,
       '每日排程（line-oa-daily.yml）：先從 firm_digital_signals 官網 LINE 連結發現新帳號，再抓所有帳號主頁；未認證帳號無公開主頁、無人數；日差為淨增（新增−封鎖）'
WHERE NOT EXISTS (SELECT 1 FROM data_sources WHERE scraper_name = 'line_oa_daily');
