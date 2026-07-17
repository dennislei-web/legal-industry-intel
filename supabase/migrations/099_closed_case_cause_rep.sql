-- 099: 終結案件微資料「案由種類 × 委任情形」交叉聚合（案由供需 Phase 2）
-- closed_case_stats.py 解析民事訴訟/家事訴訟 txt 時，對每案取 (原告有律師, 被告有律師)
-- 組合 × 案由種類，聚合成 (月×檔型×種類) 的四格分布。用以回答「哪些案由當事人不請律師」
-- ——委任率低＋件數大＝律師未滲透市場；委任率高＋集中度低＝紅海（官方統計無案由別委任率）。
-- 口徑：終結案件、任一造「有律師代理」含法扶；種類用 scripts/cause_map.py 的 map_judgment()
-- （跟供給面 lawyer_cause_stats / cause_supply_stats 同一把尺，家事＝非訟細項優先）。
-- 第一版僅民事訴訟＋家事訴訟檔（刑事是辯護人口徑不同，後補）；家事非訟檔無代理欄，
-- 保護令等純非訟種類不在表內，映入非訟桶的種類（如繼承非訟）只覆蓋其中的「訴訟」案件。

CREATE TABLE IF NOT EXISTS closed_case_cause_rep_stats (
  yyyymm text NOT NULL,             -- 西元年月
  file_type text NOT NULL,          -- 民事訴訟 / 家事訴訟
  cause_group text NOT NULL,        -- map_judgment() 種類
  n_total int NOT NULL,
  n_both int NOT NULL DEFAULT 0,    -- 原被告雙方都有律師
  n_p_only int NOT NULL DEFAULT 0,  -- 僅原告有律師
  n_d_only int NOT NULL DEFAULT 0,  -- 僅被告有律師
  n_none int NOT NULL DEFAULT 0,    -- 雙方皆無
  PRIMARY KEY (yyyymm, file_type, cause_group)
);
CREATE INDEX IF NOT EXISTS idx_ccrs_type_group ON closed_case_cause_rep_stats (file_type, cause_group, yyyymm);

ALTER TABLE closed_case_cause_rep_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ccrs" ON closed_case_cause_rep_stats;
CREATE POLICY "auth_read_ccrs" ON closed_case_cause_rep_stats FOR SELECT USING (auth.uid() IS NOT NULL);

-- 已回填月份（backfill-rep 模式用）
CREATE OR REPLACE FUNCTION closed_case_rep_months()
RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(array_agg(DISTINCT yyyymm), '{}') FROM closed_case_cause_rep_stats;
$$;

-- 案由種類 × 年度 委任分布（全國聚合；前端供需表「委任率」欄與 modal 委任分布共用一份）
-- months 供前端判斷完整年（>=12）；年=西元曆年
CREATE OR REPLACE FUNCTION cause_rep_yearly(p_file_type text DEFAULT NULL)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.y, t.n_total DESC), '[]'::json) FROM (
    SELECT file_type, cause_group, left(yyyymm, 4) AS y,
           count(DISTINCT yyyymm)::int AS months,
           sum(n_total)::int AS n_total, sum(n_both)::int AS n_both,
           sum(n_p_only)::int AS n_p_only, sum(n_d_only)::int AS n_d_only,
           sum(n_none)::int AS n_none
    FROM closed_case_cause_rep_stats
    WHERE p_file_type IS NULL OR file_type = p_file_type
    GROUP BY 1, 2, 3) t;
$$;

GRANT EXECUTE ON FUNCTION closed_case_rep_months() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_rep_yearly(text) TO anon, authenticated;

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('終結案件案由委任交叉', 'https://opendata.judicial.gov.tw/', '司法院開放資料 - 終結案件資料月包：案由種類 × 委任情形交叉（民事/家事訴訟）', 'closed_cases', 'closed_case_stats', 'monthly')
ON CONFLICT (name) DO NOTHING;
