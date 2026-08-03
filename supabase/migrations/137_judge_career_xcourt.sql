-- 137: 法官生涯累計加跨院合計
-- 1) judge_judgment_stats 加 career_total_xcourt（同一人跨院生涯合計）/ career_courts（合併院數）
-- 2) refresh_judge_career_totals()：以 DB 端重演前端同名拆分邏輯（index.html judgeSameNameCourts）
--    a. 逐院署名區間先過幽靈月防呆（孤立月：該院 ±6 個月內無其他署名且當月 ≤2 件，
--       不列入區間；全孤立的院保留原樣）——防止上訴審附件誤抓的單件署名拉長區間
--    b. 官方遷調/支援邊（judge_transfers，無向串接）與錨定院相連者確認為同一人
--    c. 其餘他院署名區間與錨定院重疊 >6 個月＝同名另一人，排除；並沿
--       judge_changes 官方＋推定邊傳遞排除（與前端 edgeCourts 同口徑）
--    d. 合計＝未被排除各院 case_count 總和（幽靈月一併排除，與 modal 生涯軌跡卡口徑一致；
--       故跨院合計可能比各院 case_count_total 直加略少）
-- 3) refresh_judge_judgment_stats() 重定義：尾端串呼叫 refresh_judge_career_totals()
--    （CREATE OR REPLACE 會重置 proconfig，需重掛 mig 133 的 600s timeout）
-- 4) judges_combined view 以 CREATE OR REPLACE 附加兩欄於尾端（前段欄序不變）

ALTER TABLE judge_judgment_stats
  ADD COLUMN IF NOT EXISTS career_total_xcourt int,
  ADD COLUMN IF NOT EXISTS career_courts smallint;

CREATE OR REPLACE FUNCTION refresh_judge_career_totals() RETURNS int AS $$
DECLARE
  rec record;
  linked text[];
  oth text[];
  tmp text[];
  n int := 0;
