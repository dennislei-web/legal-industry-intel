-- 修 market_year_trend() 行政訴訟恆為 0 的問題
-- 根因：來源 datasetId 43994 重傳後，高等行政法院的 proc_l1 從「訴訟」改為
--   「地方行政訴訟庭／高等行政訴訟庭」兩庭、「訴訟/其他」下移到 proc_l2，
--   052 的條件 proc_l1='訴訟' 全數 miss → 前端行政訴訟 KPI/趨勢線恆 0。
-- 新口徑（一審、跨 112-08 行政訴訟新制連續）：
--   高等行政法院（兩庭）proc_l2='訴訟' ＋ 101–112 年地院行政訴訟庭 proc_l1='訴訟'
--   校準：114 年 = 9,980（地方庭）+ 4,802（高等庭）= 14,782，與 052 當初基準一致
CREATE OR REPLACE FUNCTION market_year_trend()
RETURNS TABLE(year_ad int, segment text, new_cases bigint) AS $$
  SELECT (year_tw + 1911) AS year_ad, seg, sum(nc)::bigint
  FROM (
    SELECT year_tw, new_cases AS nc,
      CASE
        WHEN case_category='民事' AND court_level='地方法院' AND proc_l1='民事' AND proc_l2='民事訴訟' THEN '民事訴訟'
        WHEN case_category='民事' AND court_level='地方法院' AND proc_l1='民事' AND proc_l2='民事非訟' THEN '民事非訟'
        WHEN case_category='民事' AND court_level='地方法院' AND proc_l1='民執' AND proc_l2='執行'   THEN '民事執行'
        WHEN case_category='刑事' AND court_level='地方法院' AND proc_l1='訴訟' AND proc_l2='第一審' THEN '刑事訴訟'
        WHEN case_category='家事' AND court_level='地方法院'                                        THEN '家事'
        WHEN case_category='少年' AND court_level='地方法院'                                        THEN '少年'
        WHEN case_category='行政訴訟' AND ((court_level='高等行政法院' AND proc_l2='訴訟')
                                        OR (court_level='地方法院' AND proc_l1='訴訟'))            THEN '行政訴訟'
        ELSE NULL END AS seg
    FROM court_case_stats
  ) x
  WHERE seg IS NOT NULL AND nc > 0
  GROUP BY 1, 2
  ORDER BY 1, 2;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION market_year_trend() SET statement_timeout = '30s';
