-- 政府標案 → 個別律師歸戶 view（律師 modal「政府標案」區塊用）
-- 兩條歸戶路徑：
--   1) 一人所：投標名稱截 firm_key（同 mig 060 口徑）對上 moj_solo_firm_lawyers
--   2) 個人律師名義投標（「王大明律師」）：去掉尾綴「律師」即姓名
-- 口徑限制：姓名歸戶，同名律師會合併（前端註記）；多人所案件無法歸到individual律師
CREATE OR REPLACE VIEW gov_lawyer_tenders
WITH (security_invoker = true) AS
SELECT
  s.name AS lawyer_name,
  f.firm_name AS vendor_name,
  '一人所' AS via,
  f.tender_key, f.is_winner, f.award_amount,
  t.title, t.unit_name, t.award_year, t.award_date
FROM gov_tender_firms f
JOIN gov_tenders t USING (tender_key)
JOIN moj_solo_firm_lawyers s
  ON s.firm_key = coalesce(substring(f.firm_name FROM '^.+?(?:法律|律師)事務所'), f.firm_name)
UNION ALL
SELECT
  regexp_replace(f.firm_name, '律師$', '') AS lawyer_name,
  f.firm_name AS vendor_name,
  '個人名義' AS via,
  f.tender_key, f.is_winner, f.award_amount,
  t.title, t.unit_name, t.award_year, t.award_date
FROM gov_tender_firms f
JOIN gov_tenders t USING (tender_key)
WHERE f.firm_name ~ '律師$' AND f.firm_name NOT LIKE '%事務所%';
