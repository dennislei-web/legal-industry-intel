-- 律師供給預測：從 moj_lawyers 現職名冊建歷史進場趨勢＋年齡結構，供前端算退休潮與淨供給投影
-- 口徑陷阱：moj_lawyers.birth_year 是**民國年**（practice_start_date 是西元 date）
--   年齡 = (今年西元 - 1911) - birth_year
-- 存活者偏差：intake_by_year 是「現職律師的進場年」，早年被離所/退休者不計 → 近 10-15 年可靠、早年低估
-- SECURITY DEFINER：讀 moj_lawyers（RLS authenticated），聚合非敏感，grant authenticated+anon

CREATE OR REPLACE FUNCTION lawyer_supply_stats()
RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH act AS (
    SELECT birth_year, practice_start_date
    FROM moj_lawyers
    WHERE deregistered_at IS NULL
  ), roc AS (SELECT (extract(year from now())::int - 1911) AS y)
  SELECT json_build_object(
    'total_active', (SELECT count(*) FROM act),
    'anchor_year_ad', extract(year from now())::int,
    'recent_intake_avg', (
      SELECT round(avg(n))::int FROM (
        SELECT count(*)::int AS n FROM act
        WHERE practice_start_date ~ '^\d{4}'
          AND left(practice_start_date, 4)::int BETWEEN extract(year from now())::int - 5 AND extract(year from now())::int - 1
        GROUP BY left(practice_start_date, 4)
      ) s
    ),
    'intake_by_year', (
      SELECT coalesce(json_agg(json_build_object('year', year, 'n', n) ORDER BY year), '[]'::json)
      FROM (
        SELECT left(practice_start_date, 4)::int AS year, count(*)::int AS n
        FROM act
        WHERE practice_start_date ~ '^\d{4}'
          AND left(practice_start_date, 4)::int BETWEEN 2005 AND extract(year from now())::int
        GROUP BY 1
      ) t
    ),
    'age_hist', (
      SELECT coalesce(json_agg(json_build_object('age', age, 'n', n) ORDER BY age), '[]'::json)
      FROM (
        SELECT ((SELECT y FROM roc) - birth_year) AS age, count(*)::int AS n
        FROM act
        WHERE birth_year BETWEEN 20 AND 100
          AND ((SELECT y FROM roc) - birth_year) BETWEEN 24 AND 90
        GROUP BY 1
      ) a
    )
  );
$$;

GRANT EXECUTE ON FUNCTION lawyer_supply_stats() TO authenticated, anon;
