-- 專業法庭泛化（家事法官頁 → 專業法庭頁）：參數化 RPC 取代 family_* 專用版
-- 兩種模式：
--   案類模式：p_cat = cats JSONB 鍵（家事/刑事/民事/行政/少年），p_court_like 留 NULL
--   法院模式：p_cat = NULL、p_court_like = '智慧財產%'（智商法院含改制前智慧財產法院），
--             全部案件都算該類（cat_cases = case_count）
-- 過濾與門檻沿用 mig 119（未知法院/姓名雜訊/最低 3 件）；口徑沿用 mig 040（2020-01 起）。
-- family_judge_stats / family_cases_by_year 保留不動（避免破壞既有呼叫端），前端改用本版。

CREATE OR REPLACE FUNCTION cat_judge_stats(p_cat text DEFAULT NULL, p_court_like text DEFAULT NULL)
RETURNS TABLE (name text, court_name text, total_cases bigint, cat_cases bigint,
               cat_share numeric, avg_days numeric, first_ym text, last_ym text) AS $$
  SELECT name, court_name,
         sum(case_count)::bigint,
         sum(CASE WHEN p_cat IS NULL THEN case_count
                  ELSE coalesce((cats->>p_cat)::int, 0) END)::bigint,
         round(sum(CASE WHEN p_cat IS NULL THEN case_count
                        ELSE coalesce((cats->>p_cat)::int, 0) END)::numeric
               / nullif(sum(case_count), 0), 3),
         round(sum(sum_days)::numeric / nullif(sum(n_days), 0), 0),
         min(yyyymm), max(yyyymm)
  FROM judge_month_stats
  WHERE yyyymm >= '202001'
    AND court_name <> '未知法院'
    AND char_length(name) >= 2
    AND name NOT LIKE '%法官%'
    AND (p_court_like IS NULL OR court_name LIKE p_court_like)
  GROUP BY 1, 2
  HAVING sum(CASE WHEN p_cat IS NULL THEN case_count
                  ELSE coalesce((cats->>p_cat)::int, 0) END) >= 3;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cat_judge_stats(text, text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION cat_judge_stats(text, text) TO anon, authenticated;

-- 年度序列：ok_months 判別「該類分類已完成回填的月份」。
-- 家事因 2020 重分類回填期歷史偏低才需要（月 >= 300 件判別，沿用 mig 030）；
-- 其他類別自始分類即正確，p_ok_min 傳 0（ok_months = months）。
-- 平均結案天數＝該月該類佔比 >= 0.8 的法官月估算（專責法官近似值，同 mig 030 手法）。
CREATE OR REPLACE FUNCTION cat_cases_by_year(p_cat text DEFAULT NULL, p_court_like text DEFAULT NULL,
                                             p_ok_min int DEFAULT 0)
RETURNS TABLE (year text, cat_cases bigint, total_cases bigint,
               months int, ok_months int, cat_avg_days numeric) AS $$
  WITH m AS (
    SELECT yyyymm,
           sum(CASE WHEN p_cat IS NULL THEN case_count
                    ELSE coalesce((cats->>p_cat)::int, 0) END) AS cc,
           sum(case_count) AS tot,
           sum(sum_days) FILTER (WHERE p_cat IS NULL
               OR coalesce((cats->>p_cat)::int, 0)::numeric / nullif(case_count, 0) >= 0.8) AS sd,
           sum(n_days) FILTER (WHERE p_cat IS NULL
               OR coalesce((cats->>p_cat)::int, 0)::numeric / nullif(case_count, 0) >= 0.8) AS nd
    FROM judge_month_stats
    WHERE yyyymm >= '202001'
      AND (p_court_like IS NULL OR court_name LIKE p_court_like)
    GROUP BY yyyymm
  )
  SELECT left(yyyymm, 4),
         sum(cc)::bigint,
         sum(tot)::bigint,
         count(*)::int,
         (count(*) FILTER (WHERE cc >= p_ok_min))::int,
         round(sum(sd)::numeric / nullif(sum(nd), 0), 0)
  FROM m
  GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cat_cases_by_year(text, text, int) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION cat_cases_by_year(text, text, int) TO anon, authenticated;
