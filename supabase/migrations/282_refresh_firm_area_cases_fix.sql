-- ============================================================
-- 282: refresh_firm_area_cases 兩個問題（2026-11-11 安全盤點時發現）
-- ============================================================
-- 1. mig 279 只 REVOKE anon／authenticated，沒收 PUBLIC 的預設執行權 → 拿公開金鑰（未登入）就能呼叫。
--    不會外洩資料（只回列數），但任何人都能觸發重算。改成只有 service_role 能跑。
-- 2. 函數裡的 DELETE 沒有 WHERE，經 PostgREST 呼叫會被 pg-safeupdate 擋（21000），
--    每月排程（extract-site-facts.yml）會失敗。mig 279 當時是用 SQL 直接跑所以沒發現。
-- ============================================================

CREATE OR REPLACE FUNCTION refresh_firm_area_cases()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET statement_timeout = '300s'
AS $$
DECLARE n integer;
BEGIN
  CREATE TEMP TABLE _fac ON COMMIT DROP AS
  WITH lawyer_firm AS (            -- 律師 → 事務所（同名多人者不計）
    SELECT name, MIN(firm_name) AS firm_name
    FROM lawyer_cause_court_stats
    WHERE firm_name IS NOT NULL AND firm_name <> '' AND NOT COALESCE(firm_ambiguous, false)
    GROUP BY name HAVING COUNT(DISTINCT firm_name) = 1
  ),
  cat AS (SELECT cause_group, MIN(cat) AS cat FROM cause_group_causes GROUP BY cause_group),
  la AS (
    SELECT s.name, cause_to_site_area(c.cat, s.cause_group, s.sub_group) AS area, SUM(s.cases) AS cases
    FROM lawyer_court_cause_year_stats s
    LEFT JOIN cat c ON c.cause_group = s.cause_group
    GROUP BY 1, 2
  )
  SELECT lf.firm_name, la.area, SUM(la.cases)::int AS cases, COUNT(*)::int AS lawyers
  FROM la JOIN lawyer_firm lf ON lf.name = la.name
  WHERE la.cases > 0
  GROUP BY 1, 2;

  -- 小表、先算好再換，鎖表時間極短（不要在這裡做長時間 TRUNCATE，PostgREST 會整站 503）
  DELETE FROM firm_area_cases WHERE true;   -- 經 PostgREST 呼叫時 pg-safeupdate 會擋沒有 WHERE 的 DELETE
  INSERT INTO firm_area_cases (firm_name, area, cases, lawyers) SELECT * FROM _fac;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION refresh_firm_area_cases() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION refresh_firm_area_cases() TO service_role;
