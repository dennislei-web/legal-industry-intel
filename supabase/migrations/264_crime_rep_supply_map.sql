-- 264：案由供需「刑事」頁補委任率＋市場欄（2026-11-05）
-- 口徑（雷拍板）：分母＝地院終結被告人次；主欄「有律師」只算選任律師（含法扶）；公設／義務律師另列供下鑽展開。
--
-- 1. closed_case_cause_rep_stats 加 n_public／n_duty 兩欄。刑事訴訟列重用既有欄位，讓前端
--    repped = n_both + n_p_only + n_d_only 的公式不變：
--      n_total  ＝ 被告人次（每被告取第一個罪名層當主罪名，與 closed_case_cause_* 同單位）
--      n_p_only ＝ 選任律師辯護（自費）     n_d_only ＝ 選任律師辯護-法律扶助     n_both ＝ 0
--      n_public ＝ 公設辯護人辯護          n_duty   ＝ 義務律師辯護              n_none ＝ 無／其他
--    → 主欄委任率＝選任含法扶 ÷ 被告人次，與民事「任一造有律師代理（含法扶）」最可比。
-- 2. crime_supply_map：罪名條號（closed_case_cause_national.cause，如「刑法§276」）→ 供給面種類
--    （scripts/cause_map.py CRIME_TITLE_RULES 的 41 組＋其他刑事）。規則單一真實源在 Python 的
--    map_criminal_supply()，由 closed_case_stats.py 算好 upsert（sync-crime-map 一次補齊、每月 run 順帶更新）。
--    必須做到條號級：殺人罪章 §276 過失致死 7,927 人次 vs §271 殺人 1,109；背信及重利罪章 §344/344-1 重利 1,040 vs §342 背信 1,154。
-- 3. closed_case_rep_months 加 p_file_type（簽名變更 → 先 DROP，mig 098 教訓）；cause_rep_yearly 多回 n_public／n_duty。
-- 4. cause_group_yearly_crim()：刑事市場序列（全國被告人次 × 供給面種類 × 年），前端刑事頁「市場終結／3 年變化」兩欄用；
--    未入對照表的罪名落「其他刑事」（新法名要等下一次 ETL 補對照）。

ALTER TABLE closed_case_cause_rep_stats
  ADD COLUMN IF NOT EXISTS n_public int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS n_duty int NOT NULL DEFAULT 0;
COMMENT ON COLUMN closed_case_cause_rep_stats.n_total IS '民事／家事：終結案件數；刑事訴訟：地院終結被告人次';
COMMENT ON COLUMN closed_case_cause_rep_stats.n_p_only IS '民事／家事：僅原告有律師；刑事訴訟：選任律師辯護（自費）';
COMMENT ON COLUMN closed_case_cause_rep_stats.n_d_only IS '民事／家事：僅被告有律師；刑事訴訟：選任律師辯護-法律扶助';
COMMENT ON COLUMN closed_case_cause_rep_stats.n_public IS '刑事訴訟：公設辯護人辯護（被告人次）；民事／家事恆 0';
COMMENT ON COLUMN closed_case_cause_rep_stats.n_duty IS '刑事訴訟：義務律師辯護（被告人次）；民事／家事恆 0';

CREATE TABLE IF NOT EXISTS crime_supply_map (
  cause text PRIMARY KEY,            -- 正規化罪名鍵：法名§條[-之N]（同 closed_case_cause_national.cause）
  cause_group text NOT NULL,         -- 需求面罪章／特別法名（cause_map.map_criminal）
  supply_group text NOT NULL,        -- 供給面種類（cause_map.map_criminal_supply）
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE crime_supply_map ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_csm" ON crime_supply_map;
CREATE POLICY "auth_read_csm" ON crime_supply_map FOR SELECT USING (auth.uid() IS NOT NULL);

DROP FUNCTION IF EXISTS closed_case_rep_months();
CREATE OR REPLACE FUNCTION closed_case_rep_months(p_file_type text DEFAULT NULL)
RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(array_agg(DISTINCT yyyymm), '{}') FROM closed_case_cause_rep_stats
  WHERE p_file_type IS NULL OR file_type = p_file_type;
$$;

CREATE OR REPLACE FUNCTION cause_rep_yearly(p_file_type text DEFAULT NULL)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.y, t.n_total DESC), '[]'::json) FROM (
    SELECT file_type, cause_group, left(yyyymm, 4) AS y,
           count(DISTINCT yyyymm)::int AS months,
           sum(n_total)::int AS n_total, sum(n_both)::int AS n_both,
           sum(n_p_only)::int AS n_p_only, sum(n_d_only)::int AS n_d_only,
           sum(n_none)::int AS n_none,
           sum(n_public)::int AS n_public, sum(n_duty)::int AS n_duty
    FROM closed_case_cause_rep_stats
    WHERE p_file_type IS NULL OR file_type = p_file_type
    GROUP BY 1, 2, 3) t;
$$;

CREATE OR REPLACE FUNCTION cause_group_yearly_crim()
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.y, t.n DESC), '[]'::json) FROM (
    SELECT left(n.yyyymm, 4) AS y, COALESCE(m.supply_group, '其他刑事') AS cause_group,
           sum(n.case_count)::int AS n, sum(n.convicted)::int AS convicted,
           count(DISTINCT n.yyyymm)::int AS months
    FROM closed_case_cause_national n
    LEFT JOIN crime_supply_map m ON m.cause = n.cause
    WHERE n.file_type = '刑事訴訟'
    GROUP BY 1, 2) t;
$$;

GRANT EXECUTE ON FUNCTION closed_case_rep_months(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_rep_yearly(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_group_yearly_crim() TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
