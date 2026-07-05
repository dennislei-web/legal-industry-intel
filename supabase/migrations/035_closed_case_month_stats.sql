-- 司法院開放資料「終結案件資料」月包 → 案件層級微資料聚合
-- closed_case_month_stats：closed_case_stats.py 解析民事訴訟/家事訴訟 txt 的
-- (月×法院×檔案類型) 聚合：律師委任率、終結情形分布、訴訟標的金額
-- court_name 用月包資料夾名（地院=「臺灣臺北地方法院」，與 judge_month_stats/court_case_stats 一致；
-- 簡易庭/高院等資料夾名原樣保留，查詢時自行過濾）
-- 刑事檔（階層式，被告列有「選任律師辯護」）尚未納入，見 CLAUDE.md

CREATE TABLE IF NOT EXISTS closed_case_month_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  yyyymm text NOT NULL,            -- 西元年月（民國11505 → '202605'）
  court_name text NOT NULL,
  file_type text NOT NULL,         -- 民事訴訟 / 家事訴訟
  total_cases int NOT NULL,
  plaintiff_rep int NOT NULL DEFAULT 0,  -- 原告有律師代理件數
  defendant_rep int NOT NULL DEFAULT 0,  -- 被告有律師代理件數
  both_rep int NOT NULL DEFAULT 0,       -- 兩造皆有律師件數
  outcomes jsonb,                  -- 終結情形1 分布 {"判決":n,"和解":n,"撤回":n,...}
  amount_sum numeric,              -- 訴訟標的金額合計（僅新台幣、有值案件）
  amount_n int,                    -- 有金額案件數
  UNIQUE (yyyymm, court_name, file_type)
);
CREATE INDEX IF NOT EXISTS idx_ccms_court ON closed_case_month_stats (court_name, yyyymm);

ALTER TABLE closed_case_month_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ccms" ON closed_case_month_stats;
CREATE POLICY "auth_read_ccms" ON closed_case_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('終結案件微資料統計', 'https://opendata.judicial.gov.tw/', '司法院開放資料 - 終結案件資料月包（案件層級）：律師委任率/終結情形/標的金額聚合', 'closed_cases', 'closed_case_stats', 'monthly')
ON CONFLICT (name) DO NOTHING;
