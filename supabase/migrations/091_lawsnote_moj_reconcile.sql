-- ============================================================
-- 091: 僅Lawsnote 律師歸戶 ＋ 歷史名冊標記（Lawsnote 降級為 enrichment 層）
-- ============================================================
-- 背景：lawyers_combined 三源合併走「姓名精確比對」，1,023 位僅Lawsnote 律師
--   = 姓名對不上 moj_lawyers / lawyer_members。實際成因兩類：
--   (a) 同一人、用字不同：改名（MOJ old_name 可證）或異體字（温/溫、峯/峰、
--       擧/舉、衞/衛、凊/清…）→ 應歸戶合併，身分主幹以 MOJ 為準
--   (b) 已離開執業：只出現在歷史裁判書，MOJ 現行名冊本來就無列 → 標 historical
--
-- 設計：
--   1. lawsnote_name_alias 表：lawsnote 用字 → MOJ 名冊用字（同 051 的
--      lawyer_name_alias 精神，但方向是「名冊內部歸戶」不是判決歸戶）
--   2. lawsnote_alias_backfill()：以「證號正規化比對」＋「old_name 比對
--      （含『、』分隔多舊名）」自動 populate，可重複呼叫（idempotent）；
--      API 補掃（scripts/lawsnote_moj_backfill.py）插入新 moj 列後再呼叫一次
--   3. lawyers_combined：l_dedup 加 match_name = COALESCE(別名, 原名)，
--      三處 join/排除全改走 match_name → 命中者自動升級 MOJ+Lawsnote，
--      expertise/lawsnote_url 等 enrichment 掛到 MOJ 主列上
--   4. lawyers_with_stats：加 is_historical 衍生欄（僅Lawsnote 且近 5 年
--      官方裁判書 0 件）。純 derived、自癒：日後出現案件即自動除標
--   5. 歸戶後判決統計不掉：若判決署名沿用 lawsnote 用字，補 lawyer_name_alias
--      （roster=MOJ 名 → judgment=lawsnote 名）；兩邊都有統計者不動（署名
--      分裂屬抽取端既有問題，見 051 註）
--
-- 防呆（全部在 populate 函式內）：
--   * 證號正規化：去括號、台→臺、「第」後去補零；兩側正規化證號皆唯一才配對
--   * 排除已能以原名對上 MOJ / 在籍全聯會者（全聯會+Lawsnote 的 10 列不動，
--     TWBA↔MOJ 姓名不一致是另一層問題，不在此處理）
--   * 目標 MOJ 名若已有同名 lawsnote 列 → 不建別名（避免一對多 join 膨脹）
--   * moj_name UNIQUE：一個 MOJ 主列最多吸收一個 lawsnote 列

BEGIN;

