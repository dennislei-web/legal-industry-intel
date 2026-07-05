-- 司法院開放資料「各級法院各案類新收及終結件數統計」（datasetId 43994）
-- court_case_stats：judicial_official_stats.py 每月全量 upsert 的
-- (年×月×法院×案件種類×訴訟程序別第1層) 官方聚合，民國 90 年起
-- 用途：司法統計儀表板月更資料源；後續可與 judge_month_stats 做法院層級對照
-- 注意：最高法院在來源資料中只有終結數（新收欄恆為 0）；「民事」含民執程序

CREATE TABLE IF NOT EXISTS court_case_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  year_tw int NOT NULL,          -- 民國年
  month int NOT NULL,            -- 1-12
  court_level text NOT NULL,     -- 地方法院/高等法院/最高法院/...（已去編號前綴）
  court_name text NOT NULL,      -- 臺灣臺北地方法院/臺灣高等法院/...（已去編號前綴）
  case_category text NOT NULL,   -- 民事/刑事/家事/少年/行政訴訟/...（保留歷史標籤如「民事(100年以前含家事)」）
  proc_l1 text NOT NULL DEFAULT '', -- 訴訟程序別第 1 層（訴訟/其他/民執/保護令聲請/...），第 2、3 層已聚合
  new_cases int NOT NULL DEFAULT 0,
  closed_cases int NOT NULL DEFAULT 0,
  UNIQUE (year_tw, month, court_name, case_category, proc_l1)
);
CREATE INDEX IF NOT EXISTS idx_ccs_court ON court_case_stats (court_name, year_tw);
CREATE INDEX IF NOT EXISTS idx_ccs_level_cat ON court_case_stats (court_level, case_category, year_tw);

ALTER TABLE court_case_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ccs" ON court_case_stats;
CREATE POLICY "auth_read_ccs" ON court_case_stats FOR SELECT USING (auth.uid() IS NOT NULL);

-- 資料來源登記
INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('司法院官方案件統計', 'https://opendata.judicial.gov.tw/', '司法院開放資料 - 各級法院各案類新收及終結件數統計（民國 90 年起，月×法院×案類×程序別）', 'court_stats', 'judicial_official_stats', 'monthly')
ON CONFLICT (name) DO NOTHING;
