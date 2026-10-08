-- 245：訴訟領域律師 TOP N 的「全部」選項（律師總覽卡預設＝全部，再下拉選種類）
--   p_cat NULL → 全部案類（cases_5yr）；p_cat 指定 → 該案類所有種類加總（cause_group_map；
--   刑事與少年共用種類名，刑事加總會含少年刑事案件，與 cause_supply_stats 一致）。
-- 口徑同 cause_top_lawyers（mig 093）：公開裁判書＝下限、同名不歸戶。

CREATE OR REPLACE FUNCTION cause_top_lawyers_cat(p_cat text DEFAULT NULL, p_limit int DEFAULT 10)
RETURNS TABLE (rank int, name text, cases int, total_5yr int, share numeric) AS $$
  WITH g AS (SELECT DISTINCT cause_group FROM cause_group_map WHERE cat = p_cat),
  s AS (
    SELECT l.name, l.cases_5yr,
           CASE WHEN p_cat IS NULL THEN l.cases_5yr
                ELSE (SELECT coalesce(sum(v::int), 0) FROM jsonb_each_text(l.by_group) e(k, v)
                      WHERE e.k IN (SELECT cause_group FROM g)) END::int AS c
    FROM lawyer_cause_stats l
  )
  SELECT row_number() OVER (ORDER BY c DESC, name)::int, name, c, cases_5yr,
         round(c::numeric / nullif(cases_5yr, 0), 4)
  FROM s WHERE c > 0
  ORDER BY c DESC, name
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_top_lawyers_cat(text, int) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION cause_top_lawyers_cat(text, int) TO anon, authenticated;