-- ============================================================
-- 1. 別名表
-- ============================================================
CREATE TABLE IF NOT EXISTS lawsnote_name_alias (
  lawsnote_name TEXT PRIMARY KEY,      -- lawsnote_lawyers.name 用字
  moj_name      TEXT NOT NULL UNIQUE,  -- moj_lawyers.name 名冊用字
  method        TEXT NOT NULL,         -- cert_match / old_name / api_backfill / manual
  note          TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE lawsnote_name_alias IS
  'lawsnote 用字 -> MOJ 名冊用字的歸戶對照（改名/異體字），lawyers_combined 合併走此表';

ALTER TABLE lawsnote_name_alias ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lawsnote_alias" ON lawsnote_name_alias;
CREATE POLICY "auth_read_lawsnote_alias" ON lawsnote_name_alias
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- ============================================================
-- 2. populate 函式（idempotent，API 補掃後可再呼叫）
-- ============================================================
CREATE OR REPLACE FUNCTION lawsnote_alias_backfill()
RETURNS TABLE (cert_added INT, oldname_added INT, judgment_alias_added INT)
LANGUAGE plpgsql
AS $$
DECLARE
  n_cert INT := 0;
  n_old  INT := 0;
  n_jdg  INT := 0;
BEGIN
  -- (1) 證號正規化比對
  WITH ls AS (
    SELECT l.name,
           regexp_replace(
             replace(regexp_replace(l.cert_number, '[()（）]', '', 'g'), '台', '臺'),
             '第0*(\d+)號', '第\1號') AS cert_norm
    FROM lawsnote_lawyers l
    WHERE l.cert_number IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM moj_lawyers m2 WHERE m2.name = l.name)
      AND NOT EXISTS (SELECT 1 FROM lawyer_members mm
                      WHERE mm.name = l.name AND COALESCE(mm.is_active, true))
  ),
  ls_u AS (  -- lawsnote 側同一正規化證號僅一個名字才可信
    SELECT cert_norm, min(name) AS name
    FROM ls GROUP BY cert_norm HAVING count(DISTINCT name) = 1
  ),
  mj AS (
    SELECT m.name,
           regexp_replace(
             replace(regexp_replace(m.lic_no, '[()（）]', '', 'g'), '台', '臺'),
             '第0*(\d+)號', '第\1號') AS lic_norm
    FROM moj_lawyers m
    WHERE m.lic_no IS NOT NULL
  ),
  mj_u AS (
    SELECT lic_norm, min(name) AS name
    FROM mj GROUP BY lic_norm HAVING count(DISTINCT name) = 1
  )
  INSERT INTO lawsnote_name_alias (lawsnote_name, moj_name, method, note)
  SELECT ls_u.name, mj_u.name, 'cert_match',
         '證號正規化比對（091）：' || ls_u.cert_norm
  FROM ls_u
  JOIN mj_u ON mj_u.lic_norm = ls_u.cert_norm
  WHERE ls_u.name <> mj_u.name
    AND NOT EXISTS (SELECT 1 FROM lawsnote_lawyers l2 WHERE l2.name = mj_u.name)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n_cert = ROW_COUNT;

  -- (2) MOJ old_name 比對（old_name 可能為「甲、乙、丙」多舊名串接）
  WITH cand AS (
    SELECT l.name AS lawsnote_name, m.name AS moj_name
    FROM moj_lawyers m
    CROSS JOIN LATERAL unnest(string_to_array(m.old_name, '、')) AS oldn
    JOIN lawsnote_lawyers l ON l.name = btrim(oldn)
    WHERE m.old_name IS NOT NULL
      AND l.name <> m.name
      AND NOT EXISTS (SELECT 1 FROM moj_lawyers m2 WHERE m2.name = l.name)
      AND NOT EXISTS (SELECT 1 FROM lawyer_members mm
                      WHERE mm.name = l.name AND COALESCE(mm.is_active, true))
      AND NOT EXISTS (SELECT 1 FROM lawsnote_lawyers l2 WHERE l2.name = m.name)
  ),
  cand_u AS (  -- 一個 lawsnote 名只能對到一個 MOJ 名（同舊名多人 → 放棄）
    SELECT lawsnote_name, min(moj_name) AS moj_name
    FROM cand GROUP BY lawsnote_name HAVING count(DISTINCT moj_name) = 1
  )
  INSERT INTO lawsnote_name_alias (lawsnote_name, moj_name, method, note)
  SELECT lawsnote_name, moj_name, 'old_name', 'MOJ old_name 改名比對（091）'
  FROM cand_u
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n_old = ROW_COUNT;

  -- (3) 判決歸戶：歸戶後 roster 名 = MOJ 名，若判決署名沿用 lawsnote 用字
  --     則補 lawyer_name_alias，官方案件數才不會掉。兩邊皆有統計者不動。
  INSERT INTO lawyer_name_alias (roster_name, judgment_name, note)
  SELECT a.moj_name, a.lawsnote_name,
         '091 lawsnote 歸戶：判決署名沿用 lawsnote 用字（' || a.method || '）'
  FROM lawsnote_name_alias a
  WHERE EXISTS (SELECT 1 FROM lawyer_judgment_stats s WHERE s.name = a.lawsnote_name)
    AND NOT EXISTS (SELECT 1 FROM lawyer_judgment_stats s WHERE s.name = a.moj_name)
  ON CONFLICT (roster_name) DO NOTHING;
  GET DIAGNOSTICS n_jdg = ROW_COUNT;

  RETURN QUERY SELECT n_cert, n_old, n_jdg;
END;
$$;

