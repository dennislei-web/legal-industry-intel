-- 檢察署基本資料（比照 014 courts 的種子模式）＋ 現職檢察官估計 RPC
-- 官方對照（法務統計資訊網，114 年底）：全國檢察官 1,460 人
--（最高檢 13、高檢及分署 161、地檢 1,286）；per-office 官方數無公開明細，
-- 現職數以「最新資料月具名檢察官」估計（實測 202504 = 1,471，與官方誤差 <1%）

CREATE TABLE IF NOT EXISTS prosecutor_offices (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  name text UNIQUE NOT NULL,
  office_type text NOT NULL,   -- 地方檢察署 / 高等檢察署 / 高檢分署 / 最高檢察署
  region text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE prosecutor_offices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_pof" ON prosecutor_offices;
CREATE POLICY "auth_read_pof" ON prosecutor_offices FOR SELECT USING (auth.uid() IS NOT NULL);

INSERT INTO prosecutor_offices (name, office_type, region) VALUES
  ('最高檢察署', '最高檢察署', '台北'),
  ('臺灣高等檢察署', '高等檢察署', '台北'),
  ('臺灣高等檢察署智慧財產檢察分署', '高檢分署', '台北'),
  ('臺灣高等檢察署臺中檢察分署', '高檢分署', '台中'),
  ('臺灣高等檢察署臺南檢察分署', '高檢分署', '台南'),
  ('臺灣高等檢察署高雄檢察分署', '高檢分署', '高雄'),
  ('臺灣高等檢察署花蓮檢察分署', '高檢分署', '花蓮'),
  ('福建高等檢察署金門檢察分署', '高檢分署', '金門'),
  ('臺灣臺北地方檢察署', '地方檢察署', '台北'),
  ('臺灣士林地方檢察署', '地方檢察署', '台北'),
  ('臺灣新北地方檢察署', '地方檢察署', '新北'),
  ('臺灣基隆地方檢察署', '地方檢察署', '基隆'),
  ('臺灣宜蘭地方檢察署', '地方檢察署', '宜蘭'),
  ('臺灣桃園地方檢察署', '地方檢察署', '桃園'),
  ('臺灣新竹地方檢察署', '地方檢察署', '新竹'),
  ('臺灣苗栗地方檢察署', '地方檢察署', '苗栗'),
  ('臺灣臺中地方檢察署', '地方檢察署', '台中'),
  ('臺灣南投地方檢察署', '地方檢察署', '南投'),
  ('臺灣彰化地方檢察署', '地方檢察署', '彰化'),
  ('臺灣雲林地方檢察署', '地方檢察署', '雲林'),
  ('臺灣嘉義地方檢察署', '地方檢察署', '嘉義'),
  ('臺灣臺南地方檢察署', '地方檢察署', '台南'),
  ('臺灣橋頭地方檢察署', '地方檢察署', '高雄'),
  ('臺灣高雄地方檢察署', '地方檢察署', '高雄'),
  ('臺灣屏東地方檢察署', '地方檢察署', '屏東'),
  ('臺灣臺東地方檢察署', '地方檢察署', '台東'),
  ('臺灣花蓮地方檢察署', '地方檢察署', '花蓮'),
  ('臺灣澎湖地方檢察署', '地方檢察署', '澎湖'),
  ('福建金門地方檢察署', '地方檢察署', '金門'),
  ('福建連江地方檢察署', '地方檢察署', '連江')
ON CONFLICT (name) DO NOTHING;

-- 各檢察署現職估計：最新資料月具名數 / 近 12 個資料月具名數 / 累計案件數
-- 同一人同月可能出現在多署（上訴審的地檢檢察官會被記到高檢），
-- 「主要歸屬」= 該人該期間案件量最多的署，去重後各署加總 = 全國不重複人數
CREATE OR REPLACE FUNCTION prosecutor_active_by_office()
RETURNS TABLE (office_name text, active_latest bigint, active_12m bigint, cases_total bigint) AS $$
  WITH latest AS (SELECT max(yyyymm) AS m FROM prosecutor_month_stats),
  recent AS (
    SELECT DISTINCT yyyymm FROM prosecutor_month_stats ORDER BY yyyymm DESC LIMIT 12
  ),
  primary_latest AS (
    SELECT office_name, count(*) AS n FROM (
      SELECT name, office_name,
             row_number() OVER (PARTITION BY name ORDER BY case_count DESC, office_name) AS rn
      FROM prosecutor_month_stats WHERE yyyymm = (SELECT m FROM latest)
    ) t WHERE rn = 1 GROUP BY 1
  ),
  primary_12m AS (
    SELECT office_name, count(*) AS n FROM (
      SELECT name, office_name,
             row_number() OVER (PARTITION BY name ORDER BY sum_cases DESC, office_name) AS rn
      FROM (
        SELECT name, office_name, sum(case_count) AS sum_cases
        FROM prosecutor_month_stats
        WHERE yyyymm IN (SELECT yyyymm FROM recent)
        GROUP BY 1, 2
      ) a
    ) t WHERE rn = 1 GROUP BY 1
  ),
  totals AS (
    SELECT office_name, sum(case_count)::bigint AS cases_total
    FROM prosecutor_month_stats GROUP BY 1
  )
  SELECT t.office_name,
         coalesce(pl.n, 0)::bigint,
         coalesce(p12.n, 0)::bigint,
         t.cases_total
  FROM totals t
  LEFT JOIN primary_latest pl USING (office_name)
  LEFT JOIN primary_12m p12 USING (office_name);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 全國現職估計摘要（前端 KPI 用）
CREATE OR REPLACE FUNCTION prosecutor_active_summary()
RETURNS TABLE (latest_ym text, active_latest bigint, active_12m bigint, names_total bigint) AS $$
  WITH latest AS (SELECT max(yyyymm) AS m FROM prosecutor_month_stats),
  recent AS (
    SELECT DISTINCT yyyymm FROM prosecutor_month_stats ORDER BY yyyymm DESC LIMIT 12
  )
  SELECT (SELECT m FROM latest),
         count(DISTINCT name) FILTER (WHERE yyyymm = (SELECT m FROM latest)),
         count(DISTINCT name) FILTER (WHERE yyyymm IN (SELECT yyyymm FROM recent)),
         count(DISTINCT name)
  FROM prosecutor_month_stats;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION prosecutor_active_by_office() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION prosecutor_active_summary() TO anon, authenticated;

-- 資料來源登記
INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('法務統計-檢察官人數', 'https://www.rjsd.moj.gov.tw/RJSDWeb/common/WebList3_Report.aspx?list_id=746', '法務統計資訊網 - 各級檢察機關檢察官人數（官方對照：114 年底 1,460 人）', 'prosecutors', 'manual', 'yearly')
ON CONFLICT (name) DO NOTHING;
