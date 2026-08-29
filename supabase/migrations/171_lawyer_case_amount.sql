-- 律師×訴訟標的金額（官方 join 口徑，mig 171）
-- 產出：scripts/lawyer_case_amount.py —— 終結案件微資料月包（官方標的金額）×
--       裁判書 clients 快取（scripts/.judgment_work/{ym}_clients.jsonl.gz，律師名）
--       按 JID 前 4 段 (法院代碼,民國年,字別,號) join。
-- 口徑：民事訴訟＋家事訴訟檔、官方登錄標的金額 > 0、clients 側全 cat
--       （微資料民訴檔含高院家事二審，clients 標成家事 cat）、律師×案去重、
--       ym = 終結月（微資料側）。桶界沿用 closed_case_stats 七桶（無 0 桶）。
-- 定位：取代 mig 170 lawyer_amount_month_stats（全文 regex 抽取）的分析口徑——
--       202503 試跑：join 率 97.8%（含家事 cat 99.1%）；全文抽取 1-10萬桶
--       高估 ~6 倍、月樣本量僅本口徑 1/5.6。舊表暫留、前端尚未接。

CREATE TABLE IF NOT EXISTS lawyer_case_amount_stats (
  ym     text NOT NULL,
  name   text NOT NULL,
  bucket text NOT NULL,
  cases  int  NOT NULL DEFAULT 0,
  PRIMARY KEY (ym, name, bucket)
);
CREATE INDEX IF NOT EXISTS idx_lcas_name ON lawyer_case_amount_stats (name);

ALTER TABLE lawyer_case_amount_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lcas" ON lawyer_case_amount_stats;
CREATE POLICY "auth_read_lcas" ON lawyer_case_amount_stats
  FOR SELECT USING (auth.uid() IS NOT NULL);
