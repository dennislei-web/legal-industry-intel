-- 094: gov_top_lawyers 加排序參數，供總覽卡「標數/金額」切換
--   p_sort = 'wins'（預設，得標件數）或 'amount'（已公開決標金額合計）
-- 換 signature 需先 DROP 舊版 (int)，避免 PostgREST 遇到 overload 撞名

DROP FUNCTION IF EXISTS gov_top_lawyers(int);

CREATE FUNCTION gov_top_lawyers(p_limit int DEFAULT 10, p_sort text DEFAULT 'wins')
RETURNS TABLE (name text, wins bigint, total_amount numeric, last_win_year int) AS $$
  SELECT lawyer_name,
         count(*) FILTER (WHERE is_winner),
         sum(award_amount) FILTER (WHERE is_winner),
         max(award_year) FILTER (WHERE is_winner)
  FROM gov_lawyer_tenders
  GROUP BY lawyer_name
  HAVING count(*) FILTER (WHERE is_winner) > 0
  ORDER BY
    CASE WHEN p_sort = 'amount'
         THEN sum(award_amount) FILTER (WHERE is_winner)
         ELSE (count(*) FILTER (WHERE is_winner))::numeric END DESC NULLS LAST,
    CASE WHEN p_sort = 'amount'
         THEN (count(*) FILTER (WHERE is_winner))::numeric
         ELSE sum(award_amount) FILTER (WHERE is_winner) END DESC NULLS LAST
  LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION gov_top_lawyers(int, text) SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_top_lawyers(int, text) TO authenticated;
