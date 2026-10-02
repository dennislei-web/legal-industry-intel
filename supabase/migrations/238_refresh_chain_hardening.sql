-- ============================================================
-- 238: 裁判書月更 refresh 鏈補強（清洗函數逾時＋rollup 完成標記）
-- ============================================================
-- 事故（2026-10-01 本機實跑 `judgment_stats.py run 202606`）：
--   clean_judge_name_truncations() 經 PostgREST 回 500。這支函數的 proconfig 是空的
--   （沒有 SET statement_timeout）→ 吃 authenticator 預設的 8 秒；當月有截斷名要併時
--   （那次 2 個：林皇→林皇君、劉子→劉子健）要跑 8.5～12 秒 → 被砍、整個交易 rollback。
--   沒名字要併時會提早 return，所以平常是 200——真的需要清洗的月份反而清不到，
--   腳本還照樣往下用沒清的資料算法官端彙總。
--
-- EXPLAIN（2026-10-02 直連；judge_month_stats 63 萬列／heap 519 MB，
--          lawyer_judge_pairs 223 萬列／heap 301 MB）：
--   a) 建 _trunc_map 的兩句 SELECT 各全表掃一次 judge_month_stats：實跑 2,956 ms＋3,652 ms，
--      幾乎全是磁碟讀。這 6.6 秒是「沒名字要併」也要付的，平常路徑本來就貼著 8 秒上限。
--   b) UPDATE lawyer_judge_pairs … FROM _trunc_map：Hash Join＋Seq Scan 全表。不是缺索引
--      （idx_ljp_judge 在），是暫存表沒有統計、planner 當它有 650 列；ANALYZE 之後改走
--      Nested Loop＋Bitmap Index Scan(idx_ljp_judge)，估計成本 141,432 → 6,486。
--   c) judge_month_stats／judge_month_jcase 兩句 DELETE 本來就走索引。
--
-- 修法與取捨：
--   1. 函數加 SET statement_timeout。寫在 CREATE 裡而不是另下 ALTER：CREATE OR REPLACE 不帶
--      SET 會把 proconfig 清掉，寫在一起以後照抄重寫才不會弄丟。PostgREST 會把函數層的
--      SET statement_timeout 提升成交易層設定（mig 237 附記），所以這行對 RPC 有效。
--   2. _trunc_map 建完後 ANALYZE（一行）→ (b) 不再全表掃。不另加 (judge_name, court_name)
--      索引：現有單欄索引已夠用（一個截斷名只對到個位數～數十列 pair），223 萬列的表多一個
--      索引要多佔數十 MB、每月上傳多一份寫入成本，換不到東西。
--   3. 部分索引 idx_jms_trunc_candidates（只收兩字名與「法」結尾名：9,665 列／104 kB）→
--      (a) 兩句改走 Index Only Scan（2,956 → 8～296 ms、3,652 → 5 ms，後者為冷讀）。
--      沒有它也不會壞（有 1. 保護），但那 6.6 秒每月必付，DB 忙時就是它把函數推過 8 秒；
--      索引只有 104 kB、每月新增數十列，維護成本可忽略。
--      ⚠️ planner 要能證明函數內兩句候選條件蘊含索引謂詞才會用它；改函數的候選條件時
--      要同步改索引謂詞，否則退回全表掃（結果仍正確，只是變慢）。
--   預演（子交易內造 1 個假截斷名、以 service_role 呼叫、跑完 RAISE 回滾，零殘留）：
--      現行版 8,503 ms → 新版 20 ms；沒有截斷名的提早 return 路徑 14 ms；
--      併入結果（月表累加、jcase 併列、pair 改名）逐項核對正確。
--
-- 同類地雷：refresh 鏈另有 5 支函數的 proconfig 也是空的，同樣只靠 8 秒內跑完
--   （refresh_judge_changes／refresh_judge_change_inferred_transfers 各要全掃一次
--   judge_month_stats，單掃實測 3.0～3.7 秒）。預防性補上 SET statement_timeout，純 metadata。
--   ⚠️ 之後用 CREATE OR REPLACE 重寫這幾支時要把 SET 帶上，不然又回到 8 秒。
--
-- rollup 完成標記：三支律師 rollup 走 RPC 會被閘道先回 504，函數其實在伺服器端跑完。
--   judgment_stats.py 的 refresh_stats() 改成「看表上的 refreshed_at 有沒有換新」來確認完成
--   （TRUNCATE＋INSERT 在同一個交易，新值看得到＝整支函數已 commit）。
--   lawyer_judgment_stats 本來就有；lawyer_region_year_stats、lawyer_cause_stats 在這裡補欄位
--   （函數的 INSERT 都帶欄位清單，新欄走 DEFAULT now()，函數不必改）。
--   ADD COLUMN … DEFAULT now() 不重寫表（既有列一律顯示為本次 ALTER 的時間）。

