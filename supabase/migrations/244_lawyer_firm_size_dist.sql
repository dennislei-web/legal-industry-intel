-- 244：律師所在事務所規模分布（律師總覽頁）
-- 現職律師（正常、未除名）依所屬登錄單位的人數分組；單位口徑同 firm_headcount_as_of()（分所歸戶、
-- is_firm＝名稱含「事務所」）。非事務所單位（企業／法人／機關）與未登錄另列。

CREATE OR REPLACE FUNCTION lawyer_firm_size_dist()
RETURNS TABLE(sort int, band text, lawyers int, units int)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH h AS (SELECT * FROM firm_headcount_as_of(NULL)),
  b AS (
    SELECT CASE WHEN NOT is_firm THEN 8
                WHEN lawyer_n = 1 THEN 1 WHEN lawyer_n <= 3 THEN 2 WHEN lawyer_n <= 5 THEN 3
                WHEN lawyer_n <= 10 THEN 4 WHEN lawyer_n <= 20 THEN 5 WHEN lawyer_n <= 50 THEN 6
                ELSE 7 END AS sort, lawyer_n
    FROM h
  ),
  agg AS (SELECT sort, sum(lawyer_n)::int AS lawyers, count(*)::int AS units FROM b GROUP BY sort),
  lbl(sort, band) AS (VALUES (1,'1人（獨資）'),(2,'2-3人'),(3,'4-5人'),(4,'6-10人'),(5,'11-20人'),
                             (6,'21-50人'),(7,'50人以上'),(8,'非事務所單位'),(9,'未登錄'))
  SELECT l.sort, l.band,
         CASE WHEN l.sort = 9 THEN
           ((SELECT count(*) FROM moj_lawyers WHERE state_desc = '正常' AND deregistered_at IS NULL)
            - (SELECT coalesce(sum(lawyer_n), 0) FROM h))::int
         ELSE coalesce(a.lawyers, 0) END,
         CASE WHEN l.sort = 9 THEN NULL ELSE coalesce(a.units, 0) END
  FROM lbl l LEFT JOIN agg a USING (sort)
  ORDER BY l.sort;
$$;

GRANT EXECUTE ON FUNCTION lawyer_firm_size_dist() TO authenticated, service_role;
