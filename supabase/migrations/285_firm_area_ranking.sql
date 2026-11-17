-- ============================================================
-- 285: 事務所版圖併入「依業務領域」切法（領域 × 法院 × 年度的事務所排名）
-- ============================================================
-- 需求（雷 2026-11-17）：事務所總覽的「領域專門所」和「事務所版圖」是同一份裁判書統計的兩種切法，
--   併成一張卡：切法開關「依法院案由｜依業務領域」，領域模式也要能篩法院與年度
--   （才能回答「勞動 × 新北地院喆律排第幾」）。
--
-- 原本的落差（併卡前兩塊各算各的）：
--   1. firm_area_cases（mig 279）只有 事務所×領域 兩維，不能篩法院、年度。
--   2. 件數加的是 lawyer_court_cause_year_stats.cases（整個西元年，2021/01 起），標題卻寫「近五年」；
--      版圖用 cases_win（近 5 年滾動窗）。本檔統一成 cases_win，選了年度才用整年 cases。
--   3. 律師歸所用 lawyer_cause_court_stats.firm_name（分所沒有正規化：以諾臺中分所／高雄所各自一列，
--      還有一列「律師未提供」）；版圖用 lawyer_firm_lookup（mig 266，分所併回本所、未提供不收）。
--      本檔統一成 lawyer_firm_lookup。
--
-- 做法：
--   lawyer_area_court_year_stats：律師×領域×法院×西元年（cases 整年／cases_win 滾動窗），
--     由 lawyer_court_cause_year_stats 經 cause_to_site_area() 彙總，實測約 69 萬列。
--   firm_classifiable_court_year_stats：事務所×法院×年的「可歸類案量」（佔比分母；不含一般民事／其他／醫療）。
--     分母要掃全部領域，先落地成事務所層，查詢時不必再掃 69 萬列。
--   firm_area_cases：改由上面第一張表彙總（全國、近 5 年滾動窗、lawyer_firm_lookup 歸戶），
--     事務所詳情「官網對照」分頁照舊讀這張，數字與版圖領域模式一致。
--   refresh_firm_area_cases()：三張表一起重建（名稱、回傳不變，extract-site-facts.yml 每月照打）。
--   refresh_firm_map_cache()：尾端加打 refresh_firm_area_cases()——lawyer_court_cause_year_stats 與
--     lawyer_firm_lookup 每次重建後領域表跟著重建，兩種切法的資料月份與歸戶永遠同步。
--   firm_area_rank_core：plpgsql＋force_custom_plan（理由同 266／268），不對外開放。
--   firm_area_ranking：對外包裝，只給管理員（官網主打欄是競爭情報，與 firm_site_facts 同權限）。
--     rank＝依件數的名次（不受排序與門檻影響）；ord＝目前排序下的名次（依佔比時只排達門檻的所）；
--     p_pin 指定的所一定回傳（喆律指標磚用），不在前 p_limit 名內時 in_list = false。
--     只收名稱含「事務所」者（排除掛在公司法人的企業內律師，同 mig 280）。
--   firm_area_specialists（mig 280）：前端不再呼叫，先留著不刪（舊分頁快取還會打）。
--
-- 口徑：領域模式一律名目（律師人次；案由層沒有去重素材，與版圖選案由種類時相同）。
-- ============================================================

CREATE TABLE IF NOT EXISTS lawyer_area_court_year_stats (
  name       text NOT NULL,
  area       text NOT NULL,
  court_name text NOT NULL,
  yr         int  NOT NULL,
  cases      int  NOT NULL,              -- 整個西元年
  cases_win  int  NOT NULL,              -- 只算近 5 年滾動窗內的月份
  PRIMARY KEY (area, court_name, yr, name)
);
-- 全國口徑選年度時走這支
CREATE INDEX IF NOT EXISTS idx_lacys_area_yr ON lawyer_area_court_year_stats (area, yr);

CREATE TABLE IF NOT EXISTS firm_classifiable_court_year_stats (
  firm_name  text NOT NULL,
  court_name text NOT NULL,
  yr         int  NOT NULL,
  cases      int  NOT NULL,
  cases_win  int  NOT NULL,
  PRIMARY KEY (court_name, yr, firm_name)
);