BEGIN
  -- a) 幽靈月防呆後的逐院署名區間（total 仍含全部月份，與 case_count_total 口徑一致）
  CREATE TEMP TABLE _jspan ON COMMIT DROP AS
  WITH m AS (
    SELECT name, court_name,
           (left(yyyymm, 4)::int * 12 + right(yyyymm, 2)::int) AS ymi,
           case_count
    FROM judge_month_stats
    WHERE court_name <> '未知法院'
  ), g AS (
    SELECT *,
      (case_count <= 2
       AND COALESCE(ymi - lag(ymi)  OVER w > 6, true)
       AND COALESCE(lead(ymi) OVER w - ymi > 6, true)) AS is_iso
    FROM m
    WINDOW w AS (PARTITION BY name, court_name ORDER BY ymi)
  ), k AS (
    SELECT *, (NOT is_iso OR bool_and(is_iso) OVER (PARTITION BY name, court_name)) AS keep
    FROM g
  )
  SELECT name, court_name,
         min(ymi) FILTER (WHERE keep) AS first_i,
         max(ymi) FILTER (WHERE keep) AS last_i,
         sum(case_count) FILTER (WHERE keep)::bigint AS total
  FROM k GROUP BY name, court_name;
  CREATE INDEX ON _jspan (name);

  -- b) 官方遷調/支援邊（無向）
  CREATE TEMP TABLE _joff ON COMMIT DROP AS
  SELECT DISTINCT name, from_org AS a, to_org AS b FROM judge_transfers
  WHERE from_org IS NOT NULL AND to_org IS NOT NULL AND from_org <> to_org;
  CREATE INDEX ON _joff (name);

  -- c) 傳遞邊（官方＋推定，與前端 edgeCourts 同口徑）
  CREATE TEMP TABLE _jedge ON COMMIT DROP AS
  SELECT name, court_name AS a, x AS b
  FROM judge_changes, LATERAL unnest(ARRAY[transfer_to, transfer_from, inferred_to, inferred_from]) AS x
  WHERE x IS NOT NULL AND x <> court_name;
  CREATE INDEX ON _jedge (name);

  -- 單院者直接帶自身
  UPDATE judge_judgment_stats s
  SET career_total_xcourt = s.case_count_total, career_courts = 1
  WHERE (SELECT count(*) FROM _jspan p WHERE p.name = s.name) <= 1;

  -- 多院者逐錨定列計算
  FOR rec IN
    SELECT s.name, s.court_name FROM judge_judgment_stats s
    WHERE (SELECT count(*) FROM _jspan p WHERE p.name = s.name) > 1
      -- 錨定院須有署名區間（未知法院列不在 _jspan，跳過留 NULL）
      AND EXISTS (SELECT 1 FROM _jspan p2
                  WHERE p2.name = s.name AND p2.court_name = s.court_name)
  LOOP
    -- 官方邊 BFS 至定點：與錨定院官方串接的院＝確認同一人
    linked := ARRAY[rec.court_name];
    LOOP
      SELECT array_agg(DISTINCT t.x) INTO tmp FROM (
        SELECT CASE WHEN e.a = ANY(linked) THEN e.b ELSE e.a END AS x
        FROM _joff e
        WHERE e.name = rec.name AND (e.a = ANY(linked) OR e.b = ANY(linked))
      ) t WHERE t.x <> ALL(linked);
      EXIT WHEN tmp IS NULL;
      linked := linked || tmp;
    END LOOP;

    -- 重疊 >6 個月且非官方串接 ＝ 同名另一人
    SELECT array_agg(p.court_name) INTO oth
    FROM _jspan p
    JOIN _jspan anc ON anc.name = rec.name AND anc.court_name = rec.court_name
    WHERE p.name = rec.name AND p.court_name <> rec.court_name
      AND p.court_name <> ALL(linked)
      AND LEAST(anc.last_i, p.last_i) - GREATEST(anc.first_i, p.first_i) + 1 > 6;

    -- 沿邊傳遞排除（官方串接者豁免）
    IF oth IS NOT NULL THEN
      LOOP
        SELECT array_agg(DISTINCT p.court_name) INTO tmp
        FROM _jspan p
        WHERE p.name = rec.name AND p.court_name <> rec.court_name
          AND NOT (p.court_name = ANY(oth))
          AND p.court_name <> ALL(linked)
          AND EXISTS (SELECT 1 FROM _jedge e WHERE e.name = rec.name
                      AND ((e.a = p.court_name AND e.b = ANY(oth))
                        OR (e.b = p.court_name AND e.a = ANY(oth))));
        EXIT WHEN tmp IS NULL;
        oth := oth || tmp;
      END LOOP;
    END IF;

    UPDATE judge_judgment_stats s
    SET career_total_xcourt = (
          SELECT sum(p.total)::int FROM _jspan p
          WHERE p.name = rec.name AND (oth IS NULL OR p.court_name <> ALL(oth))),
        career_courts = (
          SELECT count(*)::smallint FROM _jspan p
          WHERE p.name = rec.name AND (oth IS NULL OR p.court_name <> ALL(oth)))
    WHERE s.name = rec.name AND s.court_name = rec.court_name;
    n := n + 1;
  END LOOP;

  DROP TABLE IF EXISTS _jspan;
  DROP TABLE IF EXISTS _joff;
  DROP TABLE IF EXISTS _jedge;
  RETURN n;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_judge_career_totals() SET statement_timeout = '600s';

-- 3) refresh_judge_judgment_stats 重定義（mig 123 原身＋尾端串 career 重算＋重掛 timeout）
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
  PERFORM refresh_judge_career_totals();
END $$ LANGUAGE plpgsql SECURITY DEFINER;
ALTER FUNCTION refresh_judge_judgment_stats() SET statement_timeout = '600s';

-- 4) judges_combined 附加兩欄於尾端（CREATE OR REPLACE 允許尾端加欄，前段欄序不變）
CREATE OR REPLACE VIEW judges_combined AS
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
         s.doctype_total, s.doctype_1y, s.doctype_5y,
         s.career_total_xcourt, s.career_courts
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
  jd.doctype_5y,
  jd.career_total_xcourt,
  jd.career_courts
FROM jy
FULL JOIN ln ON jy.name = ln.name AND jy.court_name = ln.court_name
LEFT JOIN jd ON jd.name = COALESCE(jy.name, ln.name)
            AND jd.court_name = COALESCE(jy.court_name, ln.court_name)
LEFT JOIN fj ON fj.name = COALESCE(jy.name, ln.name);

-- 套用後執行 SELECT refresh_judge_career_totals(); 回填（毋須全量重跑 judgment_stats）