BEGIN;
SET LOCAL lock_timeout = '10s';  -- 拿不到鎖就整檔失敗重來，不要卡住前端讀取

-- ── 1) 清洗函數候選名的部分索引 ──
CREATE INDEX IF NOT EXISTS idx_jms_trunc_candidates
  ON judge_month_stats (name, court_name)
  WHERE char_length(name) = 2 OR name ~ '法$';

-- ── 2) clean_judge_name_truncations：加 SET statement_timeout＋ANALYZE _trunc_map ──
--     其餘內容與 mig 135 完全相同
CREATE OR REPLACE FUNCTION clean_judge_name_truncations() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout TO '300s'
AS $$
DECLARE
  n_map int;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _trunc_map (
    short_name text, court_name text, full_name text) ON COMMIT DROP;
  TRUNCATE _trunc_map;

  -- 規則1：折行截斷（兩字名＋不在名冊＋同院唯一前綴展開，mig 134）
  INSERT INTO _trunc_map
  SELECT m.name, m.court_name, min(j.name)
  FROM (SELECT DISTINCT name, court_name FROM judge_month_stats
        WHERE char_length(name) = 2) m
  JOIN jy_judges j
    ON j.court_name = m.court_name
   AND char_length(j.name) >= 3
   AND left(j.name, 2) = m.name
  WHERE NOT EXISTS (SELECT 1 FROM jy_judges r WHERE r.name = m.name)
  GROUP BY m.name, m.court_name
  HAVING count(DISTINCT j.name) = 1;

  -- 規則2：「法」黏字去尾（去尾後須為同院名冊真名；名冊 0 個「法」結尾真名不誤傷）
  INSERT INTO _trunc_map
  SELECT m.name, m.court_name, left(m.name, char_length(m.name) - 1)
  FROM (SELECT DISTINCT name, court_name FROM judge_month_stats
        WHERE name ~ '法$' AND char_length(name) IN (3, 4)) m
  WHERE NOT EXISTS (SELECT 1 FROM jy_judges r WHERE r.name = m.name)
    AND EXISTS (SELECT 1 FROM jy_judges j
                WHERE j.name = left(m.name, char_length(m.name) - 1)
                  AND j.court_name = m.court_name)
    AND NOT EXISTS (SELECT 1 FROM _trunc_map t
                    WHERE t.short_name = m.name AND t.court_name = m.court_name);

  SELECT count(*) INTO n_map FROM _trunc_map;
  IF n_map = 0 THEN RETURN 0; END IF;

  -- 暫存表沒有統計時 planner 當它有數百列，下面 lawyer_judge_pairs 那句會選
  -- Hash Join＋全表掃（mig 238 實測）；ANALYZE 後才知道只有幾列、改走 idx_ljp_judge
  ANALYZE _trunc_map;

  -- judge_month_stats：刪壞名列 → 併入本尊列（累加所有計數欄）
  WITH del AS (
    DELETE FROM judge_month_stats m
    USING _trunc_map t
    WHERE m.name = t.short_name AND m.court_name = t.court_name
    RETURNING t.full_name AS name, m.court_name, m.yyyymm,
              m.case_count, m.sum_days, m.n_days, m.cats, m.causes, m.doctypes
  ), agg AS (
    SELECT name, court_name, yyyymm,
           sum(case_count)::int AS cc, sum(sum_days)::bigint AS sd,
           sum(n_days)::int AS nd, jsonb_sum_counts(cats) AS cats,
           jsonb_sum_counts(causes) AS causes, jsonb_sum_counts(doctypes) AS doctypes
    FROM del GROUP BY name, court_name, yyyymm
  )
  INSERT INTO judge_month_stats
    (name, court_name, yyyymm, case_count, sum_days, n_days, cats, causes, doctypes)
  SELECT name, court_name, yyyymm, cc, sd, nd, cats, causes, doctypes FROM agg
  ON CONFLICT (name, court_name, yyyymm) DO UPDATE SET
    case_count = judge_month_stats.case_count + EXCLUDED.case_count,
    sum_days   = judge_month_stats.sum_days   + EXCLUDED.sum_days,
    n_days     = judge_month_stats.n_days     + EXCLUDED.n_days,
    cats       = jsonb_add_counts(judge_month_stats.cats,     EXCLUDED.cats),
    causes     = jsonb_add_counts(judge_month_stats.causes,   EXCLUDED.causes),
    doctypes   = jsonb_add_counts(judge_month_stats.doctypes, EXCLUDED.doctypes);

  -- judge_month_jcase：同法併入（PK 含 jcase）
  WITH del AS (
    DELETE FROM judge_month_jcase m
    USING _trunc_map t
    WHERE m.name = t.short_name AND m.court_name = t.court_name
    RETURNING t.full_name AS name, m.court_name, m.yyyymm, m.jcase, m.n
  ), agg AS (
    SELECT name, court_name, yyyymm, jcase, sum(n)::int AS n
    FROM del GROUP BY name, court_name, yyyymm, jcase
  )
  INSERT INTO judge_month_jcase (name, court_name, yyyymm, jcase, n)
  SELECT name, court_name, yyyymm, jcase, n FROM agg
  ON CONFLICT (name, court_name, yyyymm, jcase) DO UPDATE SET
    n = judge_month_jcase.n + EXCLUDED.n;

  -- lawyer_judge_pairs：無唯一鍵，直接改名（查詢端 RPC 走加總，重複列無害）
  UPDATE lawyer_judge_pairs p
  SET judge_name = t.full_name
  FROM _trunc_map t
  WHERE p.judge_name = t.short_name AND p.court_name = t.court_name;

  RETURN n_map;
END;
$$;

-- ── 3) refresh 鏈其餘沒有 SET statement_timeout 的函數 ──
ALTER FUNCTION refresh_prosecutor_stats()                              SET statement_timeout = '600s';
ALTER FUNCTION refresh_judge_changes(int, int, int)                    SET statement_timeout = '600s';
ALTER FUNCTION refresh_judge_change_transfers(int)                     SET statement_timeout = '600s';
ALTER FUNCTION refresh_judge_change_inferred_transfers(int, int, int)  SET statement_timeout = '600s';
ALTER FUNCTION refresh_judge_change_confidence_flag()                  SET statement_timeout = '600s';

-- ── 4) rollup 完成標記欄 ──
ALTER TABLE lawyer_region_year_stats ADD COLUMN IF NOT EXISTS refreshed_at timestamptz DEFAULT now();
ALTER TABLE lawyer_cause_stats       ADD COLUMN IF NOT EXISTS refreshed_at timestamptz DEFAULT now();

COMMIT;

-- 新欄位與新的 statement_timeout 都讀自 PostgREST 的 schema cache，馬上重載
NOTIFY pgrst, 'reload schema';
