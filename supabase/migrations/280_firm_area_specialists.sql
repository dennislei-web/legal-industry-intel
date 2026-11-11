-- ============================================================
-- 280: 依領域找實際專門所（事務所總覽「領域專門所」區塊用）
-- ============================================================
-- firm_area_cases 有 5 萬多列，前端不整張抓；這支 RPC 依領域回前 N 間。
-- 佔比分母＝該所「可歸類」案量（不含一般民事／其他／醫療：醫療案由對照沒對上）。
-- 只給管理員（競爭情報，與 firm_site_facts / firm_area_cases 同權限）。
-- ============================================================

CREATE OR REPLACE FUNCTION firm_area_specialists(
  p_area      text,
  p_sort      text    DEFAULT 'share',   -- share＝依佔比、cases＝依件數
  p_min_cases integer DEFAULT 30,
  p_limit     integer DEFAULT 60
)
RETURNS TABLE (
  firm_name    text,
  cases        integer,
  total_cases  integer,
  share        numeric,
  area_lawyers integer,     -- 該所在此領域有案量的律師數
  has_site     boolean,     -- 有官網且抽得出主打領域（抽不出主打的不算，免得誤判成「沒主打」）
  is_focus     boolean,     -- 官網主打此領域
  website_url  text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.is_intel_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH tot AS (
    SELECT c.firm_name AS fn, SUM(c.cases)::int AS total
    FROM firm_area_cases c
    WHERE c.area NOT IN ('一般民事', '其他', '醫療')
    GROUP BY c.firm_name
  )
  SELECT a.firm_name, a.cases, t.total,
         ROUND(a.cases::numeric * 100 / NULLIF(t.total, 0), 1),
         a.lawyers,
         COALESCE(cardinality(f.focus_areas) > 0, false),
         COALESCE(p_area = ANY (f.focus_areas), false),
         f.website_url
  FROM firm_area_cases a
  JOIN tot t ON t.fn = a.firm_name
  LEFT JOIN firm_site_facts f ON f.firm_name = a.firm_name
  WHERE a.area = p_area AND a.cases >= GREATEST(p_min_cases, 1)
    AND a.firm_name LIKE '%事務所%'          -- 排除掛在公司法人的企業內律師
  ORDER BY CASE WHEN p_sort = 'cases' THEN a.cases::numeric
                ELSE a.cases::numeric / NULLIF(t.total, 0) END DESC NULLS LAST,
           a.cases DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 200);
END $$;

REVOKE EXECUTE ON FUNCTION firm_area_specialists(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION firm_area_specialists(text, text, integer, integer) TO authenticated;
