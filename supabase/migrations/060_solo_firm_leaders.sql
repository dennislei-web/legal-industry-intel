-- 一人所自動推定所長：名稱含「事務所」且（分所合併後）全所僅 1 位、狀態「正常」的律師
-- 系統一律視同所長，前端所有 👑 顯示點共用此 view（人工 FIRM_LEADERS 白名單優先）
-- firm_key 口徑對齊前端 offices tab 的 firmKeyRe：^(.+?(法律|律師)事務所)，不含此 pattern 者用全名
CREATE OR REPLACE VIEW moj_solo_firm_lawyers AS
SELECT
  coalesce(substring(office_normalized FROM '^.+?(?:法律|律師)事務所'), office_normalized) AS firm_key,
  min(name) AS name,
  min(office_normalized) AS firm_name
FROM moj_lawyers
WHERE office_normalized LIKE '%事務所%'
GROUP BY 1
HAVING count(*) = 1 AND min(state_desc) = '正常';
