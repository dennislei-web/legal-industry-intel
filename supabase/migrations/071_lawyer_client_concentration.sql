-- 人名事務所律師「訴訟客戶集中度」（真經營 vs 特定公司服務分析，2026-07-09）
-- 產出管線：scripts 外部一次性分析（裁判書 12 個月當事人欄抽取，非 judgment_stats.py 常規管線）
-- 口徑：司法院公開裁判書 2025-05~2026-04；當事人=法人（公司/機關/組織）per-case 去重；
--       top1_share 分母含個人當事人案件；姓名為 key（同名合併，前端沿用 name_ambiguous 旗標）
-- 目前僅涵蓋「人名事務所」律師（所名=所內律師本名，約 1,900 位中有出庭的 1,609 位）
CREATE TABLE IF NOT EXISTS lawyer_client_concentration (
  name text PRIMARY KEY,
  window_start text NOT NULL,          -- 'YYYYMM'
  window_end text NOT NULL,
  n_cases int NOT NULL,                -- 視窗內出庭案件數
  tier text NOT NULL,                  -- A 高度集中 / B 中度集中 / C 分散 / D 樣本不足
  top1_name text,
  top1_n int NOT NULL DEFAULT 0,
  top1_share numeric NOT NULL DEFAULT 0,
  top_entities jsonb,                  -- [[法人名, 件數], ...] top3
  top_court text,
  top_titles jsonb,                    -- 主要案由 top3
  refreshed_at timestamptz DEFAULT now()
);

ALTER TABLE lawyer_client_concentration ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lcc" ON lawyer_client_concentration;
CREATE POLICY "auth_read_lcc" ON lawyer_client_concentration
  FOR SELECT USING (auth.uid() IS NOT NULL);
