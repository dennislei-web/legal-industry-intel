-- ============================================================
-- 180: firm_cause_shares — 各所案由群組成 RPC（精品利基加權排序用）
-- ============================================================
-- 供「產業深度報告＞精品利基變現」把組內排序從「全所人均營收」改成
-- 「該領域案量占比 × 人均營收」。占比分子＝利基映射到的案由群件數、
-- 分母＝該所全部案由群件數；資料鏈 = firm_analysis_facts.firm
-- → moj_lawyers.office_normalized（現職）→ lawyer_cause_stats.by_group。
-- 已知限制：lawyer_cause_stats 以姓名為鍵，跨所同名會互相污染（下限口徑
-- 註記於前端）；cats 為各案由群主要案類（cause_group_map 多數決）加總。

CREATE OR REPLACE FUNCTION firm_cause_shares()
RETURNS TABLE(firm TEXT, total BIGINT, groups JSONB, cats JSONB)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required';
  END IF;
  RETURN QUERY
  WITH gcat AS (
    SELECT DISTINCT ON (m.cause_group) m.cause_group, m.cat
    FROM (SELECT cause_group, cat, count(*) c FROM cause_group_map GROUP BY 1, 2) m
    ORDER BY m.cause_group, m.c DESC
  ),
  per_group AS (
    SELECT f.firm AS f_firm, g.key AS cause_group, sum(g.value::int) AS n
    FROM firm_analysis_facts f
    JOIN moj_lawyers ml ON ml.office_normalized = f.firm AND ml.practice_end_date IS NULL
    JOIN lawyer_cause_stats s ON s.name = ml.name,
    LATERAL jsonb_each_text(s.by_group) g
    GROUP BY f.firm, g.key
  )
  SELECT p.f_firm,
         sum(p.n)::BIGINT,
         jsonb_object_agg(p.cause_group, p.n),
         (SELECT jsonb_object_agg(cat, cn) FROM (
            SELECT COALESCE(gc.cat, '其他') AS cat, sum(p2.n) AS cn
            FROM per_group p2 LEFT JOIN gcat gc ON gc.cause_group = p2.cause_group
            WHERE p2.f_firm = p.f_firm GROUP BY 1
          ) c)
  FROM per_group p
  GROUP BY p.f_firm;
END;
$$;

REVOKE EXECUTE ON FUNCTION firm_cause_shares() FROM anon, public;
GRANT EXECUTE ON FUNCTION firm_cause_shares() TO authenticated;
