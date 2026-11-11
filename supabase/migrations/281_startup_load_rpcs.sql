-- ============================================================
-- 281: 開頁啟動請求瘦身（2026-11-11 效能盤點）
-- ============================================================
-- 盤點結果：單一查詢本身都很快（律師名冊一頁 11 ms），但每次開頁同時送出約 40 個請求，
-- 在 2 核心的資料庫上互搶，edge log 實測每個請求被拖到 0.8～2.4 秒。
-- 其中三組是「為了在瀏覽器算一個小統計，把整張表逐頁抓回來」：
--   律師總覽 性別／年齡／年資圖   moj_lawyers 16 頁        → moj_demographics() 1 次
--   一人所所長對照表（每次開頁）  moj_solo_firm_lawyers 5 頁 → solo_firm_map() 1 次
--   同名律師名單（每次開頁）      lawyers_with_stats 逐頁   → ambiguous_lawyer_names() 1 次
-- 另外事務所版圖的兩個下拉（法院／年度）每次掃 49 萬列，冷快取時 11 秒：改讀快取表。
-- ============================================================

-- 1. 律師人口統計：回傳原始值直方圖，分組仍在前端做（年齡依當年計算）
CREATE OR REPLACE FUNCTION moj_demographics()
RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH b AS (
    SELECT sex, birth_year,
           NULLIF(left(substring(lic_no from '^\(?(\d+)'), 4), '')::int AS lic_year
    FROM moj_lawyers
  )
  SELECT json_build_object(
    'total', (SELECT count(*) FROM b),
    'gender', (SELECT json_agg(json_build_object('sex', sex, 'n', n) ORDER BY (sex = '男') DESC, n DESC)
               FROM (SELECT sex, count(*) AS n FROM b WHERE sex IS NOT NULL AND sex <> '' GROUP BY sex) g),
    'birth_years', (SELECT json_object_agg(birth_year, n)
                    FROM (SELECT birth_year, count(*) AS n FROM b
                          WHERE birth_year IS NOT NULL AND birth_year > 0 AND birth_year < 200 GROUP BY birth_year) a),
    'lic_years', (SELECT json_object_agg(lic_year, n)
                  FROM (SELECT lic_year, count(*) AS n FROM b WHERE lic_year IS NOT NULL GROUP BY lic_year) s)
  );
$$;
REVOKE EXECUTE ON FUNCTION moj_demographics() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION moj_demographics() TO authenticated;

-- 2. 一人所所長對照表：{firm_key: 姓名}（沿用 view 的 security_invoker，權限不變）
CREATE OR REPLACE FUNCTION solo_firm_map()
RETURNS json
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE(json_object_agg(firm_key, name), '{}'::json) FROM moj_solo_firm_lawyers;
$$;
REVOKE EXECUTE ON FUNCTION solo_firm_map() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION solo_firm_map() TO authenticated;

-- 3. 同名律師名單
CREATE OR REPLACE FUNCTION ambiguous_lawyer_names()
RETURNS json
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE(json_agg(DISTINCT name), '[]'::json) FROM lawyers_with_stats WHERE name_ambiguous = true;
$$;
REVOKE EXECUTE ON FUNCTION ambiguous_lawyer_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ambiguous_lawyer_names() TO authenticated;

