-- 案由供需鑽取：每個案由種類的桶內原始案由明細（前端點列開 modal 用）
-- 資料源同 cause_supply_stats（lawyer_month_stats.causes 滾動 60 月），
-- 掛進 refresh_lawyer_cause_stats() 月更；件數為律師端加總（一案多律師重複計，下限口徑不變）

CREATE TABLE IF NOT EXISTS cause_group_causes (
  cause_group text PRIMARY KEY,
  cat text NOT NULL,            -- 民事/刑事/家事/行政...（無 mapping 的 fallback 同 cause_supply_stats）
  total bigint NOT NULL,        -- 桶內全部案由件數合計
  distinct_causes int NOT NULL, -- 桶內不同案由字串數
  top_causes jsonb NOT NULL     -- [["案由", n], ...] 前 40
);

-- 公開裁判書聚合、非內部資料，開放層級對齊 cause_supply_stats（GRANT anon）
ALTER TABLE cause_group_causes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_cgc" ON cause_group_causes;
DROP POLICY IF EXISTS "read_cgc" ON cause_group_causes;
CREATE POLICY "read_cgc" ON cause_group_causes FOR SELECT USING (true);

-- 重建 refresh_lawyer_cause_stats：沿用原邏輯（migration 070），末尾多重建 cause_group_causes
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
END $$;

GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_stats() TO service_role;
