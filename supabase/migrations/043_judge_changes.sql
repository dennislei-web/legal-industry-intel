-- 法官異動追蹤：各法院署名法官的「進場 / 退場」推斷
-- 資料源：judge_month_stats（裁判書逐月署名，唯一有時間深度的法官資料）
-- 交叉：jy_judges 現任名冊 → 定 confidence（confirmed / suspected）
-- 註：法官無律師證號那種永久唯一鍵，且 33% 姓名跨 3+ 法院（同名污染），
--     故本表只做「單一法院進退場」，不做跨院轉調連連看。

CREATE TABLE IF NOT EXISTS judge_changes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  court_name text NOT NULL,
  change_type text NOT NULL CHECK (change_type IN ('appear', 'leave')),
  event_month text NOT NULL,          -- yyyymm：進場=首見月 / 退場=末見月
  active_months int,                  -- 該法官在該院累計活躍月數
  case_count int,                     -- 累計掛名判決數（份量指標；含合議庭掛名）
  in_current_roster boolean,          -- 是否在 jy_judges 現任名冊
  confidence text NOT NULL CHECK (confidence IN ('confirmed', 'suspected')),
  detected_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_judge_changes_event_month ON judge_changes (event_month DESC);
CREATE INDEX IF NOT EXISTS idx_judge_changes_court ON judge_changes (court_name);
CREATE INDEX IF NOT EXISTS idx_judge_changes_type ON judge_changes (change_type);

ALTER TABLE judge_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "authenticated_read_judge_changes" ON judge_changes;
CREATE POLICY "authenticated_read_judge_changes" ON judge_changes
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 冪等重算：TRUNCATE→INSERT，與 refresh_judge_judgment_stats() 同慣例。
-- appear_window：first_seen 落在資料末端往前 N 個月內 → 視為「近期新面孔」
-- leave_buffer ：last_seen 早於資料末端 M 個月 → 視為「已退場」（緩衝排除資料延遲誤判）
CREATE OR REPLACE FUNCTION refresh_judge_changes(
  appear_window int DEFAULT 24,
  leave_buffer  int DEFAULT 6
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
    -- 濾掉裁判書署名解析的雜訊：職稱詞/OCR 黏連/不詳（現任名冊全為 2~4 字，此界不誤傷真人）
    WHERE name !~ '(法官|審判長|書記|事務官|庭長|通譯|檢察|不詳|陪席|受命|附表|如主文|見上|年籍|署名|附件|轉載)'
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
  UNION ALL
  -- 退場：末見月早於緩衝線。仍在現任名冊 → 疑似（可能久未掛名而非真離開）
  SELECT a.name, a.court_name, 'leave', a.last_seen, a.active_months, a.case_count,
         (r.name IS NOT NULL),
         CASE WHEN r.name IS NOT NULL THEN 'suspected' ELSE 'confirmed' END
  FROM agg a LEFT JOIN roster r USING (name, court_name)
  WHERE a.last_seen <= leave_thr;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
