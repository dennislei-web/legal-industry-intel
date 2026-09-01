-- 182: 領域律師版圖（IA 重整 P3-3 方案 B）— 律師×法院×案由種類 物化表
-- 把 famLawyersBlock（家事限定，mig 049/055 cache）泛化成任選種類的「法院常勝軍＋律師名單」：
--   全國名單/年度 = 現成 cause_top_lawyers / lawyer_cause_year_stats（mig 093/098）
--   法院維度 = 本表（lawyer_month_stats 有 court_name＋causes 同列，缺的只是這張 rollup）
-- 規模實測（2026-09-01，近 60 月）：476,324 列 / 14,851 律師 / 79 種類 —— 前端一律
--   server-side 篩選（eq cause_group + eq court_name，走 PK 前綴），嚴禁拉全量（049 的教訓）
-- 口徑：公開裁判書＝下限、種類層（cause_group）粒度、同名律師不歸戶（firm_name 僅
--   MOJ 名冊姓名唯一者填入，同名多人 firm_ambiguous=true）；causes 回填起點 2021-05
-- 家事 cache（family_lawyer_* 4 表）本次僅前端下線，DB 保留一輪觀察後另開 migration 清理

CREATE TABLE IF NOT EXISTS lawyer_cause_court_stats (
  name           text NOT NULL,
  court_name     text NOT NULL,
  cause_group    text NOT NULL,
  case_count     int  NOT NULL,
  firm_name      text,
  firm_ambiguous boolean NOT NULL DEFAULT false,
  PRIMARY KEY (cause_group, court_name, name)
);
CREATE INDEX IF NOT EXISTS idx_lccs_rank ON lawyer_cause_court_stats (cause_group, court_name, case_count DESC);

ALTER TABLE lawyer_cause_court_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lccs" ON lawyer_cause_court_stats;
CREATE POLICY "auth_read_lccs" ON lawyer_cause_court_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_lawyer_cause_court_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout TO '900s' AS $$
DECLARE cutoff text;
BEGIN
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM')
    INTO cutoff FROM lawyer_month_stats WHERE causes IS NOT NULL;
  IF cutoff IS NULL THEN RETURN; END IF;

  TRUNCATE lawyer_cause_court_stats;
  INSERT INTO lawyer_cause_court_stats (name, court_name, cause_group, case_count, firm_name, firm_ambiguous)
  WITH agg AS (
    SELECT l.name, l.court_name,
           coalesce(m.cause_group, split_part(k.key, '|', 1)) AS grp,
           sum((k.value)::int)::int AS n
    FROM lawyer_month_stats l
    CROSS JOIN LATERAL jsonb_each_text(l.causes) k
    LEFT JOIN cause_group_map m ON m.ck = k.key
    WHERE l.causes IS NOT NULL AND l.yyyymm >= cutoff
    GROUP BY 1, 2, 3
  ), firm AS (
    SELECT name, min(firm_name) AS firm_name, count(*) AS n
    FROM lawyers_combined
    WHERE firm_name IS NOT NULL
    GROUP BY name
  )
  SELECT a.name, a.court_name, a.grp, a.n,
         CASE WHEN f.n = 1 THEN f.firm_name END,
         coalesce(f.n, 0) > 1
  FROM agg a LEFT JOIN firm f USING (name);
END $$;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_court_stats() TO service_role;

-- 法院下拉：該種類有出庭紀錄的法院（按總量排序；直查物化表，毫秒級）
CREATE OR REPLACE FUNCTION cause_court_list(p_group text)
RETURNS TABLE (court_name text, total bigint, lawyers int) AS $$
  SELECT court_name, sum(case_count)::bigint, count(*)::int
  FROM lawyer_cause_court_stats
  WHERE cause_group = p_group
  GROUP BY 1 ORDER BY 2 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_court_list(text) SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_court_list(text) TO anon, authenticated;

-- 法院常勝軍：種類×法院 TOP N（SECURITY DEFINER 單發、不分頁；前端也可直查表，此 RPC 供未登入預覽一致性）
CREATE OR REPLACE FUNCTION cause_court_top_lawyers(p_group text, p_court text, p_limit int DEFAULT 100)
RETURNS TABLE (rank int, name text, firm_name text, firm_ambiguous boolean, cases int) AS $$
  SELECT row_number() OVER (ORDER BY case_count DESC, name)::int,
         name, firm_name, firm_ambiguous, case_count
  FROM lawyer_cause_court_stats
  WHERE cause_group = p_group AND court_name = p_court
  ORDER BY case_count DESC, name
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_court_top_lawyers(text, text, int) SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_court_top_lawyers(text, text, int) TO anon, authenticated;

-- 掛進月更鏈：重建 refresh_lawyer_cause_stats（沿用 098 全文，尾端多一個 PERFORM）
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
  -- 法院層物化表（mig 182）
  PERFORM refresh_lawyer_cause_court_stats();
END $$;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_stats() TO service_role;
