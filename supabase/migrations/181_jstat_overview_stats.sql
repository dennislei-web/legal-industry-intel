-- 司法統計「總覽」動態化（IA 重整 P2-2）：court_case_stats → 年×分類新收/終結聚合
-- 取代前端靜態 public/data/judicial_stats.json 的 overview 三圖（並列比對核可後才移除靜態圖）
--
-- 分類口徑（開放資料 43994 原生案類，與統計月報大分類「不同」，差異務必看 footnote）：
--   民事     = case_category='民事' AND proc_l1<>'民執'（含民事訴訟/非訟/督促/保全/調解、各級法院）
--   強制執行 = case_category='民事' AND proc_l1='民執'（含執行/併案/保全等；月報「強制執行」僅其中 proc_l2='執行'）
--   刑事/家事/少年/行政訴訟 = 同名 case_category 各級合計
--   其他     = 懲戒法院各庭（量極小）
-- 已知怪癖：最高法院新收恆 0（來源只填終結）→ 民事/刑事新收比月報少了三審新收；
--   月報另含公證/提存/憲法法庭/公設辯護/調查保護等非裁判業務，本 RPC 無（total 口徑=純案件審理量）；
--   最高法院早年列帶 legacy 標籤「刑事(102年以前含少年)」「民事(100年以前含家事)」（新收 0、終結有值），
--   用前綴匹配歸回 刑事/民事（少年/家事三審量極小，可忽略）
-- months = 該年該分類有資料的月份數（<12 表示年度未完，前端據此排除 KPI/年增率）

CREATE OR REPLACE FUNCTION jstat_overview_stats()
RETURNS TABLE(year_tw int, segment text, new_cases bigint, closed_cases bigint, months int) AS $$
  SELECT year_tw,
    CASE
      WHEN case_category LIKE '民事%' AND proc_l1='民執' THEN '強制執行'
      WHEN case_category LIKE '民事%' THEN '民事'
      WHEN case_category LIKE '刑事%' THEN '刑事'
      WHEN case_category IN ('家事','少年','行政訴訟') THEN case_category
      ELSE '其他' END AS seg,
    sum(new_cases)::bigint,
    sum(closed_cases)::bigint,
    count(DISTINCT month)::int
  FROM court_case_stats
  GROUP BY 1, 2
  ORDER BY 1, 2;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION jstat_overview_stats() SET statement_timeout = '30s';
