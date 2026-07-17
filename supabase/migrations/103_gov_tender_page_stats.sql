-- 103: 產業分析「政府標案」獨立頁聚合 RPC（gov_tenders/gov_tender_firms，mig 063）
--   gov_tender_year_stats：年度件數/金額/單一投標數（趨勢圖＋KPI）
--   gov_tender_unit_top：機關別 TOP N（件數＋金額）
--   gov_tender_amount_buckets：單案決標金額分布（件數為主、金額為輔）
--   gov_tender_bid_dist：每案投標家數分布（競爭度）
-- 口徑：資料源為「廠商名含法律/律師」搜尋聯集（scripts/gov_tenders.py），
--       金額不公開者計件不計額；定期彙送列缺機關/決標方式欄位

CREATE OR REPLACE FUNCTION gov_tender_year_stats()
RETURNS TABLE (year int, cases bigint, total_amount numeric, single_bid bigint) AS $$
  SELECT t.award_year,
         count(*),
         sum(t.total_amount),
         count(*) FILTER (WHERE b.n = 1)
  FROM gov_tenders t
  LEFT JOIN (SELECT tender_key, count(*) AS n FROM gov_tender_firms GROUP BY 1) b USING (tender_key)
  WHERE t.award_year IS NOT NULL
  GROUP BY t.award_year
  ORDER BY t.award_year;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_tender_year_stats() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_tender_year_stats() TO authenticated;

CREATE OR REPLACE FUNCTION gov_tender_unit_top(p_limit int DEFAULT 15)
RETURNS TABLE (unit_name text, cases bigint, total_amount numeric, last_year int) AS $$
  SELECT t.unit_name, count(*), sum(t.total_amount), max(t.award_year)
  FROM gov_tenders t
  WHERE t.unit_name IS NOT NULL AND t.unit_name <> ''
  GROUP BY t.unit_name
  ORDER BY sum(t.total_amount) DESC NULLS LAST
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_tender_unit_top(int) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_tender_unit_top(int) TO authenticated;

CREATE OR REPLACE FUNCTION gov_tender_amount_buckets()
RETURNS TABLE (bucket text, sort int, cases bigint, total_amount numeric) AS $$
  SELECT b.lab, b.ord, count(*), sum(t.total_amount)
  FROM gov_tenders t
  JOIN LATERAL (SELECT CASE
      WHEN t.total_amount < 100000 THEN '10 萬以下'
      WHEN t.total_amount < 500000 THEN '10–50 萬'
      WHEN t.total_amount < 1000000 THEN '50–100 萬'
      WHEN t.total_amount < 5000000 THEN '100–500 萬'
      WHEN t.total_amount < 10000000 THEN '500–1,000 萬'
      WHEN t.total_amount < 50000000 THEN '1,000–5,000 萬'
      ELSE '5,000 萬以上' END,
    CASE
      WHEN t.total_amount < 100000 THEN 1
      WHEN t.total_amount < 500000 THEN 2
      WHEN t.total_amount < 1000000 THEN 3
      WHEN t.total_amount < 5000000 THEN 4
      WHEN t.total_amount < 10000000 THEN 5
      WHEN t.total_amount < 50000000 THEN 6
      ELSE 7 END
  ) b(lab, ord) ON true
  WHERE t.total_amount IS NOT NULL
  GROUP BY b.lab, b.ord
  ORDER BY b.ord;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_tender_amount_buckets() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_tender_amount_buckets() TO authenticated;

CREATE OR REPLACE FUNCTION gov_tender_bid_dist()
RETURNS TABLE (bidders text, sort int, cases bigint) AS $$
  SELECT CASE WHEN b.n >= 5 THEN '5 家以上' ELSE b.n || ' 家' END,
         least(b.n, 5), count(*)
  FROM (SELECT tender_key, count(*) AS n FROM gov_tender_firms GROUP BY 1) b
  JOIN gov_tenders t USING (tender_key)
  GROUP BY 1, 2
  ORDER BY 2;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_tender_bid_dist() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_tender_bid_dist() TO authenticated;
