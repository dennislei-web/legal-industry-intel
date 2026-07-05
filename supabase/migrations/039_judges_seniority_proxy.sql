-- 年資 proxy：首次出現在裁判書的年份（1996 起全期回填後才有意義）
-- seniority_years = 官方名冊值優先，否則 now() 年 - 首判年（跨法院取同名最早）
-- 注意：1996 年前任職的法官會被截在 ~30 年（資料起點限制）

DROP VIEW IF EXISTS judges_combined;

CREATE VIEW judges_combined AS
WITH jy AS (
  SELECT DISTINCT ON (jy_judges.name, (normalize_court_name(jy_judges.court_name)))
    jy_judges.id, jy_judges.name,
    normalize_court_name(jy_judges.court_name) AS court_name,
    jy_judges.court_id, jy_judges.division, jy_judges.rank,
    jy_judges.appointment_date, jy_judges.seniority_years,
    jy_judges.status, jy_judges.sex, jy_judges.updated_at
  FROM jy_judges
  ORDER BY jy_judges.name, (normalize_court_name(jy_judges.court_name)), jy_judges.updated_at DESC
), ln AS (
  SELECT DISTINCT ON (lawsnote_judges.name, (normalize_court_name(lawsnote_judges.court_name)))
    lawsnote_judges.id, lawsnote_judges.lawsnote_id, lawsnote_judges.name,
    normalize_court_name(lawsnote_judges.court_name) AS court_name,
    lawsnote_judges.case_count_total, lawsnote_judges.case_count_by_year,
    lawsnote_judges.case_type_distribution, lawsnote_judges.avg_processing_days,
    lawsnote_judges.verdict_stats, lawsnote_judges.source_url, lawsnote_judges.updated_at
  FROM lawsnote_judges
  ORDER BY lawsnote_judges.name, (normalize_court_name(lawsnote_judges.court_name)), lawsnote_judges.updated_at DESC
), jd AS (
  SELECT s.name, normalize_court_name(s.court_name) AS court_name,
         s.case_count_total, s.case_count_by_year, s.case_type_distribution,
         s.avg_processing_days, s.first_yyyymm
  FROM judge_judgment_stats s
), fj AS (
  -- 同名法官跨法院的最早判決月（年資 proxy 來源）
  SELECT name, min(first_yyyymm) AS min_ym
  FROM judge_judgment_stats GROUP BY name
)
SELECT COALESCE(jy.name, ln.name) AS name,
  COALESCE(jy.court_name, ln.court_name) AS court_name,
  jy.court_id, jy.division, jy.rank,
  COALESCE(jy.seniority_years,
           (EXTRACT(year FROM now())::int - left(fj.min_ym, 4)::int)) AS seniority_years,
  jy.status, jy.sex,
  COALESCE(jd.case_count_total, ln.case_count_total) AS case_count_total,
  COALESCE(jd.case_count_by_year, ln.case_count_by_year) AS case_count_by_year,
  COALESCE(jd.case_type_distribution, ln.case_type_distribution) AS case_type_distribution,
  COALESCE(jd.avg_processing_days, ln.avg_processing_days) AS avg_processing_days,
  ln.verdict_stats,
  ln.source_url AS lawsnote_url,
  (jy.id IS NOT NULL) AS has_jy,
  (ln.id IS NOT NULL) AS has_lawsnote,
  CASE
    WHEN jd.name IS NOT NULL AND jy.id IS NOT NULL THEN '司法院+裁判書'
    WHEN jd.name IS NOT NULL THEN '僅裁判書'
    WHEN jy.id IS NOT NULL AND ln.id IS NOT NULL THEN '司法院+Lawsnote'
    WHEN jy.id IS NOT NULL THEN '僅司法院'
    ELSE '僅Lawsnote'
  END AS data_source,
  jy.id AS jy_id,
  ln.id AS ln_id,
  (jd.name IS NOT NULL) AS has_judgment,
  jd.first_yyyymm
FROM jy
FULL JOIN ln ON jy.name = ln.name AND jy.court_name = ln.court_name
LEFT JOIN jd ON jd.name = COALESCE(jy.name, ln.name)
            AND jd.court_name = COALESCE(jy.court_name, ln.court_name)
LEFT JOIN fj ON fj.name = COALESCE(jy.name, ln.name);
