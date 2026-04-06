-- ============================================================
-- lawyers_combined view 加入 lic_year 數值欄位（證號民國年）
-- 用於年資排序：lic_year 越小 = 年資越高
-- ============================================================

DROP VIEW IF EXISTS lawyers_combined CASCADE;

CREATE VIEW lawyers_combined AS
WITH all_names AS (
  SELECT DISTINCT name FROM lawyer_members WHERE COALESCE(is_active, true)
  UNION
  SELECT DISTINCT name FROM lawsnote_lawyers
  UNION
  SELECT DISTINCT name FROM moj_lawyers
),
m_dedup AS (
  SELECT DISTINCT ON (name) *
  FROM lawyer_members
  WHERE COALESCE(is_active, true)
  ORDER BY name, updated_at DESC NULLS LAST
),
l_dedup AS (
  SELECT DISTINCT ON (name) *
  FROM lawsnote_lawyers
  ORDER BY name, updated_at DESC NULLS LAST
),
j_dedup AS (
  SELECT DISTINCT ON (name) *
  FROM moj_lawyers
  ORDER BY name, updated_at DESC NULLS LAST
)
SELECT
  n.name,
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
  -- 新增：證號民國年（數值，可排序）
  CASE
    WHEN j.lic_no ~ '^\d+' THEN (REGEXP_MATCH(j.lic_no, '^(\d+)'))[1]::INTEGER
    WHEN l.cert_number ~ '^\d+' THEN (REGEXP_MATCH(l.cert_number, '^(\d+)'))[1]::INTEGER
    ELSE NULL
  END AS lic_year
FROM all_names n
LEFT JOIN m_dedup m ON n.name = m.name
LEFT JOIN l_dedup l ON n.name = l.name
LEFT JOIN j_dedup j ON n.name = j.name;

-- 重新建立 RLS policy
GRANT SELECT ON lawyers_combined TO authenticated, anon;
