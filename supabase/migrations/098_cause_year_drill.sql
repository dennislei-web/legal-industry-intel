-- 098: 案由供需下鑽 Phase 1 — 律師×案由種類×年度 物化表 + TOP 律師/事務所 RPC 支援年度切換
-- 仿地區供需模式（mig 054/057 lawyer_region_year_stats / region_top_lawyers）：
--   lawyer_cause_year_stats：物化 (律師×年×案由種類) 出庭數，資料源 lawyer_month_stats.causes
--   （mig 069，causefill 已回填 2021-05 起）× cause_group_map；規模與地區表同級（數十萬列，Micro 安全）
-- 口徑：公開裁判書＝下限、律師端計數（一案多律師重複計）、同名律師不歸戶（前端沿用 * 旗標）
-- cause_top_lawyers / firm_cause_ranking 加 p_year 參數（NULL=近5年滾動，沿用原邏輯）；
-- 簽名變更必須 DROP 舊版再建（CREATE OR REPLACE 會留下 overload，PostgREST named-arg 呼叫會歧義）

CREATE TABLE IF NOT EXISTS lawyer_cause_year_stats (
  name        text NOT NULL,
  yr          int  NOT NULL,
  cause_group text NOT NULL,
  case_count  int  NOT NULL,
  PRIMARY KEY (name, yr, cause_group)
);
CREATE INDEX IF NOT EXISTS idx_lcys_group_yr ON lawyer_cause_year_stats (cause_group, yr);

ALTER TABLE lawyer_cause_year_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lcys" ON lawyer_cause_year_stats;
CREATE POLICY "auth_read_lcys" ON lawyer_cause_year_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_lawyer_cause_year_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout TO '900s' AS $$
BEGIN
  TRUNCATE lawyer_cause_year_stats;
  INSERT INTO lawyer_cause_year_stats (name, yr, cause_group, case_count)
  SELECT s.name, s.yr, s.grp, sum(s.n)::int
  FROM (
    SELECT l.name, left(l.yyyymm, 4)::int AS yr,
           coalesce(m.cause_group, split_part(k.key, '|', 1)) AS grp,
           (k.value)::int AS n
    FROM lawyer_month_stats l
    CROSS JOIN LATERAL jsonb_each_text(l.causes) k
    LEFT JOIN cause_group_map m ON m.ck = k.key
    WHERE l.causes IS NOT NULL
  ) s
  GROUP BY 1, 2, 3;
END $$;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_year_stats() TO service_role;

-- 重建 refresh_lawyer_cause_stats：沿用 080 邏輯，末尾多呼叫年度表 refresh
-- （refresh_stats() 月更鏈自動帶到，不必動 judgment_stats.py）
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

  -- 案由種類鑽取表（同一份 _lc，多一次 rollup）
  TRUNCATE cause_group_causes;
  INSERT INTO cause_group_causes (cause_group, cat, total, distinct_causes, top_causes)
  WITH agg AS (
    SELECT coalesce(m.cause_group, split_part(l.ck, '|', 1)) AS grp,
           coalesce(m.cat, split_part(l.ck, '|', 1)) AS cat,
           coalesce(m.cause, split_part(l.ck, '|', 2)) AS cause,
           sum(l.n)::bigint AS n
    FROM _lc l LEFT JOIN cause_group_map m ON m.ck = l.ck
    GROUP BY 1, 2, 3
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY grp ORDER BY n DESC) AS rn FROM agg
  )
  SELECT grp, min(cat), sum(n)::bigint, count(*)::int,
         coalesce(jsonb_agg(jsonb_build_array(cause, n) ORDER BY n DESC)
                  FILTER (WHERE rn <= 40), '[]'::jsonb)
  FROM ranked GROUP BY grp;

  -- 年度下鑽表（mig 098；巢狀呼叫有自己的 statement_timeout）
  PERFORM refresh_lawyer_cause_year_stats();
END $$;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_stats() TO service_role;

-- cause_top_lawyers 加 p_year（NULL=近5年滾動，同 093 原邏輯；給年=該年，share=佔該律師當年出庭比例）
DROP FUNCTION IF EXISTS cause_top_lawyers(text, int);
CREATE OR REPLACE FUNCTION cause_top_lawyers(p_group text, p_limit int DEFAULT 10, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, name text, cases int, total_5yr int, share numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
  IF p_year IS NULL THEN
    RETURN QUERY
    SELECT row_number() OVER (ORDER BY (s.by_group->>p_group)::int DESC, s.name)::int,
           s.name,
           (s.by_group->>p_group)::int,
           s.cases_5yr,
           round((s.by_group->>p_group)::numeric / nullif(s.cases_5yr, 0), 4)
    FROM lawyer_cause_stats s
    WHERE coalesce((s.by_group->>p_group)::int, 0) > 0
    ORDER BY (s.by_group->>p_group)::int DESC, s.name
    LIMIT p_limit;
  ELSE
    RETURN QUERY
    WITH g AS (
      SELECT y.name AS nm, y.case_count AS c
      FROM lawyer_cause_year_stats y
      WHERE y.cause_group = p_group AND y.yr = p_year
      ORDER BY y.case_count DESC, y.name
      LIMIT p_limit
    )
    SELECT row_number() OVER (ORDER BY g.c DESC, g.nm)::int,
           g.nm, g.c, t.total,
           round(g.c::numeric / nullif(t.total, 0), 4)
    FROM g
    JOIN LATERAL (
      SELECT sum(y2.case_count)::int AS total
      FROM lawyer_cause_year_stats y2
      WHERE y2.name = g.nm AND y2.yr = p_year) t ON true
    ORDER BY g.c DESC, g.nm;
  END IF;
END $$;
ALTER FUNCTION cause_top_lawyers(text, int, int) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION cause_top_lawyers(text, int, int) TO anon, authenticated;

-- firm_cause_ranking 加 p_year（NULL=近5年滾動，同 070 原邏輯；事務所歸屬口徑不變＝現任名冊回溯）
DROP FUNCTION IF EXISTS firm_cause_ranking(text, int);
CREATE OR REPLACE FUNCTION firm_cause_ranking(p_group text, p_limit int DEFAULT 30, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int) AS $$
  WITH per AS (
    SELECT s.name, (s.by_group->>p_group)::int AS c
    FROM lawyer_cause_stats s
    WHERE p_year IS NULL AND coalesce((s.by_group->>p_group)::int, 0) > 0
    UNION ALL
    SELECT y.name, y.case_count
    FROM lawyer_cause_year_stats y
    WHERE p_year IS NOT NULL AND y.cause_group = p_group AND y.yr = p_year
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
ALTER FUNCTION firm_cause_ranking(text, int, int) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION firm_cause_ranking(text, int, int) TO anon, authenticated;

-- 年度下拉清單（案由供需 modal 用；2021 僅 5-12 月、最新年為部分年，由前端標注）
CREATE OR REPLACE FUNCTION cause_year_list()
RETURNS TABLE (yr int, cases bigint) AS $$
  SELECT yr, sum(case_count)::bigint FROM lawyer_cause_year_stats GROUP BY yr ORDER BY yr;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_year_list() SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_year_list() TO anon, authenticated;

-- 初次建置年度表
SELECT refresh_lawyer_cause_year_stats();
