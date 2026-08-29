-- 收費模型 v2 標的加費 cap（mig 173）：單案計費標的上限 1 億（使用者 2026-08-29 拍板）
-- 未 cap 的 surcharge_base_sum 在極端大案失真（實測：喆律李杰峰 15 件超額合計 95.5 億 →
-- 加費 1.4 億，大於整所訴訟側推估；恆業陳昶安 54.8 億衛福部機構案）。標的≠收費基礎，
-- cap 1 億＝單案加費封頂 147 萬，與大案律師費實務天花板同量級。
-- cap 必須逐案套用後才加總（聚合後無法回推），由 scripts/lawyer_case_amount.py 產出。
-- surcharge_base_sum（未 cap）保留不動，供離群值對照。

ALTER TABLE lawyer_case_fee_stats
  ADD COLUMN IF NOT EXISTS surcharge_capped_sum bigint NOT NULL DEFAULT 0;

COMMENT ON COLUMN lawyer_case_fee_stats.surcharge_capped_sum IS
  'Σ max(0, min(標的金額, 100000000) − 2000000)，逐案套 cap 後加總，單位元';
