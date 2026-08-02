-- 法官 tab KPI 平均案件量改走 RPC：
-- 舊版前端 select('case_count_total') 全表拉回撞 PostgREST 1000 列上限，
-- 平均其實只算到前 1000 列；本專案 aggregate 未開放，改 DB 端聚合。
-- 口徑：judges_combined（現任名冊，官方裁判書優先/Lawsnote fallback），
-- 分母 = case_count_total 非 NULL 的法官；1y/5y 含 0（近年無署名者拉低是事實）。

CREATE OR REPLACE FUNCTION judge_case_kpis()
RETURNS TABLE (
  n_with_cases BIGINT,
  avg_total NUMERIC,
  avg_1y NUMERIC,
  avg_5y NUMERIC
)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    count(*)::BIGINT,
    round(avg(case_count_total)::numeric, 0),
    round(avg(case_count_1y)::numeric, 0),
    round(avg(case_count_5y)::numeric, 0)
  FROM judges_combined
  WHERE case_count_total IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION judge_case_kpis() TO anon, authenticated;
