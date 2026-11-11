-- ============================================================
-- 279: 各所各領域實際出庭案量（給「官網說的 vs 裁判書做的」交叉分析）
-- ============================================================
-- 把裁判書案由群組／子群組對到官網抽取用的領域分類（firm_site_facts.focus_areas 同一套名稱），
-- 彙總成 事務所 × 領域 的近五年案量。
--
-- 來源：lawyer_court_cause_year_stats（律師 × 法院 × 案由群組 × 子群組 × 年）
-- 律師歸所：沿用 lawyer_cause_court_stats 的 firm_name（firm_ambiguous＝同名多人，不計）
--
-- 對不到官網領域的（未標明類型的損害賠償、買賣、不當得利、一般契約給付…）歸「一般民事」。
-- 注意：裁判書只看得到訴訟。公司商務／智慧財產／金融／稅務的顧問、申請、交易類工作不會出現，
--   這幾個領域「官網主打但案量少」不代表沒在做。
-- ============================================================

CREATE TABLE IF NOT EXISTS firm_area_cases (
  firm_name    TEXT NOT NULL,
  area         TEXT NOT NULL,
  cases        INTEGER NOT NULL,
  lawyers      INTEGER NOT NULL,      -- 該所在這個領域有案量的律師數
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (firm_name, area)
);
ALTER TABLE firm_area_cases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS firm_area_cases_admin_read ON firm_area_cases;
CREATE POLICY firm_area_cases_admin_read ON firm_area_cases
  FOR SELECT TO authenticated USING (public.is_intel_admin());
REVOKE ALL ON firm_area_cases FROM anon;
GRANT SELECT ON firm_area_cases TO authenticated;

CREATE OR REPLACE FUNCTION cause_to_site_area(p_cat text, p_group text, p_sub text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    -- 刑事裡可對到專門領域的先拆出來
    WHEN p_group = '證券金融犯罪' THEN '金融證券'
    WHEN p_group = '智財刑事' THEN '智慧財產'
    WHEN p_group IN ('個資', '妨害電腦使用') THEN '科技個資'
    WHEN p_group IN ('過失傷害', '過失致死') THEN '車禍交通'
    WHEN p_group IN ('妨害性自主', '性剝削兒少', '跟蹤騷擾') THEN '性平'
    WHEN p_group = '其他刑事' AND p_sub LIKE '性騷擾%' THEN '性平'
    WHEN p_group = '稅捐' THEN '稅務'
    WHEN p_cat = '刑事' THEN '刑事'
    WHEN p_cat = '家事' THEN '家事'
    -- 民事
    WHEN p_group = '損害賠償' AND p_sub = '交通事故' THEN '車禍交通'
    WHEN p_group = '損害賠償' AND p_sub = '醫療糾紛' THEN '醫療'
    WHEN p_group = '損害賠償' AND p_sub = '智慧財產' THEN '智慧財產'
    WHEN p_group = '損害賠償' AND p_sub = '侵害配偶權' THEN '家事'
    WHEN p_group = '損害賠償' AND p_sub = '國家賠償' THEN '行政'
    WHEN p_group = '特別法' AND p_sub LIKE '勞動%' THEN '勞動'
    WHEN p_group = '特別法' AND p_sub LIKE '票據%' THEN '債務執行'
    WHEN p_group = '特別法' AND p_sub LIKE '智慧財產%' THEN '智慧財產'
    WHEN p_group = '特別法' AND p_sub LIKE '公司與證券%' THEN '公司商務'
    WHEN p_group = '特別法' AND p_sub = '國家賠償' THEN '行政'
    WHEN p_group = '特別法' AND p_sub = '保險' THEN '消費保險'
    WHEN p_group = '特別法' AND p_sub = '公寓大廈' THEN '不動產'
    WHEN p_group = '僱傭' THEN '勞動'
    WHEN p_group = '租賃' THEN '不動產'
    WHEN p_group = '承攬' THEN '工程'
    WHEN p_group = '借貸' THEN '債務執行'
    WHEN p_group = '合夥' THEN '公司商務'
    WHEN p_group = '委任' AND p_sub LIKE '董事%' THEN '公司商務'
    WHEN p_group = '其他民法' AND p_sub LIKE '消費者債務清理%' THEN '債務執行'
    WHEN p_group = '其他民法' AND (p_sub LIKE '強制執行%' OR p_sub LIKE '確認債權%' OR p_sub LIKE '撤銷詐害%') THEN '債務執行'
    WHEN p_group = '其他民法' AND (p_sub LIKE '拆屋還地%' OR p_sub LIKE '不動產權利%' OR p_sub LIKE '共有物分割%' OR p_sub LIKE '通行權%') THEN '不動產'
    WHEN p_group = '其他民法' AND p_sub LIKE '法人、商業%' THEN '公司商務'
    WHEN p_group = '其他民法' AND p_sub LIKE '家事與繼承%' THEN '家事'
    -- 行政
    WHEN p_cat = '行政' AND p_sub LIKE '租稅%' THEN '稅務'
    WHEN p_cat = '行政' AND p_sub LIKE '智慧財產行政%' THEN '智慧財產'
    WHEN p_cat = '行政' THEN '行政'
    WHEN p_cat = '民事' THEN '一般民事'
    ELSE '其他'
  END
$$;

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
  DELETE FROM firm_area_cases;
  INSERT INTO firm_area_cases (firm_name, area, cases, lawyers) SELECT * FROM _fac;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION refresh_firm_area_cases() FROM anon, authenticated;
