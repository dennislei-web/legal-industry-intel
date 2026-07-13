-- 合議庭共署 pair：法官「共署指紋」
-- 來源：scripts/jy_copanel.py（裁判書月包逐篇抽合議庭組合，canonical judge_a < judge_b）
-- 用途：同名法官區辨——同一名字若屬兩人，其共署同事圈幾乎不相交；
--       亦可仲裁 judge_changes 的「查無遷調」疑難 case（詳 memory project-judge-transfers）。

CREATE TABLE IF NOT EXISTS judge_copanel_pairs (
  judge_a text NOT NULL,
  judge_b text NOT NULL,
  court_name text NOT NULL,
  yyyymm text NOT NULL,
  case_count int NOT NULL,
  PRIMARY KEY (judge_a, judge_b, court_name, yyyymm)
);

CREATE INDEX IF NOT EXISTS idx_jcp_a ON judge_copanel_pairs (judge_a);
CREATE INDEX IF NOT EXISTS idx_jcp_b ON judge_copanel_pairs (judge_b);
CREATE INDEX IF NOT EXISTS idx_jcp_ym ON judge_copanel_pairs (yyyymm);

ALTER TABLE judge_copanel_pairs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "authenticated_read_jcp" ON judge_copanel_pairs;
CREATE POLICY "authenticated_read_jcp" ON judge_copanel_pairs
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 指定法官在指定法院/期間的共署圈（分析用）
CREATE OR REPLACE FUNCTION judge_copanel_circle(p_name text, p_court text DEFAULT NULL,
                                                p_from text DEFAULT NULL, p_to text DEFAULT NULL)
RETURNS TABLE (colleague text, court_name text, first_ym text, last_ym text, cases bigint) AS $$
  SELECT CASE WHEN judge_a = p_name THEN judge_b ELSE judge_a END AS colleague,
         court_name, min(yyyymm), max(yyyymm), sum(case_count)
  FROM judge_copanel_pairs
  WHERE (judge_a = p_name OR judge_b = p_name)
    AND (p_court IS NULL OR court_name = p_court)
    AND (p_from IS NULL OR yyyymm >= p_from)
    AND (p_to IS NULL OR yyyymm <= p_to)
  GROUP BY 1, 2
  ORDER BY 5 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
