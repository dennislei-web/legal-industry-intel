-- 一人所推定所長 v2（取代 mig 060）：新增「登記名稱＝本人姓名（＋律師）」的個人執業者
-- 例：黃乃芙 登記於「黃乃芙律師」、黃賽月 登記於「黃賽月」→ 視同一人所所長（2026-07-23 盤點共 60 位）
-- 企業/機關登錄（office 不含事務所且非本人姓名，1,391 筆）維持排除，避免企業法務被誤標
-- 註：溫三郎（登記「温三郎律師」異體字不相等）刻意不硬修，維持不標
CREATE OR REPLACE VIEW moj_solo_firm_lawyers AS
SELECT
  coalesce(substring(office_normalized FROM '^.+?(?:法律|律師)事務所'), office_normalized) AS firm_key,
  min(name) AS name,
  min(office_normalized) AS firm_name
FROM moj_lawyers
WHERE office_normalized LIKE '%事務所%'
   OR office_normalized IN (name, name || '律師')
GROUP BY 1
HAVING count(*) = 1 AND min(state_desc) = '正常';
