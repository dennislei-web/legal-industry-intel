-- 111: 事務所版圖排行加年度切換 —— firm_court_ranking 加 p_year（NULL=近5年滾動，沿用 047 原邏輯）
-- 年度口徑＝西元曆年（同 098 cause_year_drill）；年份清單限近 5 年滾動窗內（首尾為部分年，由前端標注月份）
-- 簽名變更必須 DROP 舊版再建（同 098 註記：CREATE OR REPLACE 會留下 overload，PostgREST named-arg 呼叫會歧義）

DROP FUNCTION IF EXISTS firm_court_ranking(text, text);
CREATE OR REPLACE FUNCTION firm_court_ranking(p_cat text DEFAULT NULL, p_court text DEFAULT NULL, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int) AS $$
  WITH cutoff AS (
    SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM') AS ym
    FROM lawyer_month_stats
  ), per AS (
    SELECT m.name,
           sum(CASE WHEN p_cat IS NULL THEN m.case_count
                    ELSE coalesce((m.cats->>p_cat)::int, 0) END) AS c
    FROM lawyer_month_stats m, cutoff
    WHERE (
        (p_year IS NULL AND m.yyyymm >= cutoff.ym)
        OR (p_year IS NOT NULL AND m.yyyymm >= p_year::text || '01' AND m.yyyymm <= p_year::text || '12')
      )
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
ALTER FUNCTION firm_court_ranking(text, text, int) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION firm_court_ranking(text, text, int) TO anon, authenticated;

-- 年度下拉清單：近 5 年滾動窗內的西元年（含窗內月份範圍，供前端標注部分年）
CREATE OR REPLACE FUNCTION lms_year_list()
RETURNS TABLE (yr int, cases bigint, mm_min text, mm_max text) AS $$
  WITH cutoff AS (
    SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM') AS ym
    FROM lawyer_month_stats
  )
  SELECT substring(m.yyyymm, 1, 4)::int, sum(m.case_count)::bigint,
         min(substring(m.yyyymm, 5, 2)), max(substring(m.yyyymm, 5, 2))
  FROM lawyer_month_stats m, cutoff
  WHERE m.yyyymm >= cutoff.ym
  GROUP BY 1 ORDER BY 1 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lms_year_list() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION lms_year_list() TO anon, authenticated;
