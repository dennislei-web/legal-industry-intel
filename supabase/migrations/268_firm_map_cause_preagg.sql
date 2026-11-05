-- ============================================================
-- 268: 事務所版圖——案由種類／子類路徑也改讀預彙總（接 266；firm_cause_court_ranking v2）
-- ============================================================
-- 症狀（雷 2026-11-05，266 上線後「順手一起改」）：版圖選了案由種類（＋法院／子類／年度）仍要等
--   0.8～1.0 秒，冷快取 4.9 秒；全國口徑的種類／子類排名 0.45～0.6 秒、選年度冷快取 2.3 秒。
-- 量測（PostgREST 公開金鑰，改前→改後）：
--   損害賠償×臺北地院 4.9s 冷／0.95s 暖 → 0.2～0.4s；＋交通事故 4.8s／0.8s → 0.19s；＋2025 0.85s → 0.21s
--   其他民法×臺中 1.0s → 0.16～0.27s；全國損害賠償 0.45s → 0.27s；損害賠償／交通事故 0.59s（選年度 2.3s 冷）→ 0.22s
--   cause_sub_group_list 0.72s／0.32s → 0.21s
-- 原因：mig 258 的 firm_cause_court_ranking 近 5 年讀 lawyer_cause_court_stats、選年度或子類就對
--   lawyer_month_stats 即時展開 causes jsonb（臺北地院近 5 年 10.9 萬列），每次還要先掃全表求
--   max(yyyymm WHERE causes IS NOT NULL) 推視窗；mig 098／255 的 firm_cause_ranking／firm_cause_sub_ranking
--   是 LANGUAGE sql（generic plan，見 266 說明），而且四支函數的歸戶 CTE 都每次重算 lawyers_combined view。
--
-- 做法（與 266 同一套機制，同一支 refresh）：
--   lawyer_court_cause_year_stats：律師×法院×案由種類×子類×西元年，兩個量 cases（整年）／cases_win（近 5 年
--     滾動窗內月份）。只存 yr >= 視窗起始年。sub_group '' ＝該案由鍵沒有子類（cause_group_map.sub_group IS NULL）。
--     種類歸群與 lawyer_cause_stats／lawyer_cause_year_stats／lawyer_cause_court_stats 相同：LEFT JOIN cause_group_map，
--     對不到的鍵落回 split_part(ck, '|', 1)（即案類名；「行政」「其他」兩個種類本來就同時收規則內與落回鍵）。
--     實測 996,096 列、heap 112 MB、含索引 224 MB（258 當時估 200 MB 而不建；雷 2026-11-05 決定建）。
--   firm_map_sub_list：子類下拉清單落地（440 列），cause_sub_group_list 改讀這張。
--   firm_map_meta 加 cause_win_from／cause_win_to：causes 視窗以 max(yyyymm WHERE causes IS NOT NULL) 為準
--     （causefill 是另一條 workflow，新月份的 cats 可能先到、causes 後到；與 266 的 cats 視窗分開存）。
--   firm_cause_rank_core：三支事務所排名共用一支 plpgsql＋force_custom_plan 核心（不對外開放）；
--     firm_cause_court_ranking／firm_cause_ranking／firm_cause_sub_ranking 簽名、回傳欄、預設值不變，改成薄包裝。
--     歸戶改讀 lawyer_firm_lookup（266，規則與原 firm CTE 一字不差，每週五隨名冊週掃刷新）。
--     firm_cause_ranking 的 rank 排序加 firm_name tie-break（舊版同分順序不定）。
--   refresh_firm_map_preagg：尾端多建這兩張表＋更新 meta 的 causes 視窗；refresh_firm_map_cache 不用改。
--   p_year 口徑同舊版：整個西元年、不受視窗裁切；sub_group 篩選只對有子類的鍵有效（'' 不會被選到）。
--
-- 刷新時機：同 266——每週五本機 moj_detail_sweep_weekly.py、月更 judgment_stats.py refresh 鏈尾端、
--   judgment-groupfill.yml 尾端。子類規則（cause_group_map.sub_group generated column）改了要重跑
--   refresh_firm_map_cache 才會反映在版圖（258 即時算的好處不再；causemap-resync 已會重跑案由鏈，
--   之後若改規則記得也打 refresh_firm_map_cache）。
--
-- 驗證（2026-11-05 stage 版 _v268 與舊函數 EXCEPT 雙向，全部 0 筆差異、筆數相同）：
--   種類×法院 8 組：損害賠償×臺北（1000）、＋交通事故（769）、＋2025（1000）、＋交通事故＋2024（298）、
--     其他民法×臺中（1000）、詐欺×高雄×2023（266）、離婚×新北×離婚（本訴）（416）、行政×臺北高等行政法院（1000）
--   全國 8 組：損害賠償（4969）、損害賠償 2025（3953）、行政（3374）、詐欺 2022（2145）、
--     損害賠償／交通事故（1000）、同 2024（1000）、詐欺／加重詐欺（1000）、損害賠償 top10 含 rank（10）
--   cause_sub_group_list 440 列、件數與律師數逐列相同。
--   select * from firm_cause_court_ranking('損害賠償', '臺灣臺中地方法院') limit 3;  -- 莊子賢 477、嵩宬 182、真亮 179（同 258）

