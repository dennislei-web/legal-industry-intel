-- 逐案層兩項輸出（mig 170）：驗證「全所案件掛所長名」掛名慣例＋每所案件金額帶。
-- 由 judgment_stats.py 的 pairamtfill 模式產出（月更 run 也會一併增量）。
--
-- lawyer_pair_month_stats：同一裁判書、同一當事人方（同一個訴訟代理人/辯護人
--   block，含續行）共同列名的律師配對，name_a < name_b canonical、同案去重。
--   與 050 的 lawyer_cocounsel_pairs 差異：僅同 block 內組合（block 間/對造間不算）、
--   無法院維度、永久保存不做 60 月滾動 prune。
-- lawyer_amount_month_stats：民事（含家事財產事件可遇則收）裁判全文抽
--   「訴訟標的金額/價額」（阿拉伯數字含千分位），桶化沿用 closed_case_stats.py
--   amount_bucket() 七桶口徑，配對該案全部律師 × 月。抽不到跳過（部分覆蓋）。

CREATE TABLE IF NOT EXISTS lawyer_pair_month_stats (
  ym     text NOT NULL,
  name_a text NOT NULL,
  name_b text NOT NULL,
  cases  int  NOT NULL DEFAULT 0,
  PRIMARY KEY (ym, name_a, name_b)
);
CREATE INDEX IF NOT EXISTS idx_lpms_a ON lawyer_pair_month_stats (name_a);
CREATE INDEX IF NOT EXISTS idx_lpms_b ON lawyer_pair_month_stats (name_b);

CREATE TABLE IF NOT EXISTS lawyer_amount_month_stats (
  ym     text NOT NULL,
  name   text NOT NULL,
  bucket text NOT NULL,
  cases  int  NOT NULL DEFAULT 0,
  PRIMARY KEY (ym, name, bucket)
);
CREATE INDEX IF NOT EXISTS idx_lams_name ON lawyer_amount_month_stats (name);

ALTER TABLE lawyer_pair_month_stats   ENABLE ROW LEVEL SECURITY;
ALTER TABLE lawyer_amount_month_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lpms" ON lawyer_pair_month_stats;
DROP POLICY IF EXISTS "auth_read_lams" ON lawyer_amount_month_stats;
CREATE POLICY "auth_read_lpms" ON lawyer_pair_month_stats   FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read_lams" ON lawyer_amount_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);
