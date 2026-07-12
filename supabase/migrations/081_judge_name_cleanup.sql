-- 081: 法官姓名抽取雜訊清洗（比照 066 檢察官清洗三層法）
-- 問題：裁判書結尾「法 官」署名列後偶爾黏到程序用語——「不得上訴」「得抗告」
-- 「附錄法條」等被當成法官名；也有「鄭瑋附表」這類真名黏連（真名正常列另有計）。
-- 盤點源表共 34 個 distinct / ~660 列 / ~1,200 件（佔比極低，不影響案件量統計）。
-- 1) 刪 judge_month_stats 可辨識假名列（ETL extract_judges 已同步加姓名級停用字）
-- 2) refresh_judge_changes() 濾網 regex 補強（防歷史月包 reprocess 再帶進來）
-- 3) 套用後需呼叫 refresh_judge_judgment_stats() + refresh_judge_changes()

DELETE FROM judge_month_stats
WHERE name ~ '上訴|抗告|附表|附錄|主文|原告|被告|聲請|宣示|以上';

-- 與 043 相同，僅補強姓名雜訊 regex（如主文 → 主文，並加程序用語停用字）
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
