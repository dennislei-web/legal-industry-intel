-- ============================================================
-- 266: 事務所版圖篩選加速——律師×法院×案類×年度預彙總表（firm_court_ranking v4）
-- ============================================================
-- 症狀（雷 2026-11-05，截圖「民事／全部案由種類／全部法院／近 5 年總計」）：
--   事務所版圖只要離開預設組合，每切一次下拉要等 3～4 秒。
-- 量測（PostgREST 公開金鑰、熱快取）：民事 3.1～4.3s、臺北地院 1.2～1.8s、刑事×2024 3.2s、
--   家事×臺中 2.6s；下拉 lms_court_list 1.2s、lms_year_list 1.0s。
-- 原因：firm_court_ranking（mig 047／111／189）每次對 lawyer_month_stats（293 萬列、1.1 GB）
--   的近 5 年視窗 88.5 萬列逐列取 cats->>案類 再彙總；又是 LANGUAGE sql，參數在規劃期未知，
--   p_court IS NULL OR ... 這類條件用不到索引（同一句 SQL 直接 EXPLAIN 只要 1.1s，函數內要 2.5s）；
--   歸戶 CTE 每次重算 lawyers_combined view（0.2s、會 spill temp）。
--
-- 做法：
--   lawyer_court_cat_year_stats：律師×法院×案類×西元年，兩個量——
--     cases     ＝整年合計（選年度時用，與舊版「整個西元年」口徑同）
--     cases_win ＝只算落在近 5 年滾動窗（max(yyyymm) 往回 59 個月）內的月份（近 5 年總計用）
--     只存 yr >= 視窗起始年（年度下拉 lms_year_list 本來就只列視窗內的年）。約 49 萬列。
--     口徑等價：實測 2021 起 97 萬列 cats 各鍵加總 == case_count 零筆不符，所以「全部案類」
--     ＝所有 cat 列加總，不另存合計列。
--   lawyer_firm_lookup：047 firm CTE 落地（同名唯一者才收，歸戶規則一字不差）。
--   firm_map_meta：視窗起訖與刷新時間（dup 視窗與年度下拉的月份範圍都讀這裡，跟預彙總同一口徑）。
--   firm_court_ranking v4：同簽名、同回傳欄；改 plpgsql＋force_custom_plan，條件折成常數走索引。
--     rank 排序加 firm_name 做 tie-break（舊版同分順序不定）。
--   lms_court_list／lms_year_list：改讀預彙總表（年度月份範圍由 meta 推：首年起月、末年迄月）。
--   refresh_firm_map_cache：先 refresh_firm_map_preagg() 再重建預設快取（名稱不變，週掃／月更掛鉤沿用）。
--     DELETE 都帶 WHERE true（mig 237 safeupdate 地雷）。
--
-- 刷新時機：每週五本機 moj_detail_sweep_weekly.py（名冊歸戶變動）＋ 月更 judgment_stats.py
--   refresh 鏈尾端（lawyer_month_stats 新月份＋去重 cache 刷完後）＋ judgment-groupfill.yml 尾端。
--   中間若 lawyer_month_stats 多了新月份而還沒刷，版圖停在上一次視窗（最多一週），不會壞只會舊。
--
-- 驗證（套用前後各跑一次，10 種組合 EXCEPT 雙向為空）：
--   select * from firm_court_ranking('民事', null, null) limit 3;              -- 法丞 3410
--   select * from firm_court_ranking('家事', '臺灣臺中地方法院', null) limit 3;  -- 喆律 286

CREATE TABLE IF NOT EXISTS lawyer_court_cat_year_stats (
  name       text NOT NULL,
  court_name text NOT NULL,
  cat        text NOT NULL,
  yr         int  NOT NULL,
  cases      int  NOT NULL,   -- 整個西元年
  cases_win  int  NOT NULL,   -- 只算近 5 年滾動窗內的月份
  PRIMARY KEY (cat, yr, court_name, name)
);
CREATE INDEX IF NOT EXISTS idx_lccy_court_yr ON lawyer_court_cat_year_stats (court_name, yr);
CREATE INDEX IF NOT EXISTS idx_lccy_yr       ON lawyer_court_cat_year_stats (yr);

CREATE TABLE IF NOT EXISTS lawyer_firm_lookup (
  name      text PRIMARY KEY,
  firm_name text NOT NULL
);

