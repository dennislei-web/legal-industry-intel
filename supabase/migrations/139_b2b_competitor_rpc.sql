-- 139: B2B 霸凌線競品儀表 RPC
-- b2b_competitor_stats(p_keywords)：按事務所關鍵字彙總 律師數/近5年案量/人均/
-- 勞動案量與占比（口徑＝競品深度分析報告：lawyers_with_stats 近五年判決露面數；
-- 勞動案＝lawyer_cause_stats top_causes（各律師前 20 大案由）含勞動關鍵字之案件合計
-- ＝下限值）。關鍵字由前端自 wbie_watchlist（admin-only）取得後傳入——
-- RPC 本身 authenticated 可執行（數字皆可自本站公開頁推導，機密是「清單」不是數字）。

BEGIN;

CREATE OR REPLACE FUNCTION b2b_competitor_stats(p_keywords text[])
RETURNS TABLE (
  keyword text,
  lawyers int,             -- 現職律師數（MOJ 名冊）
  total_5yr bigint,        -- 近 5 年判決露面合計
  labor_5yr bigint,        -- 勞動案合計（top20 案由關鍵字口徑，下限）
  labor_pct numeric,       -- 勞動案占比 %
  top_lawyers jsonb        -- 前 8 位 [name, cases_5yr, lic_year]
) LANGUAGE sql STABLE AS $$
  WITH kw AS (SELECT unnest(p_keywords) AS k),
  members AS (
    SELECT kw.k, l.name, l.lic_year,
           COALESCE(l.official_cases_5yr, 0) AS cases_5yr
    FROM kw
    JOIN lawyers_with_stats l
      ON l.firm_name ILIKE '%' || kw.k || '%'
    WHERE l.has_moj AND l.is_active IS NOT FALSE
  ),
  labor AS (
    SELECT m.k, m.name,
           COALESCE(SUM((tc->>1)::bigint) FILTER (
             WHERE tc->>0 ~ '(工資|資遣|退休金|僱傭|職災|加班|調職|競業|勞動|勞保|就業服務)'
           ), 0) AS labor_cases
    FROM members m
    JOIN lawyer_cause_stats cs ON cs.name = m.name
    CROSS JOIN LATERAL jsonb_array_elements(cs.top_causes) AS tc
    GROUP BY m.k, m.name
  )
  SELECT m.k AS keyword,
         COUNT(DISTINCT m.name)::int AS lawyers,
         SUM(m.cases_5yr)::bigint AS total_5yr,
         COALESCE(SUM(lb.labor_cases), 0)::bigint AS labor_5yr,
         CASE WHEN SUM(m.cases_5yr) > 0
              THEN ROUND(COALESCE(SUM(lb.labor_cases), 0) * 100.0 / SUM(m.cases_5yr), 1)
              ELSE 0 END AS labor_pct,
         (SELECT jsonb_agg(jsonb_build_array(t.name, t.cases_5yr, t.lic_year) ORDER BY t.cases_5yr DESC)
          FROM (SELECT d.* FROM (
                  SELECT DISTINCT ON (mm.name) mm.name, mm.cases_5yr, mm.lic_year
                  FROM members mm WHERE mm.k = m.k
                  ORDER BY mm.name, mm.cases_5yr DESC) d
                ORDER BY d.cases_5yr DESC LIMIT 8) t) AS top_lawyers
  FROM members m
  LEFT JOIN labor lb ON lb.k = m.k AND lb.name = m.name
  GROUP BY m.k;
$$;

COMMIT;
