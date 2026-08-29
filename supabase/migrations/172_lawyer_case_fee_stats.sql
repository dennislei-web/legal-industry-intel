-- 律師×月 收費模型 v2 聚合（mig 172，主批次 session 需求）：
-- 每案推估費 = [基本費 + max(0, 標的金額−200萬)×1.5%] × 審級係數(二三審1.5) × 身分係數
-- 桶表（171 lawyer_case_amount_stats）算不出超額加費（200萬門檻切在桶中間、
-- 1000萬+ 桶內離散度 40 倍）——join 管線逐案有精確金額，聚合時一併輸出本表。
-- 產出：scripts/lawyer_case_amount.py（與桶表同一趟 join，母體=join 成功且金額>0 案）。
-- 審級按 JID 法院代碼：TPH/TCH/TNH/KSH/HLH/KMH 開頭=二審、TPS=三審（微資料無
-- 最高法院民訴版式，恆 0 留欄位）、其餘（地院/簡易庭/智財商業）=一審=總數−二−三。

CREATE TABLE IF NOT EXISTS lawyer_case_fee_stats (
  ym                 text   NOT NULL,
  name               text   NOT NULL,
  cases_200plus      int    NOT NULL DEFAULT 0,  -- 標的金額 > 200 萬件數
  surcharge_base_sum bigint NOT NULL DEFAULT 0,  -- Σ max(0, 金額−2,000,000)，單位元
  appeal2_cases      int    NOT NULL DEFAULT 0,
  appeal3_cases      int    NOT NULL DEFAULT 0,
  PRIMARY KEY (ym, name)
);
CREATE INDEX IF NOT EXISTS idx_lcfs_name ON lawyer_case_fee_stats (name);

ALTER TABLE lawyer_case_fee_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lcfs" ON lawyer_case_fee_stats;
CREATE POLICY "auth_read_lcfs" ON lawyer_case_fee_stats
  FOR SELECT USING (auth.uid() IS NOT NULL);
