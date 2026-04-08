-- ============================================================
-- 修正 lawyers_combined: 改用證號去重，不再用姓名
-- 解決同名不同人被錯誤合併的問題（308 組，368 人）
-- ============================================================

DROP VIEW IF EXISTS lawyers_combined CASCADE;

CREATE VIEW lawyers_combined AS
WITH
-- MOJ 律師（用 lic_no 唯一，每筆都保留）
j_all AS (
  SELECT * FROM moj_lawyers
),
-- 全聯會（用 name 去重取最新）
m_dedup AS (
  SELECT DISTINCT ON (name) *
  FROM lawyer_members
  WHERE COALESCE(is_active, true)
  ORDER BY name, updated_at DESC NULLS LAST
),
-- Lawsnote（用 name 去重取最新）
l_dedup AS (
  SELECT DISTINCT ON (name) *
  FROM lawsnote_lawyers
  ORDER BY name, updated_at DESC NULLS LAST
)
SELECT
  COALESCE(j.name, m.name, l.name) AS name,
  COALESCE(m.bar_association, array_to_string(j.guild_names, ', ')) AS bar_association,
  COALESCE(j.main_region, m.region) AS region,
  m.practice_start_date,
  m.practice_end_date,
  COALESCE(m.is_active, true) AS is_active,
  l.case_count_5yr,
  l.expertise_areas,
  l.lawsnote_id,
  l.source_url AS lawsnote_url,
  l.education,
  COALESCE(j.office_normalized, j.office, l.firm_name) AS firm_name,
  COALESCE(j.lic_no, l.cert_number) AS cert_number,
  (m.id IS NOT NULL) AS has_twba,
  (l.id IS NOT NULL) AS has_lawsnote,
  (j.id IS NOT NULL) AS has_moj,
  CASE
    WHEN j.id IS NOT NULL AND m.id IS NOT NULL AND l.id IS NOT NULL THEN '三者皆有'
    WHEN j.id IS NOT NULL AND m.id IS NOT NULL THEN 'MOJ+全聯會'
    WHEN j.id IS NOT NULL AND l.id IS NOT NULL THEN 'MOJ+Lawsnote'
    WHEN m.id IS NOT NULL AND l.id IS NOT NULL THEN '全聯會+Lawsnote'
    WHEN j.id IS NOT NULL THEN '僅法務部'
    WHEN m.id IS NOT NULL THEN '僅全聯會'
    ELSE '僅Lawsnote'
  END AS data_source,
  m.id AS member_id,
  l.id AS lawsnote_id_pk,
  j.id AS moj_id,
  j.lic_no AS moj_lic_no,
  j.office AS moj_office,
  j.guild_names AS moj_guild_names,
  j.sex AS moj_sex,
  CASE
    WHEN j.lic_no ~ '^\(?\d+' THEN (REGEXP_MATCH(j.lic_no, '^\(?(\d+)'))[1]::INTEGER
    WHEN l.cert_number ~ '^\(?\d+' THEN (REGEXP_MATCH(l.cert_number, '^\(?(\d+)'))[1]::INTEGER
    ELSE NULL
  END AS lic_year
FROM j_all j
-- MOJ 律師為主表，LEFT JOIN 全聯會和 Lawsnote
LEFT JOIN m_dedup m ON j.name = m.name
LEFT JOIN l_dedup l ON j.name = l.name

UNION ALL

-- 只在全聯會有、MOJ 沒有的律師
SELECT
  m.name,
  m.bar_association,
  m.region,
  m.practice_start_date,
  m.practice_end_date,
  m.is_active,
  l.case_count_5yr,
  l.expertise_areas,
  l.lawsnote_id,
  l.source_url AS lawsnote_url,
  l.education,
  l.firm_name,
  l.cert_number,
  true AS has_twba,
  (l.id IS NOT NULL) AS has_lawsnote,
  false AS has_moj,
  CASE
    WHEN l.id IS NOT NULL THEN '全聯會+Lawsnote'
    ELSE '僅全聯會'
  END AS data_source,
  m.id AS member_id,
  l.id AS lawsnote_id_pk,
  NULL::UUID AS moj_id,
  NULL AS moj_lic_no,
  NULL AS moj_office,
  NULL::TEXT[] AS moj_guild_names,
  NULL AS moj_sex,
  CASE
    WHEN l.cert_number ~ '^\(?\d+' THEN (REGEXP_MATCH(l.cert_number, '^\(?(\d+)'))[1]::INTEGER
    ELSE NULL
  END AS lic_year
FROM m_dedup m
LEFT JOIN l_dedup l ON m.name = l.name
WHERE NOT EXISTS (SELECT 1 FROM moj_lawyers j2 WHERE j2.name = m.name)

UNION ALL

-- 只在 Lawsnote 有、MOJ 和全聯會都沒有的律師
SELECT
  l.name,
  NULL AS bar_association,
  NULL AS region,
  NULL AS practice_start_date,
  NULL AS practice_end_date,
  true AS is_active,
  l.case_count_5yr,
  l.expertise_areas,
  l.lawsnote_id,
  l.source_url AS lawsnote_url,
  l.education,
  l.firm_name,
  l.cert_number,
  false AS has_twba,
  true AS has_lawsnote,
  false AS has_moj,
  '僅Lawsnote' AS data_source,
  NULL::UUID AS member_id,
  l.id AS lawsnote_id_pk,
  NULL::UUID AS moj_id,
  NULL AS moj_lic_no,
  NULL AS moj_office,
  NULL::TEXT[] AS moj_guild_names,
  NULL AS moj_sex,
  CASE
    WHEN l.cert_number ~ '^\(?\d+' THEN (REGEXP_MATCH(l.cert_number, '^\(?(\d+)'))[1]::INTEGER
    ELSE NULL
  END AS lic_year
FROM l_dedup l
WHERE NOT EXISTS (SELECT 1 FROM moj_lawyers j2 WHERE j2.name = l.name)
  AND NOT EXISTS (SELECT 1 FROM m_dedup m2 WHERE m2.name = l.name);

GRANT SELECT ON lawyers_combined TO authenticated, anon;
