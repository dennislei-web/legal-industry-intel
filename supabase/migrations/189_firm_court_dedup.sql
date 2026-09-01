-- ============================================================
-- 189: 事務所版圖去重 — 法院×案類維度的共同署名素材＋排行 RPC 去重欄
-- ============================================================
-- mig 186 的 lawyer_group_month_stats 只有 ym×律師集合，沒法院/案類維度，
-- 事務所版圖（案類×法院競爭位置）無法逐條件去重。本檔補齊：
--
-- lawyer_group_court_month_stats：ym × court × cat × 同判決律師集合（>=2 人）。
--   一份判決只屬一個法院＋一個案類，按維度拆列不會拆散判決；聚合掉 court/cat
--   即等於舊表（parse() 同趟產兩種列，兩表永遠一致）。groupfill 回填、月更增量。
--
-- firm_court_dup_month_stats：ym × firm × court × cat 的重複數 cache（只存有
--   共列的組合，列數小）。⚠️ 歸戶口徑刻意用 047 firm_court_ranking 的 firm CTE
--   （lawyers_combined、截到第一個「事務所」、同名唯一）而非 mig 186 的 moj fk——
--   排行 RPC 的名目與去重必須同一套歸戶才能相減。
--
-- firm_court_ranking v3：加 dup_cases/dedup_cases 欄、rank 改按 dedup 排序。
--   cache 空時 dup=0、dedup=cases＝現行為（前端可先上，有 dup 資料才切去重呈現）。
--   案由種類（group）層維持名目（素材無 cause 維度，同 firm_cause_shares 決策）。

CREATE TABLE IF NOT EXISTS lawyer_group_court_month_stats (
  ym         text   NOT NULL,
  court_name text   NOT NULL,
  cat        text   NOT NULL,
  lawyers    text[] NOT NULL,   -- sorted、同案去重後的律師名集合（>=2 人）
  cases      int    NOT NULL DEFAULT 0,
  PRIMARY KEY (ym, court_name, cat, lawyers)
);

CREATE TABLE IF NOT EXISTS firm_court_dup_month_stats (
  ym         text NOT NULL,
  firm_name  text NOT NULL,   -- 047 排行口徑歸戶名（非 mig 186 firm_key）
  court_name text NOT NULL,
  cat        text NOT NULL,
  dup_cases  int  NOT NULL DEFAULT 0,   -- 同判決同所 k 人 → k-1 重複合計
  PRIMARY KEY (ym, firm_name, court_name, cat)
);
CREATE INDEX IF NOT EXISTS idx_fcdms_firm ON firm_court_dup_month_stats (firm_name);

ALTER TABLE lawyer_group_court_month_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_court_dup_month_stats     ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lgcms" ON lawyer_group_court_month_stats;
DROP POLICY IF EXISTS "auth_read_fcdms" ON firm_court_dup_month_stats;
CREATE POLICY "auth_read_lgcms" ON lawyer_group_court_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read_fcdms" ON firm_court_dup_month_stats     FOR SELECT USING (auth.uid() IS NOT NULL);

-- p_ym NULL＝全量重建（只能 supabase db query 跑，PostgREST 8s timeout 同 186 註記）；
-- 指定 p_ym＝單月增量（groupfill CI 與月更 refresh_stats() 逐月打）。
DROP FUNCTION IF EXISTS refresh_firm_court_dup(text);
CREATE OR REPLACE FUNCTION refresh_firm_court_dup(p_ym text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_ym IS NULL THEN
    TRUNCATE firm_court_dup_month_stats;
  ELSE
    DELETE FROM firm_court_dup_month_stats WHERE ym = p_ym;
  END IF;
  INSERT INTO firm_court_dup_month_stats (ym, firm_name, court_name, cat, dup_cases)
  WITH firm AS (  -- 歸戶口徑＝047 firm_court_ranking 的 firm CTE，一字不差
    SELECT name, min(coalesce(substring(firm_name from '^(.*?事務所)'), firm_name)) AS firm_name,
           count(*) AS n
    FROM lawyers_combined
    WHERE firm_name IS NOT NULL AND firm_name NOT LIKE '%未提供%'
    GROUP BY name
  ),
  t AS (
    SELECT g.ym, g.court_name, g.cat, g.lawyers, g.cases, f.firm_name, count(*) AS k
    FROM lawyer_group_court_month_stats g
    CROSS JOIN LATERAL unnest(g.lawyers) AS ln(name)
    JOIN firm f ON f.name = ln.name AND f.n = 1
    WHERE g.ym >= COALESCE(p_ym, '000000') AND g.ym <= COALESCE(p_ym, '999999')
    GROUP BY g.ym, g.court_name, g.cat, g.lawyers, g.cases, f.firm_name
    HAVING count(*) >= 2
  )
  SELECT ym, firm_name, court_name, cat, sum((k - 1) * cases)::int
  FROM t GROUP BY 1, 2, 3, 4;
END;
$$;
ALTER FUNCTION refresh_firm_court_dup(text) SET statement_timeout = '600s';
REVOKE EXECUTE ON FUNCTION refresh_firm_court_dup(text) FROM anon, public;
GRANT EXECUTE ON FUNCTION refresh_firm_court_dup(text) TO service_role;

-- 排行 RPC v3：nominal 邏輯照舊（111 版），LEFT JOIN dup cache、rank 按 dedup。
-- 簽名同 111（同參數），DROP 再建防 overload 歧義。
DROP FUNCTION IF EXISTS firm_court_ranking(text, text, int);
CREATE OR REPLACE FUNCTION firm_court_ranking(p_cat text DEFAULT NULL, p_court text DEFAULT NULL, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int, dup_cases bigint, dedup_cases bigint) AS $$
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
  ), dup AS (
    SELECT d.firm_name, sum(d.dup_cases)::bigint AS dup_cases
    FROM firm_court_dup_month_stats d, cutoff
    WHERE (
        (p_year IS NULL AND d.ym >= cutoff.ym)
        OR (p_year IS NOT NULL AND d.ym >= p_year::text || '01' AND d.ym <= p_year::text || '12')
      )
      AND (p_court IS NULL OR d.court_name = p_court)
      AND (p_cat IS NULL OR d.cat = p_cat)
    GROUP BY d.firm_name
  )
  SELECT row_number() OVER (ORDER BY (a.cases - coalesce(u.dup_cases, 0)) DESC)::int,
         a.firm_name, a.cases, a.lawyer_count,
         coalesce(u.dup_cases, 0)::bigint,
         (a.cases - coalesce(u.dup_cases, 0))::bigint
  FROM agg a LEFT JOIN dup u USING (firm_name)
  ORDER BY (a.cases - coalesce(u.dup_cases, 0)) DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION firm_court_ranking(text, text, int) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION firm_court_ranking(text, text, int) TO anon, authenticated;
