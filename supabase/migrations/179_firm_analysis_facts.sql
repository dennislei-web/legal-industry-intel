-- ============================================================
-- 179: firm_analysis_facts — AI 事務所分析結構化資料集
-- ============================================================
-- 來源：398 家 firm_profiles.ai_analysis 文字＋leaders json＋DB 訊號，
-- 由 scripts/_batch408/v2/facts_extract.py 抽取、upload_facts.py 重灌。
-- 供「事務所總覽＞產業結構分析」區塊前端聚合（列數小，client 端聚合）。
-- 營收為模型推估區間（萬元）；concentration/succession 為文字啟發式抽取，
-- 前端只呈現聚合比例不逐所標籤。

CREATE TABLE IF NOT EXISTS firm_analysis_facts (
  firm TEXT PRIMARY KEY,
  lawyer_count INT,
  region TEXT,
  avg_cases INT,
  type TEXT,                -- 六型態
  founded_year INT,
  roster_n INT,             -- 分析文載在籍
  court_n INT,              -- 有出庭
  cases_5y INT,
  rev_low_wan INT,          -- 營收推估下緣（萬/年）
  rev_high_wan INT,
  concentration TEXT,       -- 掛名制度/真集中/分散非掛名/不明（啟發式）
  succession_risk INT,      -- 速讀最大風險點名接班/斷層/高齡/熄燈
  ex_judicial_n INT,
  practice_focus TEXT,
  g_rating NUMERIC,
  g_reviews INT,
  social TEXT,
  fb_pixel INT,
  google_ads INT,
  gov_tender_amt BIGINT,
  indep_seats INT,
  awards_n INT,
  tagline TEXT,
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE firm_analysis_facts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_firm_analysis_facts" ON firm_analysis_facts;
CREATE POLICY "auth_read_firm_analysis_facts" ON firm_analysis_facts
  FOR SELECT USING (auth.uid() IS NOT NULL);