-- 4. 事務所版圖下拉（法院／年度）快取
--    stamp＝算快取當下的 firm_map_meta.refreshed_at；底表重算後 stamp 對不上，函數自動退回即時計算，
--    所以就算漏跑 refresh_lms_list_cache() 也只會變慢、不會給舊資料。
CREATE TABLE IF NOT EXISTS lms_list_cache (
  kind       TEXT PRIMARY KEY,          -- court / year
  payload    JSONB NOT NULL,
  stamp      TIMESTAMPTZ,
  built_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE lms_list_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON lms_list_cache FROM anon, authenticated;

CREATE OR REPLACE FUNCTION lms_court_list_live()
RETURNS TABLE (court_name text, cases bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.court_name, sum(s.cases_win)::bigint
  FROM lawyer_court_cat_year_stats s
  GROUP BY 1 HAVING sum(s.cases_win) > 0
  ORDER BY 2 DESC;
$$;
CREATE OR REPLACE FUNCTION lms_year_list_live()
RETURNS TABLE (yr integer, cases bigint, mm_min text, mm_max text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.yr, sum(s.cases_win)::bigint,
         CASE WHEN s.yr = left(m.win_from, 4)::int THEN substr(m.win_from, 5, 2) ELSE '01' END,
         CASE WHEN s.yr = left(m.win_to, 4)::int   THEN substr(m.win_to, 5, 2)   ELSE '12' END
  FROM lawyer_court_cat_year_stats s, firm_map_meta m
  WHERE m.id = 1
  GROUP BY s.yr, m.win_from, m.win_to
  HAVING sum(s.cases_win) > 0
  ORDER BY 1 DESC;
$$;
REVOKE EXECUTE ON FUNCTION lms_court_list_live() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION lms_year_list_live() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION refresh_lms_list_cache()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE st timestamptz;
BEGIN
  SELECT refreshed_at INTO st FROM firm_map_meta WHERE id = 1;
  INSERT INTO lms_list_cache (kind, payload, stamp, built_at)
  SELECT 'court', COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb), st, now() FROM lms_court_list_live() c
  ON CONFLICT (kind) DO UPDATE SET payload = EXCLUDED.payload, stamp = EXCLUDED.stamp, built_at = now();
  INSERT INTO lms_list_cache (kind, payload, stamp, built_at)
  SELECT 'year', COALESCE(jsonb_agg(to_jsonb(y)), '[]'::jsonb), st, now() FROM lms_year_list_live() y
  ON CONFLICT (kind) DO UPDATE SET payload = EXCLUDED.payload, stamp = EXCLUDED.stamp, built_at = now();
  RETURN 2;
END $$;
REVOKE EXECUTE ON FUNCTION refresh_lms_list_cache() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION lms_court_list()
RETURNS TABLE (court_name text, cases bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p jsonb;
BEGIN
  SELECT c.payload INTO p FROM lms_list_cache c
  WHERE c.kind = 'court' AND c.stamp IS NOT DISTINCT FROM (SELECT m.refreshed_at FROM firm_map_meta m WHERE m.id = 1);
  IF p IS NULL THEN
    RETURN QUERY SELECT * FROM lms_court_list_live();
  ELSE
    RETURN QUERY SELECT x.court_name, x.cases FROM jsonb_to_recordset(p) AS x(court_name text, cases bigint) ORDER BY x.cases DESC;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION lms_year_list()
RETURNS TABLE (yr integer, cases bigint, mm_min text, mm_max text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p jsonb;
BEGIN
  SELECT c.payload INTO p FROM lms_list_cache c
  WHERE c.kind = 'year' AND c.stamp IS NOT DISTINCT FROM (SELECT m.refreshed_at FROM firm_map_meta m WHERE m.id = 1);
  IF p IS NULL THEN
    RETURN QUERY SELECT * FROM lms_year_list_live();
  ELSE
    RETURN QUERY SELECT x.yr, x.cases, x.mm_min, x.mm_max
                 FROM jsonb_to_recordset(p) AS x(yr integer, cases bigint, mm_min text, mm_max text) ORDER BY x.yr DESC;
  END IF;
END $$;

-- 5. 事務所總覽的「律師身分結構／平均年齡年資」：整份名冊的精簡欄位一次回傳
--    （舊版同樣是 16 頁平行抓 moj_lawyers；所長推估邏輯較複雜，留在前端算，只把 16 次請求併成 1 次）
--    每列＝[姓名, 出生年, 證號, 事務所]；純量 json 回傳不受 PostgREST 1000 列上限。
CREATE OR REPLACE FUNCTION moj_lawyers_slim()
RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(json_agg(json_build_array(name, birth_year, lic_no, office_normalized)), '[]'::json) FROM moj_lawyers;
$$;
REVOKE EXECUTE ON FUNCTION moj_lawyers_slim() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION moj_lawyers_slim() TO authenticated;

SELECT refresh_lms_list_cache();
