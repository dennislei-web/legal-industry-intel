-- ============================================================
-- 186: 所級案件量去重 — 判決層同所共同署名修正
-- ============================================================
-- 問題：所級案量 = SUM(lawyer_month_stats.case_count) 時，同一裁判書由多位
-- 同所律師共同署名會每人各計 1 件（掛名制度所與大所協作團隊都被灌水；
-- lidx 抽樣實測：理律民家判決 mention 灌水 54%、喆律 37%、黃重鋼 58%）。
-- mig 170 的 lawyer_pair_month_stats 只收「同一個代理人 label（含續行）」的
-- 同 block 配對；掛名慣例常見「同方每位律師各掛一個 label」＝跨 block，
-- pair 表系統性低估，去重必須回判決層。
--
-- lawyer_group_month_stats：ym × 同一裁判書共同署名的律師名集合（>=2 人，
--   sorted text[]；全案類、判決＋裁定，跨當事人方合併——同所律師代理不同
--   共同被告仍屬同一判決，所級只計 1 件）。judgment_stats.py parse() 產出
--   （agg.json 的 lawyer_group key），groupfill 模式回填、月更 run 自動增量。
--   永久保存不做滾動 prune（同 mig 170 的 lawyer_pair_month_stats）。
--   單人判決不存：其去重數＝名目數，lawyer_month_stats 已涵蓋。
--
-- firm_dedup_month_stats：ym × firm_key 的所×月名目/去重案量 cache，
--   refresh_firm_dedup_stats() 全量重建（TRUNCATE+INSERT，掛 refresh_stats()
--   月更）。歸戶口徑與 moj_firm_statistics()（142 版）一致：現職名冊
--   （deregistered_at IS NULL、排「律師未顯示」）姓名唯一者歸戶、
--   firm_key 截到第一個「法律/律師事務所」（分所合併）。
--   dedup_cases = nominal - Σ(同判決同所 k 人的 k-1)＝該所 distinct 判決數。
--   注意：按「現任名冊」回溯（轉入律師帶入過往共列、離所者不計），
--   與 lawyer_judgment_stats/firm_court_ranking 同一資料天花板。

CREATE TABLE IF NOT EXISTS lawyer_group_month_stats (
  ym      text   NOT NULL,
  lawyers text[] NOT NULL,   -- sorted、同案去重後的律師名集合（>=2 人）
  cases   int    NOT NULL DEFAULT 0,
  PRIMARY KEY (ym, lawyers)
);

CREATE TABLE IF NOT EXISTS firm_dedup_month_stats (
  ym            text NOT NULL,
  firm_key      text NOT NULL,
  nominal_cases int  NOT NULL DEFAULT 0,  -- Σ 律師 mention（現職唯一名歸戶）
  dup_cases     int  NOT NULL DEFAULT 0,  -- 同判決同所 k 人 → k-1 重複合計
  dedup_cases   int  NOT NULL DEFAULT 0,  -- nominal - dup ＝ distinct 判決數
  lawyer_n      int  NOT NULL DEFAULT 0,  -- 當月有出庭的歸戶律師數
  PRIMARY KEY (ym, firm_key)
);
CREATE INDEX IF NOT EXISTS idx_fdms_firm ON firm_dedup_month_stats (firm_key);

ALTER TABLE lawyer_group_month_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_dedup_month_stats   ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lgms" ON lawyer_group_month_stats;
DROP POLICY IF EXISTS "auth_read_fdms" ON firm_dedup_month_stats;
CREATE POLICY "auth_read_lgms" ON lawyer_group_month_stats FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read_fdms" ON firm_dedup_month_stats   FOR SELECT USING (auth.uid() IS NOT NULL);

-- p_ym NULL＝全量重建（實測 ~10s＞PostgREST authenticator 的 8s statement_timeout，
-- 只能走 supabase db query / Management API 手動跑）；指定 p_ym＝單月增量
-- （DELETE+INSERT 該月，走 idx_lms_yyyymm，<2s，PostgREST RPC 可呼叫——
-- judgment_stats.py refresh_stats() 與 groupfill CI 都逐月打單月版）。
-- 注意函數層 SET statement_timeout 蓋不掉 authenticator 已武裝的頂層計時器。
DROP FUNCTION IF EXISTS refresh_firm_dedup_stats();
CREATE OR REPLACE FUNCTION refresh_firm_dedup_stats(p_ym text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_ym IS NULL THEN
    TRUNCATE firm_dedup_month_stats;
  ELSE
    DELETE FROM firm_dedup_month_stats WHERE ym = p_ym;
  END IF;
  INSERT INTO firm_dedup_month_stats (ym, firm_key, nominal_cases, dup_cases, dedup_cases, lawyer_n)
  WITH normalized AS (  -- 歸戶口徑同 moj_firm_statistics()（142 版）
    SELECT name,
      CASE WHEN office_normalized ~ '(法律事務所|律師事務所)'
        THEN REGEXP_REPLACE(office_normalized, '^(.+?(?:法律|律師)事務所).*$', '\1')
        ELSE office_normalized END AS firm_key
    FROM moj_lawyers
    WHERE office_normalized IS NOT NULL AND office_normalized <> ''
      AND office_normalized <> '律師未顯示'
      AND deregistered_at IS NULL
  ),
  fk AS (
    SELECT name, MIN(firm_key) AS firm_key FROM normalized
    GROUP BY name HAVING COUNT(*) = 1
  ),
  nom AS (
    SELECT m.yyyymm AS ym, f.firm_key,
           sum(m.case_count)::int AS nominal,
           count(DISTINCT m.name)::int AS lawyer_n
    FROM lawyer_month_stats m
    JOIN fk f ON f.name = m.name
    -- COALESCE range 寫法讓單月模式穩定走 idx_lms_yyyymm；202101 = group 表回填起點
    WHERE m.yyyymm >= COALESCE(p_ym, '202101') AND m.yyyymm <= COALESCE(p_ym, '999999')
    GROUP BY 1, 2
  ),
  dup AS (
    SELECT t.ym, t.firm_key, sum((t.k - 1) * t.cases)::int AS dup_cases
    FROM (
      -- 每組合列 × 所：k = 組合內歸戶到該所的人數（(ym,lawyers) 是 PK，分組即逐列）
      SELECT g.ym, g.lawyers, g.cases, f.firm_key, count(*) AS k
      FROM lawyer_group_month_stats g
      CROSS JOIN LATERAL unnest(g.lawyers) AS ln(name)
      JOIN fk f ON f.name = ln.name
      WHERE g.ym >= COALESCE(p_ym, '000000') AND g.ym <= COALESCE(p_ym, '999999')
      GROUP BY g.ym, g.lawyers, g.cases, f.firm_key
      HAVING count(*) >= 2
    ) t
    GROUP BY 1, 2
  )
  SELECT n.ym, n.firm_key, n.nominal,
         COALESCE(d.dup_cases, 0),
         n.nominal - COALESCE(d.dup_cases, 0),
         n.lawyer_n
  FROM nom n
  LEFT JOIN dup d ON d.ym = n.ym AND d.firm_key = n.firm_key;
END;
$$;

ALTER FUNCTION refresh_firm_dedup_stats(text) SET statement_timeout = '600s';
REVOKE EXECUTE ON FUNCTION refresh_firm_dedup_stats(text) FROM anon, public;
GRANT EXECUTE ON FUNCTION refresh_firm_dedup_stats(text) TO service_role;
