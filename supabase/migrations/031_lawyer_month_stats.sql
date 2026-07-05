-- 裁判書 → 律師統計（訴訟代理人/辯護人抽取）
-- 與 judge_month_stats 同管線產出，未來取代 Lawsnote 律師案件數的基礎表
CREATE TABLE IF NOT EXISTS lawyer_month_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  court_name text NOT NULL,
  yyyymm text NOT NULL,
  case_count int NOT NULL,
  cats jsonb,
  UNIQUE (name, court_name, yyyymm)
);
CREATE INDEX IF NOT EXISTS idx_lms_name ON lawyer_month_stats (name);
CREATE INDEX IF NOT EXISTS idx_lms_yyyymm ON lawyer_month_stats (yyyymm);

ALTER TABLE lawyer_month_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lms" ON lawyer_month_stats;
CREATE POLICY "auth_read_lms" ON lawyer_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);
