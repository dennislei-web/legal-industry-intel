-- 終結案件微資料「訴訟標的金額級距 × 是否委任律師」交叉聚合
-- closed_case_amount_rep：closed_case_stats.py 解析民事訴訟/家事訴訟 txt 時，對每個
-- 「有新台幣標的金額」的案件，落入金額級距桶 × 該案是否任一造有律師代理，聚合成
-- (月×法院×檔型×金額桶) 的 n / repped_n。用以回答「標的金額多大，當事人才會請律師」。
-- 口徑：僅民事/家事「訴訟」且有標的金額者（非財產訴訟多無金額欄，不入表）；
--       委任＝原告或被告任一造有律師代理（含法扶）；金額為訴訟標的非成交價。

CREATE TABLE IF NOT EXISTS closed_case_amount_rep (
  yyyymm text NOT NULL,             -- 西元年月
  court_name text NOT NULL,
  file_type text NOT NULL,          -- 民事訴訟 / 家事訴訟
  amount_bucket text NOT NULL,      -- 0 / 1-10萬 / 10-50萬 / 50-100萬 / 100-500萬 / 500-1000萬 / 1000萬+
  n int NOT NULL,                   -- 該桶有標的金額的案件數
  repped_n int NOT NULL DEFAULT 0,  -- 其中任一造有律師代理件數
  PRIMARY KEY (yyyymm, court_name, file_type, amount_bucket)
);
CREATE INDEX IF NOT EXISTS idx_ccar_type_bucket ON closed_case_amount_rep (file_type, amount_bucket, yyyymm);

ALTER TABLE closed_case_amount_rep ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ccar" ON closed_case_amount_rep;
CREATE POLICY "auth_read_ccar" ON closed_case_amount_rep FOR SELECT USING (auth.uid() IS NOT NULL);

-- 已回填月份（backfill-amount 模式用）
CREATE OR REPLACE FUNCTION closed_case_amount_months()
RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(array_agg(DISTINCT yyyymm), '{}') FROM closed_case_amount_rep;
$$;

-- 委任率 vs 標的金額級距曲線（全國聚合；p_year 可選單一西元年，NULL=全部年）
-- 回傳各桶 n（案件量）/ repped_n（委任件數）/ rate（委任率），依金額級距排序
CREATE OR REPLACE FUNCTION amount_rep_curve(p_file_type text DEFAULT '民事訴訟', p_year text DEFAULT NULL)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  WITH ord AS (
    SELECT unnest AS amount_bucket, ordinality AS ord
    FROM unnest(ARRAY['0','1-10萬','10-50萬','50-100萬','100-500萬','500-1000萬','1000萬+'])
      WITH ORDINALITY
  )
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.ord), '[]'::json) FROM (
    SELECT o.ord, o.amount_bucket,
           COALESCE(sum(a.n), 0)::int AS n,
           COALESCE(sum(a.repped_n), 0)::int AS repped_n,
           CASE WHEN COALESCE(sum(a.n), 0) > 0
                THEN round(sum(a.repped_n)::numeric / sum(a.n), 4)
                ELSE NULL END AS rate
    FROM ord o
    LEFT JOIN closed_case_amount_rep a
      ON a.amount_bucket = o.amount_bucket
     AND a.file_type = p_file_type
     AND (p_year IS NULL OR left(a.yyyymm, 4) = p_year)
    GROUP BY o.ord, o.amount_bucket
  ) t;
$$;

GRANT EXECUTE ON FUNCTION closed_case_amount_months() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION amount_rep_curve(text, text) TO anon, authenticated;

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('終結案件標的金額委任交叉', 'https://opendata.judicial.gov.tw/', '司法院開放資料 - 終結案件資料月包：訴訟標的金額級距 × 是否委任律師交叉（民事/家事訴訟）', 'closed_cases', 'closed_case_stats', 'monthly')
ON CONFLICT (name) DO NOTHING;
