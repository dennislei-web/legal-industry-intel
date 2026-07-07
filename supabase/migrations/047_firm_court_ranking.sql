-- 事務所版圖：案類 × 法院 → 事務所排名（喆律競爭位置分析）
-- 口徑：lawyer_month_stats 近 5 年（滾動 60 月錨定資料最新月）＋
--       事務所歸屬走 lawyers_combined 唯一同名（同名多筆不歸屬，會低估大所）
-- 僅公開裁判書，下限估計；家事佔比重的所被低估更多，跨所比較限「同案類內」才公平

CREATE INDEX IF NOT EXISTS idx_lms_court ON lawyer_month_stats (court_name);

CREATE OR REPLACE FUNCTION firm_court_ranking(p_cat text DEFAULT NULL, p_court text DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int) AS $$
  WITH cutoff AS (
    SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM') AS ym
    FROM lawyer_month_stats
  ), per AS (
    SELECT m.name,
           sum(CASE WHEN p_cat IS NULL THEN m.case_count
                    ELSE coalesce((m.cats->>p_cat)::int, 0) END) AS c
    FROM lawyer_month_stats m, cutoff
    WHERE m.yyyymm >= cutoff.ym
      AND (p_court IS NULL OR m.court_name = p_court)
    GROUP BY m.name
    HAVING sum(CASE WHEN p_cat IS NULL THEN m.case_count
                    ELSE coalesce((m.cats->>p_cat)::int, 0) END) > 0
  ), firm AS (
    -- 正規化：截到第一個「事務所」為止（分所/掛名後綴合併，同 004 firm_key 邏輯），
    -- 排除「未提供」類佔位名
    SELECT name, min(coalesce(substring(firm_name from '^(.*?事務所)'), firm_name)) AS firm_name,
           count(*) AS n
    FROM lawyers_combined
    WHERE firm_name IS NOT NULL AND firm_name NOT LIKE '%未提供%'
    GROUP BY name
  ), agg AS (
    SELECT f.firm_name, sum(p.c)::bigint AS cases, count(*)::int AS lawyer_count
    FROM per p JOIN firm f USING (name)
    WHERE f.n = 1
    GROUP BY f.firm_name
  )
  SELECT row_number() OVER (ORDER BY cases DESC)::int, firm_name, cases, lawyer_count
  FROM agg ORDER BY cases DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION firm_court_ranking(text, text) SET statement_timeout = '120s';

-- 法院下拉選單：近 5 年有律師出庭的法院（按出庭量排序）
CREATE OR REPLACE FUNCTION lms_court_list()
RETURNS TABLE (court_name text, cases bigint) AS $$
  WITH cutoff AS (
    SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM') AS ym
    FROM lawyer_month_stats
  )
  SELECT m.court_name, sum(m.case_count)::bigint
  FROM lawyer_month_stats m, cutoff
  WHERE m.yyyymm >= cutoff.ym
  GROUP BY 1 ORDER BY 2 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lms_court_list() SET statement_timeout = '120s';
