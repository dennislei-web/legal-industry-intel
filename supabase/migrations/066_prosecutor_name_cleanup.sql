-- 066: 檢察官姓名抽取雜訊清洗 + 「累計具名人數」改門檻估計
-- 問題：judgment_stats.py 的檢察官姓名 regex 允許 \s 跨換行，當事人欄「…檢察署檢察官」
-- 不具名時會把下一行「被　告　○○」抓成姓名；動作式也會收進「蒞庭表示」「接獲線報」等片語。
-- 359 個資料月累計出 17,752 個 distinct「姓名」，其中 9,838 個只出現 1 件（幾乎全是雜訊），
-- 官方現職僅 1,460 人。ETL regex 已同步修正（禁跨行＋擴充停用字），本檔清歷史資料。
--
-- 1) 刪可辨識假名列：17,455 列 / 21,904 件（僅佔總案件 0.75%，不影響案件量統計）
-- 2) prosecutor_active_summary().names_total 改為「跨 >=12 個資料月具名」門檻估計
--    （實測 2,646 人，符合現職 1,460 + 30 年離退調動的合理累計量）
-- 3) 套用後需呼叫 refresh_prosecutor_stats() 重建彙總表

DELETE FROM prosecutor_month_stats
WHERE name ~ '被告|蒞庭|法官|檢察|書記|公訴|自訴|上訴|抗告|判決|裁定|起訴|到庭|職務|通知|傳喚|移送|解送|線報|同上|前揭|中華|口|○|◯';

CREATE OR REPLACE FUNCTION prosecutor_active_summary()
RETURNS TABLE (latest_ym text, active_latest bigint, active_12m bigint, names_total bigint) AS $$
  WITH latest AS (SELECT max(yyyymm) AS m FROM prosecutor_month_stats),
  recent AS (
    SELECT DISTINCT yyyymm FROM prosecutor_month_stats ORDER BY yyyymm DESC LIMIT 12
  ),
  -- 累計人數門檻：跨 12 個以上資料月才算真人（單月/零星出現多為殘餘抽取雜訊，
  -- 如誤抓的被告姓名；真檢察官在 30 年資料窗內幾乎必然跨多年具名）
  cumulative AS (
    SELECT count(*) AS n FROM (
      SELECT name FROM prosecutor_month_stats
      GROUP BY name HAVING count(DISTINCT yyyymm) >= 12
    ) t
  )
  SELECT (SELECT m FROM latest),
         count(DISTINCT name) FILTER (WHERE yyyymm = (SELECT m FROM latest)),
         count(DISTINCT name) FILTER (WHERE yyyymm IN (SELECT yyyymm FROM recent)),
         (SELECT n FROM cumulative)
  FROM prosecutor_month_stats;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION prosecutor_active_summary() TO anon, authenticated;