CREATE TABLE IF NOT EXISTS lawyer_court_cause_year_stats (
  name        text NOT NULL,
  court_name  text NOT NULL,
  cause_group text NOT NULL,
  sub_group   text NOT NULL DEFAULT '',   -- '' ＝ 該案由鍵沒有子類
  yr          int  NOT NULL,
  cases       int  NOT NULL,              -- 整個西元年
  cases_win   int  NOT NULL,              -- 只算近 5 年滾動窗內的月份
  PRIMARY KEY (cause_group, court_name, sub_group, yr, name)
);
-- 全國口徑（不選法院）的子類／年度查詢走這支；實測損害賠償／交通事故 17,263 列 index scan 11 ms
CREATE INDEX IF NOT EXISTS idx_lccys_group_sub_yr ON lawyer_court_cause_year_stats (cause_group, sub_group, yr);

CREATE TABLE IF NOT EXISTS firm_map_sub_list (
  cause_group text   NOT NULL,
  sub_group   text   NOT NULL,
  cases       bigint NOT NULL,   -- 近 5 年滾動窗內件數（律師人次）
  lawyers     int    NOT NULL,   -- 視窗內有該子類出庭紀錄的律師數
  PRIMARY KEY (cause_group, sub_group)
);

ALTER TABLE firm_map_meta ADD COLUMN IF NOT EXISTS cause_win_from text;   -- causes 視窗起月 YYYYMM
ALTER TABLE firm_map_meta ADD COLUMN IF NOT EXISTS cause_win_to   text;   -- causes 最新月 YYYYMM

ALTER TABLE lawyer_court_cause_year_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_map_sub_list             ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_read_lccys ON lawyer_court_cause_year_stats;
DROP POLICY IF EXISTS auth_read_fmsl  ON firm_map_sub_list;
CREATE POLICY auth_read_lccys ON lawyer_court_cause_year_stats FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY auth_read_fmsl  ON firm_map_sub_list             FOR SELECT USING (auth.uid() IS NOT NULL);

-- 預彙總重建（266 本體＋案由兩張表，約 45～60 秒）
CREATE OR REPLACE FUNCTION refresh_firm_map_preagg()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $$
DECLARE
  v_to    text;
  v_from  text;
  v_cto   text;
  v_cfrom text;