-- 不建 policy：只有 SECURITY DEFINER 的 RPC 與 service_role 讀得到
ALTER TABLE lawyer_area_court_year_stats       ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_classifiable_court_year_stats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON lawyer_area_court_year_stats       FROM anon, authenticated;
REVOKE ALL ON firm_classifiable_court_year_stats FROM anon, authenticated;

-- 三張表一起重建（約 10～15 秒）
CREATE OR REPLACE FUNCTION refresh_firm_area_cases()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET statement_timeout = '300s'
AS $$
DECLARE n integer;
BEGIN
  DROP TABLE IF EXISTS _fresh_lacys;
  CREATE TEMP TABLE _fresh_lacys ON COMMIT DROP AS
  WITH cat AS (SELECT cause_group, MIN(cat) AS cat FROM cause_group_causes GROUP BY cause_group)
  SELECT s.name, cause_to_site_area(c.cat, s.cause_group, s.sub_group) AS area, s.court_name, s.yr,
         SUM(s.cases)::int AS cases, SUM(s.cases_win)::int AS cases_win
  FROM lawyer_court_cause_year_stats s
  LEFT JOIN cat c ON c.cause_group = s.cause_group
  GROUP BY 1, 2, 3, 4;

  -- 不用 TRUNCATE（排他鎖會讓 PostgREST 重載 schema 時整站 503）；WHERE true 是給 pg-safeupdate 看的（mig 237）
  DELETE FROM lawyer_area_court_year_stats WHERE true;
  INSERT INTO lawyer_area_court_year_stats (name, area, court_name, yr, cases, cases_win)
  SELECT name, area, court_name, yr, cases, cases_win FROM _fresh_lacys
  ORDER BY area, court_name, yr, name;

  DELETE FROM firm_classifiable_court_year_stats WHERE true;
  INSERT INTO firm_classifiable_court_year_stats (firm_name, court_name, yr, cases, cases_win)
  SELECT f.firm_name, t.court_name, t.yr, SUM(t.cases)::int, SUM(t.cases_win)::int
  FROM _fresh_lacys t JOIN lawyer_firm_lookup f ON f.name = t.name
  WHERE t.area NOT IN ('一般民事', '其他', '醫療')
  GROUP BY 1, 2, 3;

  DELETE FROM firm_area_cases WHERE true;
  INSERT INTO firm_area_cases (firm_name, area, cases, lawyers)
  SELECT x.firm_name, x.area, SUM(x.c)::int, COUNT(*)::int
  FROM (
    SELECT f.firm_name, t.area, t.name, SUM(t.cases_win) AS c
    FROM _fresh_lacys t JOIN lawyer_firm_lookup f ON f.name = t.name
    GROUP BY 1, 2, 3
    HAVING SUM(t.cases_win) > 0
  ) x
  GROUP BY 1, 2;
  GET DIAGNOSTICS n = ROW_COUNT;

  ANALYZE lawyer_area_court_year_stats;
  ANALYZE firm_classifiable_court_year_stats;
  ANALYZE firm_area_cases;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION refresh_firm_area_cases() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION refresh_firm_area_cases() TO service_role;

-- 版圖預彙總重建後，領域表跟著重建（本體同 mig 266，只多最後一行）
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

  PERFORM refresh_firm_area_cases();
END $$;
REVOKE EXECUTE ON FUNCTION refresh_firm_map_cache() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION refresh_firm_map_cache() TO service_role;

-- 排名核心（不對外開放；p_court／p_year 為 NULL 即不篩）
CREATE OR REPLACE FUNCTION firm_area_rank_core(
  p_area text, p_court text, p_year int, p_sort text, p_min_cases int, p_limit int, p_pin text)
