-- 093: 律師/事務所總覽頁排行 RPC
--   cause_top_lawyers：訴訟領域律師 TOP N（展開 lawyer_cause_stats.by_group，mig 070）
--   gov_top_lawyers：政府標案得標律師榜（彙總 gov_lawyer_tenders view，mig 078）
-- 口徑：cause_top_lawyers 僅公開裁判書＝下限、同名律師不歸戶（前端沿用 * 旗標慣例）；
--       gov_top_lawyers 姓名歸戶（一人所＋個人名義投標），同名會合併

CREATE OR REPLACE FUNCTION cause_top_lawyers(p_group text, p_limit int DEFAULT 10)
RETURNS TABLE (rank int, name text, cases int, total_5yr int, share numeric) AS $$
  SELECT row_number() OVER (ORDER BY (by_group->>p_group)::int DESC, name)::int,
         name,
         (by_group->>p_group)::int,
         cases_5yr,
         round((by_group->>p_group)::numeric / nullif(cases_5yr, 0), 4)
  FROM lawyer_cause_stats
  WHERE coalesce((by_group->>p_group)::int, 0) > 0
  ORDER BY (by_group->>p_group)::int DESC, name
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_top_lawyers(text, int) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION cause_top_lawyers(text, int) TO anon, authenticated;

CREATE OR REPLACE FUNCTION gov_top_lawyers(p_limit int DEFAULT 10)
RETURNS TABLE (name text, wins bigint, total_amount numeric, last_win_year int) AS $$
  SELECT lawyer_name,
         count(*) FILTER (WHERE is_winner),
         sum(award_amount) FILTER (WHERE is_winner),
         max(award_year) FILTER (WHERE is_winner)
  FROM gov_lawyer_tenders
  GROUP BY lawyer_name
  HAVING count(*) FILTER (WHERE is_winner) > 0
  ORDER BY 2 DESC, 3 DESC NULLS LAST
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_top_lawyers(int) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_top_lawyers(int) TO authenticated;