-- ============================================================
-- 3. lawyers_combined：合併改走 match_name（欄位輸出完全不變）
-- ============================================================
CREATE OR REPLACE VIEW lawyers_combined AS
WITH j_all AS (
  SELECT * FROM moj_lawyers
), m_dedup AS (
  SELECT DISTINCT ON (name) *
  FROM lawyer_members
  WHERE COALESCE(is_active, true)
  ORDER BY name, updated_at DESC NULLS LAST
), l_dedup AS (
  SELECT DISTINCT ON (l.name) l.*,
         COALESCE(a.moj_name, l.name) AS match_name  -- 091: 歸戶別名
  FROM lawsnote_lawyers l
  LEFT JOIN lawsnote_name_alias a ON a.lawsnote_name = l.name
  ORDER BY l.name, l.updated_at DESC NULLS LAST
)
SELECT COALESCE(j.name, m.name, l.match_name) AS name,
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
  m.id IS NOT NULL AS has_twba,
  l.id IS NOT NULL AS has_lawsnote,
  j.id IS NOT NULL AS has_moj,
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
    WHEN j.lic_no ~ '^\(?\d+' THEN (regexp_match(j.lic_no, '^\(?(\d+)'))[1]::integer
    WHEN l.cert_number ~ '^\(?\d+' THEN (regexp_match(l.cert_number, '^\(?(\d+)'))[1]::integer
    ELSE NULL::integer
  END AS lic_year
FROM j_all j
LEFT JOIN m_dedup m ON j.name = m.name
LEFT JOIN l_dedup l ON j.name = l.match_name

UNION ALL

SELECT m.name,
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
  l.id IS NOT NULL AS has_lawsnote,
  false AS has_moj,
  CASE WHEN l.id IS NOT NULL THEN '全聯會+Lawsnote' ELSE '僅全聯會' END AS data_source,
  m.id AS member_id,
  l.id AS lawsnote_id_pk,
  NULL::uuid AS moj_id,
  NULL::text AS moj_lic_no,
  NULL::text AS moj_office,
  NULL::text[] AS moj_guild_names,
  NULL::text AS moj_sex,
  CASE
    WHEN l.cert_number ~ '^\(?\d+' THEN (regexp_match(l.cert_number, '^\(?(\d+)'))[1]::integer
    ELSE NULL::integer
  END AS lic_year
FROM m_dedup m
LEFT JOIN l_dedup l ON m.name = l.match_name
WHERE NOT EXISTS (SELECT 1 FROM moj_lawyers j2 WHERE j2.name = m.name)

UNION ALL

SELECT l.match_name AS name,
  NULL::text AS bar_association,
  NULL::text AS region,
  NULL::date AS practice_start_date,
  NULL::date AS practice_end_date,
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
  NULL::uuid AS member_id,
  l.id AS lawsnote_id_pk,
  NULL::uuid AS moj_id,
  NULL::text AS moj_lic_no,
  NULL::text AS moj_office,
  NULL::text[] AS moj_guild_names,
  NULL::text AS moj_sex,
  CASE
    WHEN l.cert_number ~ '^\(?\d+' THEN (regexp_match(l.cert_number, '^\(?(\d+)'))[1]::integer
    ELSE NULL::integer
  END AS lic_year
FROM l_dedup l
WHERE NOT EXISTS (SELECT 1 FROM moj_lawyers j2 WHERE j2.name = l.match_name)
  AND NOT EXISTS (SELECT 1 FROM m_dedup m2 WHERE m2.name = l.match_name);

-- ============================================================
-- 4. lawyers_with_stats：追加 is_historical（衍生、自癒）
-- ============================================================
CREATE OR REPLACE VIEW lawyers_with_stats AS
SELECT c.*,
       s.cases_5yr     AS official_cases_5yr,
       s.cases_total   AS official_cases_total,
       s.cats_5yr      AS official_cats_5yr,
       s.top_court_5yr AS official_top_court,
       s.n_courts_5yr  AS official_n_courts,
       s.last_yyyymm   AS official_last_ym,
       count(*) OVER (PARTITION BY c.name) > 1 AS name_ambiguous,
       (c.data_source = '僅Lawsnote' AND COALESCE(s.cases_5yr, 0) = 0) AS is_historical
FROM lawyers_combined c
LEFT JOIN lawyer_name_alias a      ON a.roster_name = c.name
LEFT JOIN lawyer_judgment_stats s  ON s.name = COALESCE(a.judgment_name, c.name);

-- ============================================================
-- 5. 初次 populate
-- ============================================================
SELECT * FROM lawsnote_alias_backfill();

COMMIT;
