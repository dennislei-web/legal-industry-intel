-- 法官案件量拆窗＋判決/裁定拆分
-- 1) judge_month_stats / lawyer_month_stats 加 doctypes jsonb（{"判決":n,"裁定":n,"其他":n}，
--    由 judgment_stats.py doctypefill 重解月包回填；未回填月為 NULL）
-- 2) judge_judgment_stats 加 case_count_1y / case_count_5y（視窗以資料最新月為基準，
--    近一年=含最新月往回 12 個月、近五年=60 個月）與 doctype_total/1y/5y
-- 3) refresh_judge_judgment_stats() 改版一併彙總新欄
-- 4) judges_combined view 重建，新欄附加在尾端（欄序與 mig 039 相同）

ALTER TABLE judge_month_stats  ADD COLUMN IF NOT EXISTS doctypes jsonb;
ALTER TABLE lawyer_month_stats ADD COLUMN IF NOT EXISTS doctypes jsonb;

ALTER TABLE judge_judgment_stats
  ADD COLUMN IF NOT EXISTS case_count_1y int,
  ADD COLUMN IF NOT EXISTS case_count_5y int,
  ADD COLUMN IF NOT EXISTS doctype_total jsonb,
  ADD COLUMN IF NOT EXISTS doctype_1y jsonb,
  ADD COLUMN IF NOT EXISTS doctype_5y jsonb;

CREATE OR REPLACE FUNCTION refresh_judge_judgment_stats() RETURNS void AS $$
DECLARE
  maxym text;
  cut1 text;
  cut5 text;
BEGIN
  SELECT max(yyyymm) INTO maxym FROM judge_month_stats;
  IF maxym IS NULL THEN RETURN; END IF;
  cut1 := to_char(to_date(maxym, 'YYYYMM') - interval '11 months', 'YYYYMM');
  cut5 := to_char(to_date(maxym, 'YYYYMM') - interval '59 months', 'YYYYMM');
  TRUNCATE judge_judgment_stats;
  INSERT INTO judge_judgment_stats
    (name, court_name, case_count_total, case_count_by_year,
     case_type_distribution, avg_processing_days, first_yyyymm,
     case_count_1y, case_count_5y, doctype_total, doctype_1y, doctype_5y,
     refreshed_at)
  SELECT g.name, g.court_name, g.total,
    (SELECT jsonb_object_agg(t.y, t.c) FROM (
       SELECT left(m2.yyyymm, 4) AS y, sum(m2.case_count) AS c
       FROM judge_month_stats m2
       WHERE m2.name = g.name AND m2.court_name = g.court_name
       GROUP BY 1) t),
    (SELECT jsonb_object_agg(t2.k, t2.v) FROM (
       SELECT e.key AS k, sum((e.value)::text::int) AS v
       FROM judge_month_stats m3, jsonb_each(m3.cats) e
       WHERE m3.name = g.name AND m3.court_name = g.court_name
       GROUP BY e.key) t2),
    CASE WHEN g.nd > 0 THEN round(g.sd::numeric / g.nd, 0) END,
    g.first_ym,
    COALESCE(g.c1, 0), COALESCE(g.c5, 0),
    (SELECT jsonb_object_agg(t3.k, t3.v) FROM (
       SELECT e.key AS k, sum((e.value)::text::int) AS v
       FROM judge_month_stats m4, jsonb_each(m4.doctypes) e
       WHERE m4.name = g.name AND m4.court_name = g.court_name
       GROUP BY e.key) t3),
    (SELECT jsonb_object_agg(t4.k, t4.v) FROM (
       SELECT e.key AS k, sum((e.value)::text::int) AS v
       FROM judge_month_stats m5, jsonb_each(m5.doctypes) e
       WHERE m5.name = g.name AND m5.court_name = g.court_name
         AND m5.yyyymm >= cut1
       GROUP BY e.key) t4),
    (SELECT jsonb_object_agg(t5.k, t5.v) FROM (
       SELECT e.key AS k, sum((e.value)::text::int) AS v
       FROM judge_month_stats m6, jsonb_each(m6.doctypes) e
       WHERE m6.name = g.name AND m6.court_name = g.court_name
         AND m6.yyyymm >= cut5
       GROUP BY e.key) t5),
    now()
  FROM (
    SELECT name, court_name, sum(case_count)::int AS total,
           sum(case_count) FILTER (WHERE yyyymm >= cut1)::int AS c1,
           sum(case_count) FILTER (WHERE yyyymm >= cut5)::int AS c5,
           sum(sum_days) AS sd, sum(n_days) AS nd, min(yyyymm) AS first_ym
    FROM judge_month_stats GROUP BY name, court_name
  ) g;
END $$ LANGUAGE plpgsql SECURITY DEFINER;

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
         s.avg_processing_days, s.first_yyyymm,
         s.case_count_1y, s.case_count_5y,
         s.doctype_total, s.doctype_1y, s.doctype_5y
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
  jd.first_yyyymm,
  jd.case_count_1y,
  jd.case_count_5y,
  jd.doctype_total,
  jd.doctype_1y,
  jd.doctype_5y
FROM jy
FULL JOIN ln ON jy.name = ln.name AND jy.court_name = ln.court_name
LEFT JOIN jd ON jd.name = COALESCE(jy.name, ln.name)
            AND jd.court_name = COALESCE(jy.court_name, ln.court_name)
LEFT JOIN fj ON fj.name = COALESCE(jy.name, ln.name);

-- 套用後另以 REST RPC 呼叫 refresh_judge_judgment_stats()（全期重算需時較長，
-- 走 REST 可帶長 timeout；doctype 欄待 doctypefill 回填後才有值）
