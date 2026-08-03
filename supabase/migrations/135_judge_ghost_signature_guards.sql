-- 135: 幽靈署名防呆（附件原審誤抓 + 「法」黏字）
-- 問題一（附件誤抓）：上訴審判決常在結尾附「原審判決全文」，附件超過 3000 字時
--   extract_judges 舊版尾窗會抓到附件裡的原審署名 → 原審地院法官被記到上訴審法院
--   1-2 件 → refresh_judge_changes 產生幽靈進場列 → mig 089 推定轉調誤判整排
--   「地院→高院 異動」（例：張議/林容/鄭雅云 2026-04/05）。ETL 已改「日期列錨定
--   第一個署名區」根治新資料；歷史 1-2 件幽靈列無法與真支援/借調區分，不動源表，
--   改在事件層加 min_cases 門檻：進退場事件要求該 (法官,法院) 累計 >= 5 件（幽靈累計 1-3 件、偶有多次上訴達 4 件；真進退場累計數十件起跳）。
--   真進場/轉調法官首月就數十件，1-2 件幽靈與零星借調不成立事件，不受影響。
-- 問題二（法黏字）：下一位法官的「法 官」label 折行、「法」黏到前一位名尾
--   （楊佳祥法/蔡名曜法/周賢法，全 DB 僅 3 筆各 1 件）。現任名冊 0 個「法」結尾
--   真名。ETL 已加 4 字去尾；DB 清洗規則併入 clean_judge_name_truncations()。
-- 套用後需執行 clean_judge_name_truncations() + 全 refresh 鏈。

-- ── 1) refresh_judge_changes 加 min_cases（簽章變更需先 DROP 舊版避免 overload）──
DROP FUNCTION IF EXISTS refresh_judge_changes(int, int);
CREATE OR REPLACE FUNCTION refresh_judge_changes(
  appear_window int DEFAULT 24,
  leave_buffer  int DEFAULT 6,
  min_cases     int DEFAULT 5
) RETURNS int AS $$
DECLARE
  n int;
  max_m text;
  appear_thr text;
  leave_thr text;
BEGIN
  SELECT max(yyyymm) INTO max_m FROM judge_month_stats;
  appear_thr := to_char(to_date(max_m, 'YYYYMM') - (appear_window || ' months')::interval, 'YYYYMM');
  leave_thr  := to_char(to_date(max_m, 'YYYYMM') - (leave_buffer  || ' months')::interval, 'YYYYMM');

  TRUNCATE judge_changes RESTART IDENTITY;

  WITH agg AS (
    SELECT name, court_name,
           min(yyyymm) AS first_seen,
           max(yyyymm) AS last_seen,
           count(*)    AS active_months,
           sum(case_count) AS case_count
    FROM judge_month_stats
    -- 濾掉裁判書署名解析的雜訊：職稱詞/程序用語/OCR 黏連/不詳（現任名冊全為 2~4 字，此界不誤傷真人）
    WHERE name !~ '(法官|審判長|書記|事務官|庭長|通譯|檢察|不詳|陪席|受命|附表|附錄|主文|見上|年籍|署名|附件|轉載|上訴|抗告|原告|被告|聲請|宣示|以上)'
      AND char_length(name) BETWEEN 2 AND 4
      AND court_name <> '未知法院'   -- 治標：法院未辨識記錄（源表 court 抽取失敗 fallback，約3%）不列入異動；治本＝上游 JID 回推法院後自動恢復
    GROUP BY name, court_name
  ),
  roster AS (SELECT DISTINCT name, court_name FROM jy_judges)
  INSERT INTO judge_changes
    (name, court_name, change_type, event_month, active_months, case_count, in_current_roster, confidence)
  -- 進場：近期首見（yyyymm 為 6 位定長字串，字典序＝時間序，可直接比較）
  SELECT a.name, a.court_name, 'appear', a.first_seen, a.active_months, a.case_count,
         (r.name IS NOT NULL),
         CASE WHEN r.name IS NOT NULL THEN 'confirmed' ELSE 'suspected' END
  FROM agg a LEFT JOIN roster r USING (name, court_name)
  WHERE a.first_seen >= appear_thr
    AND a.case_count >= min_cases
  UNION ALL
  -- 退場：末見月早於緩衝線。仍在現任名冊 → 疑似（可能久未掛名而非真離開）
  SELECT a.name, a.court_name, 'leave', a.last_seen, a.active_months, a.case_count,
         (r.name IS NOT NULL),
         CASE WHEN r.name IS NOT NULL THEN 'suspected' ELSE 'confirmed' END
  FROM agg a LEFT JOIN roster r USING (name, court_name)
  WHERE a.last_seen <= leave_thr
    AND a.case_count >= min_cases;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 2) clean_judge_name_truncations 擴充：加「法」黏字去尾規則 ──
CREATE OR REPLACE FUNCTION clean_judge_name_truncations() RETURNS int AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;
