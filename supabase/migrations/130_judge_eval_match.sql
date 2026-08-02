-- （原編 129，與並行 session 的 129_crm_officer_reviews 撞號改 130）
-- 評鑑決議 ↔ 懲戒/彈劾 對應（解遮罩）：評鑑決議書公開版隱名，但後端職務法庭懲戒判決
-- 與監察院彈劾案文「具名」且會引用「○年度評字第○號」→ 用引用鏈把評鑑成立案對應回具名案。
-- 來源腳本：scripts/judge_evaluations.py match（citation=原文引用；inferred=姓氏+法院+時序推定）

ALTER TABLE judge_evaluations
  ADD COLUMN IF NOT EXISTS matched_kind text,     -- disc（懲戒裁判）/ imp（監察院彈劾）
  ADD COLUMN IF NOT EXISTS matched_case_no text,  -- 對應案號
  ADD COLUMN IF NOT EXISTS matched_name text,     -- 具名法官（由對應案解遮罩）
  ADD COLUMN IF NOT EXISTS match_basis text;      -- citation / inferred

CREATE INDEX IF NOT EXISTS idx_jeval_mname ON judge_evaluations (matched_name);
