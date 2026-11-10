-- 產業觀察報告加「AI 解讀」（scripts/industry_watch_report.py 呼叫 Claude 依本期＋前幾期數字撰寫）
-- interpretation：{headline, insights:[{title,body}], zhelu:[], actions:[], watch:[], data_cautions:[]}
-- 解讀失敗或沒有 API 金鑰時欄位維持 NULL，報告本身（規則產生的重點與各段）照常寫入
ALTER TABLE industry_watch_reports
  ADD COLUMN IF NOT EXISTS interpretation jsonb,
  ADD COLUMN IF NOT EXISTS interp_model   text,
  ADD COLUMN IF NOT EXISTS interpreted_at timestamptz;
