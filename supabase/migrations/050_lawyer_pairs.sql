-- 律師配對關係（Phase 2）：點一位律師 → 對到哪些法官／協同律師／對造律師
-- 三張「月 × 配對」聚合表，由 judgment_stats.py 的 pairfill/run 產出（近 5 年 rolling 視窗）：
--   lawyer_judge_pairs     律師 → 法官（× 法院、含案類 cats）；律師來源＝與 lawyer_month_stats 同一份 extract_lawyers
--   lawyer_cocounsel_pairs 協同律師（同案同造兩兩；canonical lawyer_a < lawyer_b）
--   lawyer_opposing_pairs  對造律師（僅民事/家事/行政，攻方 P × 守方 D；canonical a < b）
-- 查詢走 per-lawyer RPC lawyer_pair_summary(name)，不做全域 refresh（Micro 1GB RAM 安全）
-- 口徑：僅公開裁判書、姓名為 key（同名合併）、案量為下限；對造密度天生低（民事僅約 3 成兩造皆委任）

CREATE TABLE IF NOT EXISTS lawyer_judge_pairs (
  lawyer_name text NOT NULL,
  judge_name  text NOT NULL,
  court_name  text NOT NULL,
  yyyymm      text NOT NULL,
  case_count  int  NOT NULL DEFAULT 0,
  cats        jsonb
);
CREATE INDEX IF NOT EXISTS idx_ljp_lawyer ON lawyer_judge_pairs (lawyer_name);
CREATE INDEX IF NOT EXISTS idx_ljp_ym     ON lawyer_judge_pairs (yyyymm);

CREATE TABLE IF NOT EXISTS lawyer_cocounsel_pairs (
  lawyer_a   text NOT NULL,
  lawyer_b   text NOT NULL,
  court_name text NOT NULL,
  yyyymm     text NOT NULL,
  case_count int  NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_ccp_a  ON lawyer_cocounsel_pairs (lawyer_a);
CREATE INDEX IF NOT EXISTS idx_ccp_b  ON lawyer_cocounsel_pairs (lawyer_b);
CREATE INDEX IF NOT EXISTS idx_ccp_ym ON lawyer_cocounsel_pairs (yyyymm);

CREATE TABLE IF NOT EXISTS lawyer_opposing_pairs (
  lawyer_a   text NOT NULL,
  lawyer_b   text NOT NULL,
  court_name text NOT NULL,
  yyyymm     text NOT NULL,
  case_count int  NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_opp_a  ON lawyer_opposing_pairs (lawyer_a);
CREATE INDEX IF NOT EXISTS idx_opp_b  ON lawyer_opposing_pairs (lawyer_b);
CREATE INDEX IF NOT EXISTS idx_opp_ym ON lawyer_opposing_pairs (yyyymm);

ALTER TABLE lawyer_judge_pairs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE lawyer_cocounsel_pairs ENABLE ROW LEVEL SECURITY;
ALTER TABLE lawyer_opposing_pairs  ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ljp" ON lawyer_judge_pairs;
DROP POLICY IF EXISTS "auth_read_ccp" ON lawyer_cocounsel_pairs;
DROP POLICY IF EXISTS "auth_read_opp" ON lawyer_opposing_pairs;
CREATE POLICY "auth_read_ljp" ON lawyer_judge_pairs     FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read_ccp" ON lawyer_cocounsel_pairs FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read_opp" ON lawyer_opposing_pairs  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 點一位律師的配對彙總：三塊各回 top-N（跨月/跨法院加總，錨定表內 rolling 視窗）
-- 協同/對造為 canonical 存一次，查詢時 lawyer_a、lawyer_b 兩向 union 再合併
CREATE OR REPLACE FUNCTION lawyer_pair_summary(p_name text, p_limit int DEFAULT 20)
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'judges', COALESCE((
      SELECT jsonb_agg(j) FROM (
        SELECT judge_name AS judge, court_name AS court, sum(case_count)::int AS cases
        FROM lawyer_judge_pairs WHERE lawyer_name = p_name
        GROUP BY judge_name, court_name
        ORDER BY sum(case_count) DESC, judge_name
        LIMIT p_limit
      ) j
    ), '[]'::jsonb),
    'cocounsel', COALESCE((
      SELECT jsonb_agg(c) FROM (
        SELECT peer, sum(c)::int AS cases FROM (
          SELECT lawyer_b AS peer, case_count AS c FROM lawyer_cocounsel_pairs WHERE lawyer_a = p_name
          UNION ALL
          SELECT lawyer_a AS peer, case_count AS c FROM lawyer_cocounsel_pairs WHERE lawyer_b = p_name
        ) u GROUP BY peer ORDER BY sum(c) DESC, peer LIMIT p_limit
      ) c
    ), '[]'::jsonb),
    'opposing', COALESCE((
      SELECT jsonb_agg(o) FROM (
        SELECT peer, sum(c)::int AS cases FROM (
          SELECT lawyer_b AS peer, case_count AS c FROM lawyer_opposing_pairs WHERE lawyer_a = p_name
          UNION ALL
          SELECT lawyer_a AS peer, case_count AS c FROM lawyer_opposing_pairs WHERE lawyer_b = p_name
        ) u GROUP BY peer ORDER BY sum(c) DESC, peer LIMIT p_limit
      ) o
    ), '[]'::jsonb)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lawyer_pair_summary(text, int) SET statement_timeout = '30s';
