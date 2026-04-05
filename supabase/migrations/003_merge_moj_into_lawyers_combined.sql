-- ============================================================
-- 把 moj_lawyers 合併進 lawyers_combined view
-- ============================================================
-- 目標：每位律師可被 3 個來源同時標記
--   - 法務部 (MOJ lawyerbc)     → has_moj
--   - 全聯會 (TWBA lawyer_members) → has_twba
--   - Lawsnote 判決             → has_lawsnote
-- ============================================================

DROP VIEW IF EXISTS lawyers_combined CASCADE;

CREATE VIEW lawyers_combined AS
WITH all_names AS (
  -- 取三表 name 聯集（每個名字一次）
  SELECT DISTINCT name FROM lawyer_members WHERE COALESCE(is_active, true)
  UNION
  SELECT DISTINCT name FROM lawsnote_lawyers
  UNION
  SELECT DISTINCT name FROM moj_lawyers
),
m_dedup AS (
  -- 同名律師取最新一筆
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
  -- 基本欄位（優先 MOJ > 全聯會 > Lawsnote）
  COALESCE(m.bar_association, array_to_string(j.guild_names, ', ')) AS bar_association,
  COALESCE(j.main_region, m.region) AS region,
  m.practice_start_date,
  m.practice_end_date,
  COALESCE(m.is_active, true) AS is_active,
  -- Lawsnote 加值欄位
  l.case_count_5yr,
  l.expertise_areas,
  l.lawsnote_id,
  l.source_url AS lawsnote_url,
  l.education,
  -- 事務所（優先 MOJ，因為是登記原文）
  COALESCE(j.office_normalized, j.office, l.firm_name) AS firm_name,
  -- 證號（優先 MOJ）
  COALESCE(j.lic_no, l.cert_number) AS cert_number,
  -- 三個來源 flag
  (m.id IS NOT NULL) AS has_twba,
  (l.id IS NOT NULL) AS has_lawsnote,
  (j.id IS NOT NULL) AS has_moj,
  -- 兼容舊 data_source 欄位 (加入 MOJ 後擴充)
  CASE
    WHEN j.id IS NOT NULL AND m.id IS NOT NULL AND l.id IS NOT NULL THEN '三者皆有'
    WHEN j.id IS NOT NULL AND m.id IS NOT NULL THEN 'MOJ+全聯會'
    WHEN j.id IS NOT NULL AND l.id IS NOT NULL THEN 'MOJ+Lawsnote'
    WHEN m.id IS NOT NULL AND l.id IS NOT NULL THEN '全聯會+Lawsnote'
    WHEN j.id IS NOT NULL THEN '僅法務部'
    WHEN m.id IS NOT NULL THEN '僅全聯會'
    ELSE '僅Lawsnote'
  END AS data_source,
  -- PK 參考
  m.id AS member_id,
  l.id AS lawsnote_id_pk,
  j.id AS moj_id,
  -- MOJ 專屬欄位
  j.lic_no AS moj_lic_no,
  j.office AS moj_office,
  j.guild_names AS moj_guild_names,
  j.sex AS moj_sex
FROM all_names n
LEFT JOIN m_dedup m ON n.name = m.name
LEFT JOIN l_dedup l ON n.name = l.name
LEFT JOIN j_dedup j ON n.name = j.name;