RETURNS TABLE (
  rank         int,       -- 依件數的名次
  ord          int,       -- 目前排序下的名次（依佔比時未達門檻者為 NULL）
  firm_name    text,
  cases        bigint,
  total_cases  bigint,    -- 該所可歸類案量（同一法院／年度條件）
  share        numeric,   -- cases ÷ total_cases，百分比
  lawyer_count int,       -- 該所在此領域有案量的律師數
  has_site     boolean,   -- 有官網且抽得出主打領域
  is_focus     boolean,   -- 官網主打此領域
  n_firms      int,       -- 此條件下有案量的事務所總數
  in_list      boolean    -- 是否在目前排序的前 p_limit 名內（false＝只因 p_pin 才回傳）
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
SET plan_cache_mode = 'force_custom_plan'
AS $$
#variable_conflict use_column
BEGIN
  IF p_area IS NULL THEN RETURN; END IF;
  RETURN QUERY
  WITH per AS (
    SELECT s.name, sum(CASE WHEN p_year IS NULL THEN s.cases_win ELSE s.cases END)::bigint AS c
    FROM lawyer_area_court_year_stats s
    WHERE s.area = p_area
      AND (p_court IS NULL OR s.court_name = p_court)
      AND (p_year  IS NULL OR s.yr         = p_year)
    GROUP BY s.name
    HAVING sum(CASE WHEN p_year IS NULL THEN s.cases_win ELSE s.cases END) > 0
  ), agg AS (
    SELECT f.firm_name AS fname, sum(p.c)::bigint AS cs, count(*)::int AS lcnt
    FROM per p JOIN lawyer_firm_lookup f ON f.name = p.name
    WHERE f.firm_name LIKE '%事務所%'
    GROUP BY f.firm_name
  ), tot AS (
    SELECT d.firm_name AS fname, sum(CASE WHEN p_year IS NULL THEN d.cases_win ELSE d.cases END)::bigint AS t
    FROM firm_classifiable_court_year_stats d
    WHERE (p_court IS NULL OR d.court_name = p_court)
      AND (p_year  IS NULL OR d.yr         = p_year)
    GROUP BY d.firm_name
  ), ranked AS (
    SELECT (row_number() OVER (ORDER BY a.cs DESC, a.fname))::int AS rk,
           a.fname, a.cs, t.t, round(a.cs::numeric * 100 / NULLIF(t.t, 0), 1) AS sh, a.lcnt,
           (count(*) OVER ())::int AS nf
    FROM agg a LEFT JOIN tot t ON t.fname = a.fname
  ), elig AS (
    SELECT r.fname,
           (row_number() OVER (ORDER BY CASE WHEN p_sort = 'share' THEN r.sh ELSE r.cs::numeric END DESC NULLS LAST,
                                        r.cs DESC, r.fname))::int AS o
    FROM ranked r
    WHERE p_sort IS DISTINCT FROM 'share' OR r.cs >= GREATEST(p_min_cases, 1)
  )
  SELECT r.rk, e.o, r.fname, r.cs, r.t, r.sh, r.lcnt,
         COALESCE(cardinality(f.focus_areas) > 0, false),
         COALESCE(p_area = ANY (f.focus_areas), false),
         r.nf,
         COALESCE(e.o <= p_limit, false)
  FROM ranked r
  LEFT JOIN elig e ON e.fname = r.fname
  LEFT JOIN firm_site_facts f ON f.firm_name = r.fname
  WHERE e.o <= p_limit OR r.fname = p_pin
  ORDER BY e.o NULLS LAST;
END $$;
REVOKE EXECUTE ON FUNCTION firm_area_rank_core(text, text, int, text, int, int, text) FROM PUBLIC, anon, authenticated;

-- 對外：只給管理員
CREATE OR REPLACE FUNCTION firm_area_ranking(
  p_area      text,
  p_court     text DEFAULT NULL,
  p_year      int  DEFAULT NULL,
  p_sort      text DEFAULT 'cases',   -- cases＝依件數、share＝依佔比
  p_min_cases int  DEFAULT 30,        -- 只在依佔比時生效
  p_limit     int  DEFAULT 100,
  p_pin       text DEFAULT NULL)
RETURNS TABLE (
  rank int, ord int, firm_name text, cases bigint, total_cases bigint, share numeric,
  lawyer_count int, has_site boolean, is_focus boolean, n_firms int, in_list boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_intel_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT * FROM firm_area_rank_core(
    p_area, p_court, p_year, COALESCE(p_sort, 'cases'), COALESCE(p_min_cases, 30),
    LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000), p_pin);
END $$;
REVOKE EXECUTE ON FUNCTION firm_area_ranking(text, text, int, text, int, int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION firm_area_ranking(text, text, int, text, int, int, text) TO authenticated;

-- 首次填表
SELECT refresh_firm_area_cases();

NOTIFY pgrst, 'reload schema';
