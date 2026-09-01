-- 181: 法官跨院合計加「幽靈院」防呆（與前端 index.html 同口徑）
--
-- 問題（時瑋辰個案）：mig 137 的幽靈月防呆只殺「孤立月」（該院 ±6 個月內無其他署名且當月 ≤2 件），
-- 抓不到長跨度、細水流型的誤抓署名。時瑋辰（司法院名冊＝新北地院現任法官）在臺灣高等法院
-- 有 67 件散在 44 個月（月均 1.5 件、全為判決），每個月都有「鄰居」故全數躲過孤立月規則；
-- 其真身臺中地院（1,724 件/49 月，月均 35.2）與新北地院（4,846 件/95 月，月均 51.0）反而
-- 因與該幽靈區間重疊 >6 個月而被判成「同名的另一位法官」——主從完全顛倒。
--
-- 修法：整院層級的幽靈判定。某院署名月數 ≥6、月均 ≤3 件、不到本人常態院（最高密度院）的 10%、
-- 且審級高於常態院 ＝不符任職法官的辦案節奏，研判為裁判被上訴後上訴審判決書附件／原審全文誤抓。
--   a. 幽靈院不列入 career_total_xcourt / career_courts
--   b. 幽靈院不參與同名重疊判定（不會把真身拆掉）
--   c. 錨定列本身是幽靈院時，改以該人常態院為錨（常態任職院必為最高密度）
-- 審級條件不可省：誤抓成因是上訴審引用原審全文，幽靈院必然是上級審。少了它會誤殺離島小院的
-- 真任職（連江地院法官月均中位數僅 4.7、澎湖 11.5，本身就低量）——實測會多殺 608 列地院任職。
-- 全國影響面：1,247 個法官×法院列 / 1,134 位法官 / 34,094 件，其中地方法院 0 筆。

CREATE OR REPLACE FUNCTION refresh_judge_career_totals() RETURNS int AS $$
DECLARE
  rec record;
  anchor_court text;
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
         sum(case_count) FILTER (WHERE keep)::bigint AS total,
         count(*) FILTER (WHERE keep)::int AS months
  FROM k GROUP BY name, court_name;
  CREATE INDEX ON _jspan (name);

  -- a2) 幽靈院：≥6 月、月均 ≤3 件、<本人常態院的 10%、且審級高於常態院（整院誤抓署名）
  CREATE TEMP TABLE _jghost ON COMMIT DROP AS
  WITH d AS (
    SELECT name, court_name, months,
           total::numeric / GREATEST(months, 1) AS dens,
           CASE WHEN court_name LIKE '最高%' THEN 3
                WHEN court_name LIKE '%高等%' THEN 2 ELSE 1 END AS tier
    FROM _jspan WHERE months IS NOT NULL
  ), t AS (
    -- 常態院＝最高密度院（同密度時取件數多者，確保與前端排序結果一致）
    SELECT DISTINCT ON (name) name, dens AS top_dens, tier AS top_tier
    FROM d ORDER BY name, dens DESC, months DESC
  )
  SELECT d.name, d.court_name
  FROM d JOIN t USING (name)
  WHERE d.months >= 6 AND d.dens <= 3
    AND d.dens < t.top_dens * 0.1
    AND d.tier > t.top_tier;
  CREATE INDEX ON _jghost (name);

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
    -- 錨定院：本列若是幽靈院，改以最高密度的非幽靈院為錨
    anchor_court := rec.court_name;
    IF EXISTS (SELECT 1 FROM _jghost gh
               WHERE gh.name = rec.name AND gh.court_name = rec.court_name) THEN
      SELECT p.court_name INTO anchor_court
      FROM _jspan p
      WHERE p.name = rec.name
        AND NOT EXISTS (SELECT 1 FROM _jghost gh2
                        WHERE gh2.name = p.name AND gh2.court_name = p.court_name)
      ORDER BY p.total::numeric / GREATEST(p.months, 1) DESC
      LIMIT 1;
      anchor_court := COALESCE(anchor_court, rec.court_name);
    END IF;

    -- 官方邊 BFS 至定點：與錨定院官方串接的院＝確認同一人
    linked := ARRAY[anchor_court];
    LOOP
      SELECT array_agg(DISTINCT t.x) INTO tmp FROM (
        SELECT CASE WHEN e.a = ANY(linked) THEN e.b ELSE e.a END AS x
        FROM _joff e
        WHERE e.name = rec.name AND (e.a = ANY(linked) OR e.b = ANY(linked))
      ) t WHERE t.x <> ALL(linked);
      EXIT WHEN tmp IS NULL;
      linked := linked || tmp;
    END LOOP;

    -- 重疊 >6 個月且非官方串接 ＝ 同名另一人（幽靈院不參與判定）
    SELECT array_agg(p.court_name) INTO oth
    FROM _jspan p
    JOIN _jspan anc ON anc.name = rec.name AND anc.court_name = anchor_court
    WHERE p.name = rec.name AND p.court_name <> anchor_court
      AND p.court_name <> ALL(linked)
      AND NOT EXISTS (SELECT 1 FROM _jghost gh
                      WHERE gh.name = p.name AND gh.court_name = p.court_name)
      AND LEAST(anc.last_i, p.last_i) - GREATEST(anc.first_i, p.first_i) + 1 > 6;

    -- 沿邊傳遞排除（官方串接者豁免）
    IF oth IS NOT NULL THEN
      LOOP
        SELECT array_agg(DISTINCT p.court_name) INTO tmp
        FROM _jspan p
        WHERE p.name = rec.name AND p.court_name <> anchor_court
          AND NOT (p.court_name = ANY(oth))
          AND p.court_name <> ALL(linked)
          AND NOT EXISTS (SELECT 1 FROM _jghost gh
                          WHERE gh.name = p.name AND gh.court_name = p.court_name)
          AND EXISTS (SELECT 1 FROM _jedge e WHERE e.name = rec.name
                      AND ((e.a = p.court_name AND e.b = ANY(oth))
                        OR (e.b = p.court_name AND e.a = ANY(oth))));
        EXIT WHEN tmp IS NULL;
        oth := oth || tmp;
      END LOOP;
    END IF;

    -- 合計＝未被排除且非幽靈院各院 total
    UPDATE judge_judgment_stats s
    SET career_total_xcourt = (
          SELECT sum(p.total)::int FROM _jspan p
          WHERE p.name = rec.name AND (oth IS NULL OR p.court_name <> ALL(oth))
            AND NOT EXISTS (SELECT 1 FROM _jghost gh
                            WHERE gh.name = p.name AND gh.court_name = p.court_name)),
        career_courts = (
          SELECT count(*)::smallint FROM _jspan p
          WHERE p.name = rec.name AND (oth IS NULL OR p.court_name <> ALL(oth))
            AND NOT EXISTS (SELECT 1 FROM _jghost gh
                            WHERE gh.name = p.name AND gh.court_name = p.court_name))
    WHERE s.name = rec.name AND s.court_name = rec.court_name;
    n := n + 1;
  END LOOP;

  DROP TABLE IF EXISTS _jspan;
  DROP TABLE IF EXISTS _jghost;
  DROP TABLE IF EXISTS _joff;
  DROP TABLE IF EXISTS _jedge;
  RETURN n;
END $$ LANGUAGE plpgsql SECURITY DEFINER;
-- CREATE OR REPLACE 會重置 proconfig，必須重掛 timeout（mig 133/137 教訓）
ALTER FUNCTION refresh_judge_career_totals() SET statement_timeout = '600s';

-- 套用後執行：SELECT refresh_judge_career_totals();