CREATE TABLE IF NOT EXISTS firm_map_meta (
  id           int PRIMARY KEY CHECK (id = 1),
  win_from     text NOT NULL,   -- 近 5 年視窗起月 YYYYMM
  win_to       text NOT NULL,   -- 資料最新月 YYYYMM
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE lawyer_court_cat_year_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE lawyer_firm_lookup          ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_map_meta               ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_read_lccy ON lawyer_court_cat_year_stats;
DROP POLICY IF EXISTS auth_read_lfl  ON lawyer_firm_lookup;
DROP POLICY IF EXISTS auth_read_fmm  ON firm_map_meta;
CREATE POLICY auth_read_lccy ON lawyer_court_cat_year_stats FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY auth_read_lfl  ON lawyer_firm_lookup          FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY auth_read_fmm  ON firm_map_meta               FOR SELECT USING (auth.uid() IS NOT NULL);

-- 預彙總重建（約 20～30 秒）：視窗以 lawyer_month_stats 的 max(yyyymm) 為準
CREATE OR REPLACE FUNCTION refresh_firm_map_preagg()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $$
DECLARE
  v_to   text;
  v_from text;
BEGIN
  SELECT max(l.yyyymm) INTO v_to FROM lawyer_month_stats l;
  IF v_to IS NULL THEN RETURN; END IF;
  v_from := to_char(to_date(v_to || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM');

  DROP TABLE IF EXISTS _fresh_lccy;
  CREATE TEMP TABLE _fresh_lccy ON COMMIT DROP AS
  SELECT m.name, m.court_name, k.key AS cat, left(m.yyyymm, 4)::int AS yr,
         sum((k.value)::int)::int AS cases,
         sum(CASE WHEN m.yyyymm >= v_from THEN (k.value)::int ELSE 0 END)::int AS cases_win
  FROM lawyer_month_stats m
  CROSS JOIN LATERAL jsonb_each_text(m.cats) k
  WHERE m.yyyymm >= left(v_from, 4) || '01' AND m.cats IS NOT NULL
  GROUP BY 1, 2, 3, 4;

  -- WHERE true 不可省：PostgREST 路徑載入 pg-safeupdate，無 WHERE 的 DELETE 會回 400（mig 237）
  DELETE FROM lawyer_court_cat_year_stats WHERE true;
  INSERT INTO lawyer_court_cat_year_stats (name, court_name, cat, yr, cases, cases_win)
  SELECT name, court_name, cat, yr, cases, cases_win FROM _fresh_lccy
  ORDER BY cat, yr, court_name, name;   -- 依主鍵順序落地，同案類的列在磁碟上相鄰

  -- 歸戶口徑＝047 firm_court_ranking 的 firm CTE，一字不差（同名多筆者不收）
  DROP TABLE IF EXISTS _fresh_lookup;
  CREATE TEMP TABLE _fresh_lookup ON COMMIT DROP AS
  SELECT lc.name, min(coalesce(substring(lc.firm_name from '^(.*?事務所)'), lc.firm_name)) AS firm_name
  FROM lawyers_combined lc
  WHERE lc.firm_name IS NOT NULL AND lc.firm_name NOT LIKE '%未提供%'
  GROUP BY lc.name
  HAVING count(*) = 1;

  DELETE FROM lawyer_firm_lookup WHERE true;
  INSERT INTO lawyer_firm_lookup (name, firm_name) SELECT name, firm_name FROM _fresh_lookup;

  INSERT INTO firm_map_meta (id, win_from, win_to, refreshed_at) VALUES (1, v_from, v_to, now())
  ON CONFLICT (id) DO UPDATE
    SET win_from = EXCLUDED.win_from, win_to = EXCLUDED.win_to, refreshed_at = EXCLUDED.refreshed_at;

  ANALYZE lawyer_court_cat_year_stats;
  ANALYZE lawyer_firm_lookup;
END $$;
REVOKE EXECUTE ON FUNCTION refresh_firm_map_preagg() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION refresh_firm_map_preagg() TO service_role;

-- 排行 RPC v4：簽名、回傳欄與 189 版相同；force_custom_plan 讓 p_* IS NULL OR ... 折成常數走索引
CREATE OR REPLACE FUNCTION firm_court_ranking(p_cat text DEFAULT NULL, p_court text DEFAULT NULL, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int, dup_cases bigint, dedup_cases bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
SET plan_cache_mode = 'force_custom_plan'
AS $$
#variable_conflict use_column
DECLARE
  lo text;
  hi text;
BEGIN
  IF p_year IS NOT NULL THEN
    lo := p_year::text || '01';
    hi := p_year::text || '12';
  ELSE
    SELECT m.win_from, m.win_to INTO lo, hi FROM firm_map_meta m WHERE m.id = 1;
  END IF;
  IF lo IS NULL THEN RETURN; END IF;   -- 預彙總還沒刷過

  RETURN QUERY
  WITH per AS (
    SELECT s.name, sum(CASE WHEN p_year IS NULL THEN s.cases_win ELSE s.cases END)::bigint AS c
    FROM lawyer_court_cat_year_stats s
    WHERE (p_cat IS NULL OR s.cat = p_cat)
      AND (p_court IS NULL OR s.court_name = p_court)
      AND (p_year IS NULL OR s.yr = p_year)
    GROUP BY s.name
    HAVING sum(CASE WHEN p_year IS NULL THEN s.cases_win ELSE s.cases END) > 0
  ), agg AS (
    SELECT f.firm_name AS fname, sum(p.c)::bigint AS cs, count(*)::int AS lcnt
    FROM per p JOIN lawyer_firm_lookup f ON f.name = p.name
    GROUP BY f.firm_name
  ), dup AS (
    SELECT d.firm_name AS fname, sum(d.dup_cases)::bigint AS dc
    FROM firm_court_dup_month_stats d
    WHERE d.ym >= lo AND d.ym <= hi
      AND (p_court IS NULL OR d.court_name = p_court)
      AND (p_cat IS NULL OR d.cat = p_cat)
    GROUP BY d.firm_name
  )
  SELECT (row_number() OVER (ORDER BY (a.cs - coalesce(u.dc, 0)) DESC, a.fname))::int,
         a.fname, a.cs, a.lcnt,
         coalesce(u.dc, 0)::bigint,
         (a.cs - coalesce(u.dc, 0))::bigint
  FROM agg a LEFT JOIN dup u ON u.fname = a.fname
  ORDER BY (a.cs - coalesce(u.dc, 0)) DESC, a.fname;
END $$;
GRANT EXECUTE ON FUNCTION firm_court_ranking(text, text, int) TO anon, authenticated;

-- 法院下拉：近 5 年有律師出庭的法院（按出庭量排序）——改讀預彙總
CREATE OR REPLACE FUNCTION lms_court_list()
RETURNS TABLE (court_name text, cases bigint) AS $$
  SELECT s.court_name, sum(s.cases_win)::bigint
  FROM lawyer_court_cat_year_stats s
  GROUP BY 1 HAVING sum(s.cases_win) > 0
  ORDER BY 2 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lms_court_list() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION lms_court_list() TO anon, authenticated;

-- 年度下拉：視窗內的西元年；首尾為部分年，月份範圍由 meta 推
CREATE OR REPLACE FUNCTION lms_year_list()
RETURNS TABLE (yr int, cases bigint, mm_min text, mm_max text) AS $$
  SELECT s.yr, sum(s.cases_win)::bigint,
         CASE WHEN s.yr = left(m.win_from, 4)::int THEN substr(m.win_from, 5, 2) ELSE '01' END,
         CASE WHEN s.yr = left(m.win_to, 4)::int   THEN substr(m.win_to, 5, 2)   ELSE '12' END
  FROM lawyer_court_cat_year_stats s, firm_map_meta m
  WHERE m.id = 1
  GROUP BY s.yr, m.win_from, m.win_to
  HAVING sum(s.cases_win) > 0
  ORDER BY 1 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION lms_year_list() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION lms_year_list() TO anon, authenticated;

-- 預設快取刷新：先重建預彙總，再用新 RPC 填預設組合（名稱不變，所有掛鉤沿用）
CREATE OR REPLACE FUNCTION refresh_firm_map_cache()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $$
BEGIN
  PERFORM refresh_firm_map_preagg();

  DROP TABLE IF EXISTS _fresh_map;
  CREATE TEMP TABLE _fresh_map ON COMMIT DROP AS
  SELECT r.rank, r.firm_name, r.cases, r.lawyer_count, r.dup_cases, r.dedup_cases, now() AS refreshed_at
  FROM firm_court_ranking(NULL, NULL, NULL) r;

  DELETE FROM firm_map_default_cache WHERE true;
  INSERT INTO firm_map_default_cache (rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, refreshed_at)
  SELECT rank, firm_name, cases, lawyer_count, dup_cases, dedup_cases, refreshed_at FROM _fresh_map;
END $$;
GRANT EXECUTE ON FUNCTION refresh_firm_map_cache() TO service_role;

-- 首刷：預彙總＋預設快取一起填，新 RPC 立刻有資料
SELECT refresh_firm_map_cache();

NOTIFY pgrst, 'reload schema';
