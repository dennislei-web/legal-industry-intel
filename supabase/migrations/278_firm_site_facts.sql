-- ============================================================
-- 278: 官網結構化資訊（第一階段：定位／團隊揭露／進線管道）
-- ============================================================
-- 來源：scripts/extract_site_facts.py，對 firm_websites 驗證通過且連得上的法律事務所官網，
--   抓首頁＋最多 10 個相關子頁（團隊／服務／收費／聯絡／文章類）。
-- 兩張表：
--   firm_site_snapshots  清洗後的頁面文字快照（之後要用語言模型重抽、或比對前後期變化都靠它）
--   firm_site_facts      規則抽出的結構化欄位（不經語言模型，可重現）
-- 權限：競爭情報，只開管理員讀；快照表不開放前端。
-- ============================================================

CREATE TABLE IF NOT EXISTS firm_site_snapshots (
  firm_name    TEXT PRIMARY KEY,
  website_url  TEXT NOT NULL,
  fetched_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  page_count   INTEGER,
  text_chars   INTEGER,
  pages        JSONB          -- [{url, title, text}]，每頁文字上限 6000 字
);
ALTER TABLE firm_site_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON firm_site_snapshots FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS firm_site_facts (
  firm_name        TEXT PRIMARY KEY,
  website_url      TEXT NOT NULL,
  extracted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  page_count       INTEGER,
  text_chars       INTEGER,

  -- 定位
  focus_areas      TEXT[],        -- 主打領域：出現在標題／選單／小標的領域，依權重排序
  focus_basis      TEXT,          -- 標題選單 / 內文（站上沒有選單小標結構時退而取內文前 4 個）
  mentioned_areas  TEXT[],        -- 內文有提到的領域（含主打）
  area_scores      JSONB,         -- {領域: 分數}
  client_type      TEXT,          -- 企業 / 個人 / 綜合 / 不明（由主打領域組成推定）
  tagline          TEXT,          -- 首頁 meta description 或標題（自述定位）

  -- 團隊揭露
  roster_total     INTEGER,       -- 名冊上該所律師數
  roster_listed    INTEGER,       -- 其中官網找得到姓名的
  listed_names     TEXT[],
  unlisted_names   TEXT[],        -- 名冊有、官網沒列
  extra_names      TEXT[],        -- 官網寫「某某律師」但名冊不在本所（合署／顧問／已離開未撤；規則抓的，有雜訊）
  has_bio          BOOLEAN,       -- 有學經歷
  ex_judicial      BOOLEAN,       -- 提到前法官／檢察官背景
  ex_judicial_snippet TEXT,

  -- 進線管道
  has_line         BOOLEAN,
  line_url         TEXT,
  has_form         BOOLEAN,       -- 有聯絡／諮詢表單
  has_booking      BOOLEAN,       -- 有「線上預約」類入口
  phones           TEXT[],
  fb_url           TEXT,
  ig_url           TEXT,
  yt_url           TEXT,
  free_consult     BOOLEAN,
  fee_disclosed    BOOLEAN,       -- 寫出具體收費金額
  fee_snippet      TEXT,

  -- 網站本身
  platform         TEXT,
  copyright_year   INTEGER,
  latest_content_date DATE,       -- 頁面上出現的最新日期（判斷是否停更）
  langs            TEXT[],        -- 除中文外的語言版本
  has_branches     BOOLEAN
);

ALTER TABLE firm_site_facts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS firm_site_facts_admin_read ON firm_site_facts;
CREATE POLICY firm_site_facts_admin_read ON firm_site_facts
  FOR SELECT TO authenticated USING (public.is_intel_admin());
REVOKE ALL ON firm_site_facts FROM anon;
GRANT SELECT ON firm_site_facts TO authenticated;
