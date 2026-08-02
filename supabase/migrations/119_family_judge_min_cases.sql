-- 家事法官表清理：排除「未知法院」殘渣列＋加最低案量門檻
-- 背景：family_judge_stats() 原本 HAVING sum(家事) > 0，任何被歸到 1 件家事裁判的
-- (法官×法院) 組合都進表；配上前端預設「佔比 >= 50%」篩選，1/1=100% 的雜訊列
-- （法院抽取失敗 fallback 的「未知法院」、姓名解析壞字尾如「楊佳祥法」、職稱誤抓「法官」）
-- 反而排在真家事庭法官前面。
-- 修法比照家事律師端（040 的 family_lawyer_stats HAVING >= 3）：
--   1. 排除 court_name = '未知法院'（同 043 法官異動的處理；上游 JID 治本後此列自然消失）
--   2. HAVING sum(家事) >= 3
--   3. 濾姓名解析雜訊（單字名、含「法官」字樣）

CREATE OR REPLACE FUNCTION family_judge_stats()
RETURNS TABLE (name text, court_name text, total_cases bigint, family_cases bigint,
               family_share numeric, avg_days numeric, first_ym text, last_ym text) AS $$
  SELECT name, court_name,
         sum(case_count)::bigint,
         sum(coalesce((cats->>'家事')::int, 0))::bigint,
         round(sum(coalesce((cats->>'家事')::int, 0))::numeric / nullif(sum(case_count), 0), 3),
         round(sum(sum_days)::numeric / nullif(sum(n_days), 0), 0),
         min(yyyymm), max(yyyymm)
  FROM judge_month_stats
  WHERE yyyymm >= '202001'
    AND court_name <> '未知法院'
    AND char_length(name) >= 2
    AND name NOT LIKE '%法官%'
  GROUP BY 1, 2
  HAVING sum(coalesce((cats->>'家事')::int, 0)) >= 3;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION family_judge_stats() SET statement_timeout = '120s';
