-- judges_combined 接上裁判書開放資料統計（judge_judgment_stats）
-- 案件數/案類分布/平均審理天數：官方裁判書統計優先，Lawsnote 為 fallback
-- 新增 has_judgment / first_yyyymm 欄位（附加在最後，不影響既有欄位順序）

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
)
SELECT COALESCE(jy.name, ln.name) AS name,
  COALESCE(jy.court_name, ln.court_name) AS court_name,
  jy.court_id, jy.division, jy.rank, jy.seniority_years, jy.status, jy.sex,
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
            AND jd.court_name = COALESCE(jy.court_name, ln.court_name);
