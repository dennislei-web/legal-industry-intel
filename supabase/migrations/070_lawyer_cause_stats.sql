-- Phase B 彙總層：律師案由畫像 + 事務所案由排名 + 案由供給統計
-- 資料源：lawyer_month_stats.causes（migration 069，滾動 60 月）× cause_group_map
-- 口徑同 lawyer_judgment_stats：僅公開裁判書＝下限；同名律師不歸戶（前端沿用 * 旗標）

CREATE TABLE IF NOT EXISTS lawyer_cause_stats (
  name text PRIMARY KEY,
  cases_5yr int NOT NULL,      -- causes 視窗內總件數（≒ lawyer_judgment_stats.cases_5yr）
  by_group jsonb NOT NULL,     -- {種類: 件數}（cause_group_map mapping 後）
  top_causes jsonb NOT NULL    -- [["案類|案由", n], ...] 前 20，供鑽取顯示
);

ALTER TABLE lawyer_cause_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lcs" ON lawyer_cause_stats;
CREATE POLICY "auth_read_lcs" ON lawyer_cause_stats FOR SELECT USING (auth.uid() IS NOT NULL);

-- 全量重建（TRUNCATE+INSERT，比照 refresh_lawyer_judgment_stats；月更掛進 refresh_stats()）
CREATE OR REPLACE FUNCTION refresh_lawyer_cause_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout TO '900s' AS $$
DECLARE cutoff text;
BEGIN
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM')
    INTO cutoff FROM lawyer_month_stats WHERE causes IS NOT NULL;
  IF cutoff IS NULL THEN RETURN; END IF;

  CREATE TEMP TABLE _lc ON COMMIT DROP AS
    SELECT l.name, k.key AS ck, sum((k.value)::int)::int AS n
    FROM lawyer_month_stats l, jsonb_each_text(l.causes) k
    WHERE l.causes IS NOT NULL AND l.yyyymm >= cutoff
    GROUP BY 1, 2;

  TRUNCATE lawyer_cause_stats;
  INSERT INTO lawyer_cause_stats (name, cases_5yr, by_group, top_causes)
  SELECT c.name, c.total, g.by_group, t.top_causes
  FROM (SELECT name, sum(n)::int AS total FROM _lc GROUP BY 1) c
  JOIN (
    SELECT name, jsonb_object_agg(grp, gn) AS by_group FROM (
      SELECT l.name, coalesce(m.cause_group, split_part(l.ck, '|', 1)) AS grp,
             sum(l.n)::int AS gn
      FROM _lc l LEFT JOIN cause_group_map m ON m.ck = l.ck
      GROUP BY 1, 2) s
    GROUP BY name) g USING (name)
  JOIN (
    SELECT name, jsonb_agg(jsonb_build_array(ck, n) ORDER BY n DESC) AS top_causes FROM (
      SELECT name, ck, n, row_number() OVER (PARTITION BY name ORDER BY n DESC) AS rn
      FROM _lc) s
    WHERE rn <= 20
    GROUP BY name) t USING (name);
END $$;

-- 事務所 × 案由種類 排名（口徑同 firm_court_ranking：lawyers_combined 唯一同名歸屬）
CREATE OR REPLACE FUNCTION firm_cause_ranking(p_group text, p_limit int DEFAULT 30)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int) AS $$
  WITH per AS (
    SELECT name, (by_group->>p_group)::int AS c
    FROM lawyer_cause_stats
    WHERE coalesce((by_group->>p_group)::int, 0) > 0
  ), firm AS (
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
  FROM agg ORDER BY cases DESC LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION firm_cause_ranking(text, int) SET statement_timeout = '120s';

-- 案由種類 × 供給統計：執業律師數 / 總件數 / Top10 集中度（產業分析「案由×供需」用）
-- 從 by_group 展開（全量，不用 top_causes 以免漏長尾）
CREATE OR REPLACE FUNCTION cause_supply_stats(p_cat text DEFAULT NULL)
RETURNS TABLE (cause_group text, cat text, total_cases bigint, lawyers int,
               active_lawyers int, top10_share numeric) AS $$
  WITH ex AS (
    SELECT s.name, g.key AS grp, (g.value)::int AS n
    FROM lawyer_cause_stats s, jsonb_each_text(s.by_group) g
    WHERE (g.value)::int > 0
  ), catmap AS (
    SELECT cause_group AS grp, min(cat) AS cat FROM cause_group_map GROUP BY 1
  ), ranked AS (
    SELECT grp, n, row_number() OVER (PARTITION BY grp ORDER BY n DESC) AS rn
    FROM ex
  )
  SELECT e.grp, coalesce(c.cat, e.grp), sum(e.n)::bigint, count(*)::int,
         count(*) FILTER (WHERE e.n >= 12)::int,  -- 近5年≥12件≒常態承辦此類
         round((SELECT sum(r.n) FROM ranked r WHERE r.grp = e.grp AND r.rn <= 10)::numeric
               / nullif(sum(e.n), 0), 4)
  FROM ex e LEFT JOIN catmap c ON c.grp = e.grp
  WHERE p_cat IS NULL OR c.cat = p_cat
  GROUP BY e.grp, c.cat ORDER BY 3 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_supply_stats(text) SET statement_timeout = '300s';

-- 案由種類下拉清單（事務所版圖/供需 tab 用）
CREATE OR REPLACE FUNCTION cause_group_list()
RETURNS TABLE (cat text, cause_group text) AS $$
  SELECT min(cat) AS cat, cause_group FROM cause_group_map
  GROUP BY cause_group ORDER BY 1, 2;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_group_list() SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_group_list() TO anon, authenticated;

GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_stats() TO service_role;
GRANT EXECUTE ON FUNCTION firm_cause_ranking(text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_supply_stats(text) TO anon, authenticated;
