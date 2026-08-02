-- 法官細部分析 modal（法官版 showLawyerDetail）後端支援
-- 1) lawyer_judge_pairs 反向索引：從法官查「常對到的律師」（表原本只有 lawyer 側索引）
-- 2) judge_pair_summary：per-judge 配對彙總（口徑同 lawyer_pair_summary：近 5 年 rolling、
--    僅公開裁判書、姓名為 key 同名合併、案量為下限）
-- 3) judge_cause_summary：per-judge 案由畫像（judge_month_stats.causes × cause_group_map，
--    滾動 60 月即時聚合；每法官列數少，不需 lawyer_cause_stats 式 cache 表）

CREATE INDEX IF NOT EXISTS idx_ljp_judge ON lawyer_judge_pairs (judge_name);

-- 點一位法官：常對到的律師（p_court 非 NULL 時鎖定該法院，避免同名跨院污染）
CREATE OR REPLACE FUNCTION judge_pair_summary(p_name text, p_court text DEFAULT NULL,
                                              p_limit int DEFAULT 12)
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'lawyers', COALESCE((
      SELECT jsonb_agg(l) FROM (
        SELECT lawyer_name AS lawyer, sum(case_count)::int AS cases
        FROM lawyer_judge_pairs
        WHERE judge_name = p_name AND (p_court IS NULL OR court_name = p_court)
        GROUP BY lawyer_name
        ORDER BY sum(case_count) DESC, lawyer_name
        LIMIT p_limit
      ) l
    ), '[]'::jsonb)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION judge_pair_summary(text, text, int) SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION judge_pair_summary(text, text, int) TO authenticated, service_role;

-- 點一位法官：案由畫像（by_group 種類分布 + top_causes 原始案由前 N）
CREATE OR REPLACE FUNCTION judge_cause_summary(p_name text, p_court text DEFAULT NULL,
                                               p_top int DEFAULT 20)
RETURNS jsonb AS $$
  WITH win AS (
    SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM') AS cutoff
    FROM judge_month_stats WHERE causes IS NOT NULL
  ), c AS (
    SELECT k.key AS ck, sum((k.value)::int)::int AS n
    FROM judge_month_stats j, jsonb_each_text(j.causes) k, win
    WHERE j.name = p_name AND (p_court IS NULL OR j.court_name = p_court)
      AND j.causes IS NOT NULL AND j.yyyymm >= win.cutoff
    GROUP BY 1
  )
  SELECT jsonb_build_object(
    'total', COALESCE((SELECT sum(n)::int FROM c), 0),
    'by_group', COALESCE((
      SELECT jsonb_object_agg(grp, gn) FROM (
        SELECT coalesce(m.cause_group, split_part(c.ck, '|', 1)) AS grp, sum(c.n)::int AS gn
        FROM c LEFT JOIN cause_group_map m ON m.ck = c.ck
        GROUP BY 1) s
    ), '{}'::jsonb),
    'top_causes', COALESCE((
      SELECT jsonb_agg(jsonb_build_array(ck, n) ORDER BY n DESC) FROM (
        SELECT ck, n FROM c ORDER BY n DESC LIMIT p_top) t
    ), '[]'::jsonb)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION judge_cause_summary(text, text, int) SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION judge_cause_summary(text, text, int) TO authenticated, service_role;
