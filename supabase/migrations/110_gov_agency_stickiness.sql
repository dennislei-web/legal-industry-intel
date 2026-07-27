-- 110: 政府標案「機關黏著度」——同一機關的案有多少比例回到同一所手上
--   gov_firm_norm：得標廠商名歸戶（去空白、異體字歸一（啓→啟/臺→台）、截到第一個「事務所」合併分所）
--   gov_agency_stickiness：KPI + 機關規模分層回鍋率 + 常年顧問續任率（單一 jsonb 回傳）
--   gov_sticky_pairs：最黏 機關×事務所 配對榜（限機關 ≥ p_min_cases 案）
-- 口徑：僅計有機關名＋決標日的案；「第 2 案起」＝同機關按決標日排序第 2 件起；
--       回鍋＝得標所曾得過該機關較早的標（多得標者案任一重疊即算）

CREATE OR REPLACE FUNCTION gov_firm_norm(p_name text)
RETURNS text AS $$
  SELECT coalesce(
    substring(translate(replace(p_name, ' ', ''), '啓臺', '啟台') FROM '^.+?事務所'),
    translate(replace(p_name, ' ', ''), '啓臺', '啟台')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION gov_agency_stickiness()
RETURNS jsonb AS $$
WITH w AS (
  SELECT f.tender_key, array_agg(DISTINCT gov_firm_norm(f.firm_name)) AS firms
  FROM gov_tender_firms f
  WHERE f.is_winner
  GROUP BY 1
),
t AS (
  SELECT g.tender_key, g.unit_name, g.award_date, g.award_year,
         coalesce(g.total_amount, 0) AS amt, g.title, w.firms,
         row_number() OVER (PARTITION BY g.unit_name ORDER BY g.award_date, g.tender_key) AS rn,
         count(*)    OVER (PARTITION BY g.unit_name) AS agency_n,
         lag(w.firms) OVER (PARTITION BY g.unit_name ORDER BY g.award_date, g.tender_key) AS prev_firms
  FROM gov_tenders g
  JOIN w USING (tender_key)
  WHERE g.unit_name IS NOT NULL AND g.unit_name <> '' AND g.award_date IS NOT NULL
),
flags AS (
  SELECT t.*,
         EXISTS (
           SELECT 1 FROM t t2
           WHERE t2.unit_name = t.unit_name
             AND (t2.award_date, t2.tender_key) < (t.award_date, t.tender_key)
             AND t2.firms && t.firms
         ) AS rep_any
  FROM t
),
kpi AS (
  SELECT
    count(*) FILTER (WHERE rn > 1)                                    AS next_cases,
    count(*) FILTER (WHERE rn > 1 AND firms && prev_firms)            AS rep_prev,
    count(*) FILTER (WHERE rn > 1 AND rep_any)                        AS rep_any_n,
    count(*) FILTER (WHERE rn > 1
                     AND award_year >= extract(year FROM now())::int - 5) AS next_5y,
    count(*) FILTER (WHERE rn > 1 AND rep_any
                     AND award_year >= extract(year FROM now())::int - 5) AS rep_any_5y,
    sum(amt) FILTER (WHERE rn > 1)                                    AS amt_next,
    sum(amt) FILTER (WHERE rn > 1 AND rep_any)                        AS amt_rep
  FROM flags
),
agency_conc AS (
  SELECT s.unit_name, s.agency_n, max(s.fw) AS top_n
  FROM (
    SELECT f2.unit_name, f2.agency_n,
           count(*) OVER (PARTITION BY f2.unit_name, fk.k) AS fw
    FROM flags f2, unnest(f2.firms) AS fk(k)
  ) s
  WHERE s.agency_n >= 2
  GROUP BY 1, 2
),
conc AS (
  SELECT count(*)                                        AS agencies_multi,
         count(*) FILTER (WHERE top_n = agency_n)        AS mono,
         count(*) FILTER (WHERE top_n * 2 >= agency_n)   AS half
  FROM agency_conc
),
tiers AS (
  SELECT CASE WHEN agency_n BETWEEN 2 AND 4 THEN '2-4'
              WHEN agency_n BETWEEN 5 AND 9 THEN '5-9'
              ELSE '10+' END AS tier,
         count(*) FILTER (WHERE rn > 1)               AS next_cases,
         count(*) FILTER (WHERE rn > 1 AND rep_any)   AS rep_n
  FROM flags
  WHERE agency_n >= 2
  GROUP BY 1
),
advisor AS (
  SELECT count(*)                                  AS pairs,
         count(*) FILTER (WHERE firms && pf)       AS kept
  FROM (
    SELECT firms,
           lag(firms) OVER (PARTITION BY unit_name ORDER BY award_date, tender_key) AS pf
    FROM flags
    WHERE title ~ '常年|法律顧問'
  ) a
  WHERE pf IS NOT NULL
)
SELECT jsonb_build_object(
  'next_cases',   kpi.next_cases,
  'rep_prev',     kpi.rep_prev,
  'rep_any',      kpi.rep_any_n,
  'next_5y',      kpi.next_5y,
  'rep_any_5y',   kpi.rep_any_5y,
  'amt_next',     kpi.amt_next,
  'amt_rep',      kpi.amt_rep,
  'agencies_multi', conc.agencies_multi,
  'mono',         conc.mono,
  'half',         conc.half,
  'advisor_pairs', advisor.pairs,
  'advisor_kept',  advisor.kept,
  'tiers', (SELECT jsonb_object_agg(tier, jsonb_build_object('next', next_cases, 'rep', rep_n)) FROM tiers)
)
FROM kpi, conc, advisor;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_agency_stickiness() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_agency_stickiness() TO authenticated;

CREATE OR REPLACE FUNCTION gov_sticky_pairs(p_min_cases int DEFAULT 10, p_limit int DEFAULT 15)
RETURNS TABLE (unit_name text, firm_key text, wins bigint, agency_cases bigint,
               ratio numeric, total_amount numeric, last_year int) AS $$
  WITH base AS (
    SELECT g.unit_name, gov_firm_norm(f.firm_name) AS fk, g.tender_key,
           f.award_amount, g.award_year
    FROM gov_tender_firms f
    JOIN gov_tenders g USING (tender_key)
    WHERE f.is_winner AND g.unit_name IS NOT NULL AND g.unit_name <> ''
  ),
  agency_n AS (
    SELECT unit_name, count(DISTINCT tender_key) AS n FROM base GROUP BY 1
  )
  SELECT b.unit_name, b.fk,
         count(DISTINCT b.tender_key)                                   AS wins,
         a.n                                                            AS agency_cases,
         round(count(DISTINCT b.tender_key)::numeric / a.n, 3)          AS ratio,
         sum(b.award_amount)                                            AS total_amount,
         max(b.award_year)                                              AS last_year
  FROM base b
  JOIN agency_n a USING (unit_name)
  WHERE a.n >= p_min_cases
  GROUP BY b.unit_name, b.fk, a.n
  ORDER BY ratio DESC, wins DESC
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_sticky_pairs(int, int) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_sticky_pairs(int, int) TO authenticated;