BEGIN
  SELECT max(l.yyyymm) INTO v_to FROM lawyer_month_stats l;
  IF v_to IS NULL THEN RETURN; END IF;
  v_from := to_char(to_date(v_to || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM');

  -- ---------- 266：律師×法院×案類×年 ----------
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

  -- ---------- 268：律師×法院×案由種類×子類×年 ----------
  -- causes 視窗自己算（causefill 另一條 workflow，可能比 cats 晚一個月到）
  SELECT max(l.yyyymm) INTO v_cto FROM lawyer_month_stats l WHERE l.causes IS NOT NULL;
  IF v_cto IS NOT NULL THEN
    v_cfrom := to_char(to_date(v_cto || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM');

    DROP TABLE IF EXISTS _fresh_lccys;
    CREATE TEMP TABLE _fresh_lccys ON COMMIT DROP AS
    SELECT l.name, l.court_name,
           coalesce(m.cause_group, split_part(k.key, '|', 1)) AS cause_group,   -- 同 lawyer_cause_*_stats 的落回規則
           coalesce(m.sub_group, '')                          AS sub_group,
           left(l.yyyymm, 4)::int                             AS yr,
           sum((k.value)::int)::int                           AS cases,
           sum(CASE WHEN l.yyyymm >= v_cfrom THEN (k.value)::int ELSE 0 END)::int AS cases_win
    FROM lawyer_month_stats l
    CROSS JOIN LATERAL jsonb_each_text(l.causes) k
    LEFT JOIN cause_group_map m ON m.ck = k.key
    WHERE l.yyyymm >= left(v_cfrom, 4) || '01' AND l.causes IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5;

    DELETE FROM lawyer_court_cause_year_stats WHERE true;
    INSERT INTO lawyer_court_cause_year_stats (name, court_name, cause_group, sub_group, yr, cases, cases_win)
    SELECT name, court_name, cause_group, sub_group, yr, cases, cases_win
    FROM _fresh_lccys
    ORDER BY cause_group, court_name, sub_group, yr, name;

    DELETE FROM firm_map_sub_list WHERE true;
    INSERT INTO firm_map_sub_list (cause_group, sub_group, cases, lawyers)
    SELECT cause_group, sub_group, sum(cases_win)::bigint, count(DISTINCT name)::int
    FROM _fresh_lccys
    WHERE sub_group <> '' AND cases_win > 0
    GROUP BY 1, 2;
  END IF;

  INSERT INTO firm_map_meta (id, win_from, win_to, refreshed_at, cause_win_from, cause_win_to)
  VALUES (1, v_from, v_to, now(), v_cfrom, v_cto)
  ON CONFLICT (id) DO UPDATE
    SET win_from = EXCLUDED.win_from, win_to = EXCLUDED.win_to, refreshed_at = EXCLUDED.refreshed_at,
        cause_win_from = EXCLUDED.cause_win_from, cause_win_to = EXCLUDED.cause_win_to;

  ANALYZE lawyer_court_cat_year_stats;
  ANALYZE lawyer_firm_lookup;
  ANALYZE lawyer_court_cause_year_stats;
  ANALYZE firm_map_sub_list;
END $$;
REVOKE EXECUTE ON FUNCTION refresh_firm_map_preagg() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION refresh_firm_map_preagg() TO service_role;

-- 三支事務所排名共用的核心（不對外開放；p_court／p_sub／p_year 為 NULL 即不篩）
CREATE OR REPLACE FUNCTION firm_cause_rank_core(p_group text, p_court text, p_sub text, p_year int, p_limit int)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
SET plan_cache_mode = 'force_custom_plan'
AS $$
#variable_conflict use_column
BEGIN
  IF p_group IS NULL THEN RETURN; END IF;
  RETURN QUERY
  WITH per AS (
    SELECT s.name, sum(CASE WHEN p_year IS NULL THEN s.cases_win ELSE s.cases END)::bigint AS c
    FROM lawyer_court_cause_year_stats s
    WHERE s.cause_group = p_group
      AND (p_court IS NULL OR s.court_name = p_court)
      AND (p_sub   IS NULL OR s.sub_group  = p_sub)
      AND (p_year  IS NULL OR s.yr         = p_year)
    GROUP BY s.name
    HAVING sum(CASE WHEN p_year IS NULL THEN s.cases_win ELSE s.cases END) > 0
  ), agg AS (
    SELECT f.firm_name AS fname, sum(p.c)::bigint AS cs, count(*)::int AS lcnt
    FROM per p JOIN lawyer_firm_lookup f ON f.name = p.name
    GROUP BY f.firm_name
  )
  SELECT (row_number() OVER (ORDER BY a.cs DESC, a.fname))::int, a.fname, a.cs, a.lcnt
  FROM agg a
  ORDER BY a.cs DESC, a.fname
  LIMIT p_limit;
END $$;
REVOKE EXECUTE ON FUNCTION firm_cause_rank_core(text, text, text, int, int) FROM PUBLIC, anon, authenticated;

-- 種類（＋子類／年度）×法院（mig 258 v1 同簽名）
CREATE OR REPLACE FUNCTION firm_cause_court_ranking(
  p_group text, p_court text, p_sub text DEFAULT NULL, p_year int DEFAULT NULL, p_limit int DEFAULT 1000)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM firm_cause_rank_core(p_group, p_court, p_sub, p_year, p_limit)
  WHERE p_court IS NOT NULL;
$$;

-- 種類全國（mig 070／098 同簽名；案由供需下鑽 csDrillRank 也用這支）
CREATE OR REPLACE FUNCTION firm_cause_ranking(p_group text, p_limit int DEFAULT 30, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM firm_cause_rank_core(p_group, NULL, NULL, p_year, p_limit);
$$;

-- 子類全國（mig 255 同簽名）
CREATE OR REPLACE FUNCTION firm_cause_sub_ranking(p_group text, p_sub text, p_limit int DEFAULT 1000, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM firm_cause_rank_core(p_group, NULL, p_sub, p_year, p_limit)
  WHERE p_sub IS NOT NULL;
$$;

-- 子類下拉清單（mig 255 同簽名；排序沿用 259 最後一版：具名子類依件數排，19 種程序類殿後、
--   「未標明」「其他」開頭的最後——首版 268 誤用 255 的兩個名稱，上線 20 分鐘內補正）
CREATE OR REPLACE FUNCTION cause_sub_group_list()
RETURNS TABLE (cause_group text, sub_group text, cases bigint, lawyers int)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '30s'
AS $$
  SELECT l.cause_group, l.sub_group, l.cases, l.lawyers
  FROM firm_map_sub_list l
  ORDER BY 1,
           CASE WHEN l.sub_group IN ('再審及程序事件', '再審、非常上訴與大法庭', '羈押、具保與強制處分', '刑之執行、沒收與扣押物', '其他聲請與程序', '羈押、具保與限制出境', '自訴、交付審判與訴訟參與', '閱卷、錄音與其他聲請', '訴訟救助、訴訟費用與裁判費（程序）', '程序事件（停止執行、假處分、訴訟救助、費用）', '程序事件', '督促程序（支付命令、公示催告）', '憲法審查與大法庭聲請', '律師酬金核定（程序）', '保全程序（假扣押、假處分、定暫時狀態）', '執行與保全爭議', '行政執行爭議', '程序監理人與特別代理人（含報酬）', '外國裁判認可與其他聲請') THEN 1
                WHEN l.sub_group ~ '^(未標明|其他)' THEN 2 ELSE 0 END,
           3 DESC;
$$;

GRANT EXECUTE ON FUNCTION firm_cause_court_ranking(text, text, text, int, int) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION firm_cause_ranking(text, int, int)                   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION firm_cause_sub_ranking(text, text, int, int)          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cause_sub_group_list()                                TO anon, authenticated;

-- 清掉 stage 暫名函數（正式庫 2026-11-05 比對用；新環境套用時 IF EXISTS 直接略過）
DROP FUNCTION IF EXISTS firm_cause_court_ranking_v268(text, text, text, int, int);
DROP FUNCTION IF EXISTS firm_cause_ranking_v268(text, int, int);
DROP FUNCTION IF EXISTS firm_cause_sub_ranking_v268(text, text, int, int);
DROP FUNCTION IF EXISTS cause_sub_group_list_v268();
DROP FUNCTION IF EXISTS firm_cause_rank_core_v268(text, text, text, int, int);
DROP FUNCTION IF EXISTS refresh_firm_map_cause_preagg_v268();

-- 首次填表（含 266 的三張表一起重建，約 1 分鐘）
SELECT refresh_firm_map_preagg();

NOTIFY pgrst, 'reload schema';
