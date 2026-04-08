-- ============================================================
-- 016: judges_combined view + RPCs
-- ============================================================

-- 法院名稱正規化函數
CREATE OR REPLACE FUNCTION normalize_court_name(raw_name TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN REPLACE(REPLACE(TRIM(COALESCE(raw_name, '')), '台灣', '臺灣'), '　', '');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ========== judges_combined view ==========
CREATE OR REPLACE VIEW judges_combined AS
WITH
jy AS (
  SELECT DISTINCT ON (name, normalize_court_name(court_name))
    id, name, normalize_court_name(court_name) AS court_name, court_id,
    division, rank, appointment_date, seniority_years, status, sex,
    updated_at
  FROM jy_judges
  ORDER BY name, normalize_court_name(court_name), updated_at DESC
),
ln AS (
  SELECT DISTINCT ON (name, normalize_court_name(court_name))
    id, lawsnote_id, name, normalize_court_name(court_name) AS court_name,
    case_count_total, case_count_by_year, case_type_distribution,
    avg_processing_days, verdict_stats, source_url,
    updated_at
  FROM lawsnote_judges
  ORDER BY name, normalize_court_name(court_name), updated_at DESC
)
SELECT
  COALESCE(jy.name, ln.name) AS name,
  COALESCE(jy.court_name, ln.court_name) AS court_name,
  jy.court_id,
  jy.division,
  jy.rank,
  jy.seniority_years,
  jy.status,
  jy.sex,
  ln.case_count_total,
  ln.case_count_by_year,
  ln.case_type_distribution,
  ln.avg_processing_days,
  ln.verdict_stats,
  ln.source_url AS lawsnote_url,
  (jy.id IS NOT NULL) AS has_jy,
  (ln.id IS NOT NULL) AS has_lawsnote,
  CASE
    WHEN jy.id IS NOT NULL AND ln.id IS NOT NULL THEN '司法院+Lawsnote'
    WHEN jy.id IS NOT NULL THEN '僅司法院'
    ELSE '僅Lawsnote'
  END AS data_source,
  jy.id AS jy_id,
  ln.id AS ln_id
FROM jy
FULL OUTER JOIN ln ON jy.name = ln.name AND jy.court_name = ln.court_name;

-- RLS on view (透過底層表的 RLS 控制)
GRANT SELECT ON judges_combined TO authenticated;

-- ========== RPCs ==========

-- 每法院法官數 + 平均案件量
CREATE OR REPLACE FUNCTION judge_court_statistics()
RETURNS TABLE (
  court_name TEXT,
  court_type TEXT,
  region TEXT,
  judge_count BIGINT,
  avg_case_count NUMERIC,
  avg_processing_days NUMERIC
)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    jc.court_name,
    c.court_type,
    c.region,
    COUNT(*)::BIGINT AS judge_count,
    ROUND(AVG(jc.case_count_total)::numeric, 0) AS avg_case_count,
    ROUND(AVG(jc.avg_processing_days)::numeric, 1) AS avg_processing_days
  FROM judges_combined jc
  LEFT JOIN courts c ON c.name = jc.court_name
  GROUP BY jc.court_name, c.court_type, c.region
  ORDER BY judge_count DESC;
$$;

GRANT EXECUTE ON FUNCTION judge_court_statistics() TO anon, authenticated;

-- 庭別分布
CREATE OR REPLACE FUNCTION judge_division_distribution()
RETURNS TABLE (
  division TEXT,
  count BIGINT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    COALESCE(division, '未知') AS division,
    COUNT(*)::BIGINT AS count
  FROM judges_combined
  GROUP BY division
  ORDER BY count DESC;
$$;

GRANT EXECUTE ON FUNCTION judge_division_distribution() TO anon, authenticated;

-- 資料來源登記
INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('司法院法官名冊', 'https://judicial.gov.tw/', '司法院法官資格查詢系統', 'judges', 'jy_judges', 'monthly'),
  ('Lawsnote 法官統計', 'https://page.lawsnote.com/', 'Lawsnote 法官頁面 - 案件數與統計', 'judges', 'lawsnote_judges', 'monthly')
ON CONFLICT (name) DO NOTHING;
