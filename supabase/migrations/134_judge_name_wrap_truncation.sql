-- 134: 法官姓名「折行截斷」清洗（末字被排到下一行 → 姓名只剩前 2 字）
-- 問題：少數裁判書署名區排版壞掉，姓名末字折到下一行行首（例：新北地院
-- 114 侵附民 49，「審判長法 官 俞秀／美 …… 法 官 吳丁／偉 …… 法 官 簡方／毅」），
-- RE_JUDGE 要求姓名後接換行，延伸到末字時撞到下一行「法 官」label 回退，
-- 產生 1-2 件的幽靈兩字名（俞秀/吳丁/簡方/李東/李璧/洪毓/石家…），數月後
-- 被 refresh_judge_changes() 誤判「確認退場」。202511 退場 38 筆中 7 筆是此類。
-- 判定三條件（缺一不可，避免誤傷張議/方荳/林容/陳馥等 25 位名冊真兩字名）：
--   1. 兩字名，且該名不在現任名冊 jy_judges
--   2. 同院名冊存在「唯一」以它為前綴的 3+ 字法官（同名多院如李東益/李東柏靠同院鎖定）
--   3. 併入時同 (name,court,yyyymm) 已存在則累加（同 082 慣例）
-- 做成常設函式：ETL refresh_stats() 每月在 refresh_judge_* 之前呼叫，自我修復；
-- extract_judges 已同步加折行孤字接回規則（雙保險）。
-- 套用後需重跑 refresh_judge_judgment_stats() + refresh_judge_changes() +
-- refresh_judge_change_transfers() + refresh_judge_change_inferred_transfers() +
-- refresh_judge_change_confidence_flag()。

CREATE OR REPLACE FUNCTION clean_judge_name_truncations() RETURNS int AS $$
DECLARE
  n_map int;
BEGIN
  -- 對照表：短名 × 法院 → 同院唯一前綴展開的名冊全名
  CREATE TEMP TABLE IF NOT EXISTS _trunc_map (
    short_name text, court_name text, full_name text) ON COMMIT DROP;
  TRUNCATE _trunc_map;
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

  SELECT count(*) INTO n_map FROM _trunc_map;
  IF n_map = 0 THEN RETURN 0; END IF;

  -- judge_month_stats：刪短名列 → 併入全名列（累加所有計數欄）
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
$$ LANGUAGE plpgsql SECURITY DEFINER;
