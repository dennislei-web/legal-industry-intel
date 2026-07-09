-- 政府標案：事務所層彙總 view（前端列表徽章 + modal 摘要用）
-- firm_key 口徑對齊前端 firmKeyRe：截到第一個「事務所」合併分所（建業高雄所→建業）
-- security_invoker：沿用底層 gov_tender* 的 RLS（authenticated 才可讀）
CREATE OR REPLACE VIEW gov_firm_stats
WITH (security_invoker = true) AS
SELECT
  coalesce(substring(f.firm_name FROM '^.+?事務所'), f.firm_name) AS firm_key,
  count(*) FILTER (WHERE f.is_winner)                                   AS wins,
  sum(f.award_amount) FILTER (WHERE f.is_winner)                        AS total_amount,
  count(*) FILTER (WHERE f.is_winner AND t.award_year >= extract(year FROM now())::int - 4) AS wins_5y,
  sum(f.award_amount) FILTER (WHERE f.is_winner AND t.award_year >= extract(year FROM now())::int - 4) AS amount_5y,
  count(*)                                                              AS bids,
  max(t.award_year) FILTER (WHERE f.is_winner)                          AS last_win_year
FROM gov_tender_firms f
JOIN gov_tenders t USING (tender_key)
GROUP BY 1;
