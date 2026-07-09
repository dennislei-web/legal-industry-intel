-- Phase B：判決書案由（JTITLE）進律師/法官月表（judgment_stats.py 解析時帶入）
-- causes jsonb 鍵 = 「案類|正規化案由」複合鍵（如「民事|損害賠償」「刑事|詐欺」），
-- 值 = 該 (人,法院,月) 的件數。存**原始案由**而非 mapping 後種類——
-- mapping 規則（scripts/cause_map.py）改版時只要重算 cause_group_map + rollup，
-- 不必重解析 60 個月包。
-- 只回填滾動 60 月（對齊 lawyer_judgment_stats.cases_5yr 口徑），更早月份為 NULL。

ALTER TABLE lawyer_month_stats ADD COLUMN IF NOT EXISTS causes jsonb;
ALTER TABLE judge_month_stats ADD COLUMN IF NOT EXISTS causes jsonb;

-- 案由 → 種類 對照（由 judgment_stats.py 上傳時同步 upsert；
-- 單一真實源是 scripts/cause_map.py 的 map_judgment()，本表是 SQL rollup 用的投影）
CREATE TABLE IF NOT EXISTS cause_group_map (
  ck text PRIMARY KEY,          -- 複合鍵「案類|案由」，與 causes jsonb 鍵一致
  cat text NOT NULL,            -- 民事/刑事/家事/行政/少年/懲戒/其他
  cause text NOT NULL,          -- 正規化案由
  cause_group text NOT NULL     -- 種類（民事對齊官方13類、刑事罪名分組、家事分組）
);
CREATE INDEX IF NOT EXISTS idx_cgm_group ON cause_group_map (cat, cause_group);

ALTER TABLE cause_group_map ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_cgm" ON cause_group_map;
CREATE POLICY "auth_read_cgm" ON cause_group_map FOR SELECT USING (auth.uid() IS NOT NULL);
