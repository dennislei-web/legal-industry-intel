-- 038: 月統計表法院/檢察署名正規化（v2）
-- 早年（~2001 前）裁判書全文開頭有 OCR 雜訊：前綴雜字黏在官方名前
-- （「號臺灣高等法院」「公同共有賣房臺灣新北地方法院」）、缺字錯字
-- （「臺灣桃園法院」「臺灣臺北方法院」「慧財產法院」「壹灣高等法院」），
-- 導致同法院被拆成多列、前端名單出現怪名。
-- judgment_stats.py 已同步 normalize_court()；本 migration 清既有資料。
-- v2 策略：①內文含完整官方名 → 取之（剝前綴雜字）②缺字錯字依地名/層級
-- 錨定修復 ③修不了歸「未知法院/未知檢察署」（月包可 reprocess 重建，非不可逆）。
-- merge_dirty_court_names() 可重複執行（冪等）——歷史回填跑完後應再呼叫一次，
-- 因為回填程序若仍用舊版腳本（或舊 agg 快取）會再寫入未正規化的名稱。

CREATE OR REPLACE FUNCTION fix_court_name(t text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  n text := translate(t, '台褔', '臺福');
  m text[];
BEGIN
  -- 「行政法院」是 2000 年改制前唯一行政法院的官方名，保留
  IF n IN ('未知法院', '未知檢察署', '行政法院') THEN
    RETURN n;
  END IF;
  -- ① 內文含完整官方名（含分院/分署）→ 取第一個 match（ARE 最左最長，
  --    「臺灣XX地方法院檢察署」舊名會整段被檢察署 alternative 吃掉不會誤判成法院）
  m := regexp_match(n,
    '((臺灣|福建)[一-鿿]{2,3}地方(法院)?檢察署'
    || '|(臺灣|福建)高等(法院)?檢察署([一-鿿]{2,4}(檢察)?分署)?'
    || '|最高(法院)?檢察署'
    || '|(臺灣|福建)[一-鿿]{2,3}地方法院([一-鿿]{2,3}分院)?'
    || '|(臺灣|福建)高等法院([一-鿿]{2,3}分院)?'
    || '|臺灣高雄少年(及家事)?法院'
    || '|最高行政法院|最高法院'
    || '|(臺北|臺中|高雄)高等行政法院'
    || '|智慧財產(及商業)?法院'
    || '|懲戒法院|公務員懲戒委員會)');
  IF m IS NOT NULL THEN RETURN m[1]; END IF;
  -- ② 高等行政法院缺字（「北高等行政法院」「高雄高等行政訴法院」）
  m := regexp_match(n, '(臺北|臺中|高雄|北|中|雄)高等行政');
  IF m IS NOT NULL THEN
    RETURN CASE m[1] WHEN '北' THEN '臺北' WHEN '中' THEN '臺中'
                     WHEN '雄' THEN '高雄' ELSE m[1] END || '高等行政法院';
  END IF;
  -- ③ 高等法院分院變體（「臺灣高等臺南分院法院」「臺灣花蓮高等法院」）
  m := regexp_match(n, '^臺灣高等(臺中|臺南|高雄|花蓮)分院');
  IF m IS NULL THEN
    m := regexp_match(n, '^(臺灣)?(臺中|臺南|高雄|花蓮)高等法院$');
    IF m IS NOT NULL THEN m := ARRAY[m[2]]; END IF;
  END IF;
  IF m IS NOT NULL THEN RETURN '臺灣高等法院' || m[1] || '分院'; END IF;
  -- ④ 地院/地檢缺字錯字：地名錨定＋結尾錨定（「臺灣桃園法院」「臺灣臺北方法院」
  --    「臺灣彰化地堂法院」「臺灣臺中地方地方檢察署」）
  IF n !~ '高等|少年|行政' THEN
    m := regexp_match(n, '(臺北|新北|士林|板橋|桃園|新竹|苗栗|臺中|南投|彰化|雲林|嘉義|臺南|高雄|橋頭|屏東|臺東|花蓮|宜蘭|基隆|澎湖|金門|連江)[一-鿿]{0,8}法院$');
    IF m IS NOT NULL THEN
      RETURN CASE WHEN m[1] IN ('金門','連江') THEN '福建' ELSE '臺灣' END
             || m[1] || '地方法院';
    END IF;
    m := regexp_match(n, '(臺北|新北|士林|板橋|桃園|新竹|苗栗|臺中|南投|彰化|雲林|嘉義|臺南|高雄|橋頭|屏東|臺東|花蓮|宜蘭|基隆|澎湖|金門|連江)[一-鿿]{0,8}檢察署$');
    IF m IS NOT NULL THEN
      RETURN CASE WHEN m[1] IN ('金門','連江') THEN '福建' ELSE '臺灣' END
             || m[1] || '地方檢察署';
    END IF;
  END IF;
  -- ⑤ 高等法院錯字（「臺灣等法院」「臺灣高法院」「壹灣高等法院」「高等法院」光桿）
  --    須含臺/壹/灣/等其中一字，避免把「疫高法院」（最高法院錯字）誤修成高院
  IF n ~ '^[一-鿿]{1,3}(高等?|等)法?法院$' AND n ~ '[臺壹灣等]' AND n !~ '最' THEN
    RETURN '臺灣高等法院';
  END IF;
  -- ⑥ 智財缺字（「慧財產法院」）
  IF n ~ '慧財產' THEN
    RETURN CASE WHEN n ~ '及商業' THEN '智慧財產及商業法院' ELSE '智慧財產法院' END;
  END IF;
  -- ⑦ 修不了 → 歸未知，避免怪名進前端名單
  RETURN CASE WHEN n ~ '檢察署' THEN '未知檢察署' ELSE '未知法院' END;
END $fn$;

CREATE OR REPLACE FUNCTION merge_dirty_court_names()
RETURNS TABLE(tbl text, merged_groups bigint)
SET statement_timeout = '600s'
AS $$
BEGIN
  -- ========== judge_month_stats ==========
  CREATE TEMP TABLE _grp AS
    SELECT DISTINCT m.name, fix_court_name(m.court_name) AS cn, m.yyyymm
    FROM judge_month_stats m WHERE m.court_name <> fix_court_name(m.court_name);
  CREATE TEMP TABLE _rows AS
    SELECT m.name, fix_court_name(m.court_name) AS cn, m.yyyymm,
           m.case_count, m.sum_days, m.n_days, m.cats
    FROM judge_month_stats m
    JOIN _grp g ON g.name = m.name AND g.yyyymm = m.yyyymm
               AND g.cn = fix_court_name(m.court_name);
  CREATE TEMP TABLE _cats AS
    SELECT name, cn, yyyymm, jsonb_object_agg(k, v) AS cats FROM (
      SELECT r.name, r.cn, r.yyyymm, e.key AS k, sum((e.value)::int) AS v
      FROM _rows r, jsonb_each_text(coalesce(r.cats, '{}'::jsonb)) e
      GROUP BY r.name, r.cn, r.yyyymm, e.key) x
    GROUP BY name, cn, yyyymm;
  CREATE TEMP TABLE _merged AS
    SELECT r.name, r.cn, r.yyyymm,
           sum(r.case_count)::int AS case_count,
           sum(r.sum_days)::bigint AS sum_days,
           sum(r.n_days)::int AS n_days,
           c.cats
    FROM _rows r LEFT JOIN _cats c USING (name, cn, yyyymm)
    GROUP BY r.name, r.cn, r.yyyymm, c.cats;
  DELETE FROM judge_month_stats m USING _grp g
    WHERE m.name = g.name AND m.yyyymm = g.yyyymm
      AND fix_court_name(m.court_name) = g.cn;
  INSERT INTO judge_month_stats (name, court_name, yyyymm, case_count, sum_days, n_days, cats)
    SELECT name, cn, yyyymm, case_count, sum_days, n_days, cats FROM _merged;
  tbl := 'judge_month_stats'; SELECT count(*) INTO merged_groups FROM _grp;
  RETURN NEXT;
  DROP TABLE _grp; DROP TABLE _rows; DROP TABLE _cats; DROP TABLE _merged;

  -- ========== lawyer_month_stats ==========
  CREATE TEMP TABLE _grp AS
    SELECT DISTINCT m.name, fix_court_name(m.court_name) AS cn, m.yyyymm
    FROM lawyer_month_stats m WHERE m.court_name <> fix_court_name(m.court_name);
  CREATE TEMP TABLE _rows AS
    SELECT m.name, fix_court_name(m.court_name) AS cn, m.yyyymm, m.case_count, m.cats
    FROM lawyer_month_stats m
    JOIN _grp g ON g.name = m.name AND g.yyyymm = m.yyyymm
               AND g.cn = fix_court_name(m.court_name);
  CREATE TEMP TABLE _cats AS
    SELECT name, cn, yyyymm, jsonb_object_agg(k, v) AS cats FROM (
      SELECT r.name, r.cn, r.yyyymm, e.key AS k, sum((e.value)::int) AS v
      FROM _rows r, jsonb_each_text(coalesce(r.cats, '{}'::jsonb)) e
      GROUP BY r.name, r.cn, r.yyyymm, e.key) x
    GROUP BY name, cn, yyyymm;
  CREATE TEMP TABLE _merged AS
    SELECT r.name, r.cn, r.yyyymm, sum(r.case_count)::int AS case_count, c.cats
    FROM _rows r LEFT JOIN _cats c USING (name, cn, yyyymm)
    GROUP BY r.name, r.cn, r.yyyymm, c.cats;
  DELETE FROM lawyer_month_stats m USING _grp g
    WHERE m.name = g.name AND m.yyyymm = g.yyyymm
      AND fix_court_name(m.court_name) = g.cn;
  INSERT INTO lawyer_month_stats (name, court_name, yyyymm, case_count, cats)
    SELECT name, cn, yyyymm, case_count, cats FROM _merged;
  tbl := 'lawyer_month_stats'; SELECT count(*) INTO merged_groups FROM _grp;
  RETURN NEXT;
  DROP TABLE _grp; DROP TABLE _rows; DROP TABLE _cats; DROP TABLE _merged;

  -- ========== prosecutor_month_stats ==========
  CREATE TEMP TABLE _grp AS
    SELECT DISTINCT m.name, fix_court_name(m.office_name) AS cn, m.yyyymm
    FROM prosecutor_month_stats m WHERE m.office_name <> fix_court_name(m.office_name);
  CREATE TEMP TABLE _rows AS
    SELECT m.name, fix_court_name(m.office_name) AS cn, m.yyyymm, m.case_count, m.cats
    FROM prosecutor_month_stats m
    JOIN _grp g ON g.name = m.name AND g.yyyymm = m.yyyymm
               AND g.cn = fix_court_name(m.office_name);
  CREATE TEMP TABLE _cats AS
    SELECT name, cn, yyyymm, jsonb_object_agg(k, v) AS cats FROM (
      SELECT r.name, r.cn, r.yyyymm, e.key AS k, sum((e.value)::int) AS v
      FROM _rows r, jsonb_each_text(coalesce(r.cats, '{}'::jsonb)) e
      GROUP BY r.name, r.cn, r.yyyymm, e.key) x
    GROUP BY name, cn, yyyymm;
  CREATE TEMP TABLE _merged AS
    SELECT r.name, r.cn, r.yyyymm, sum(r.case_count)::int AS case_count, c.cats
    FROM _rows r LEFT JOIN _cats c USING (name, cn, yyyymm)
    GROUP BY r.name, r.cn, r.yyyymm, c.cats;
  DELETE FROM prosecutor_month_stats m USING _grp g
    WHERE m.name = g.name AND m.yyyymm = g.yyyymm
      AND fix_court_name(m.office_name) = g.cn;
  INSERT INTO prosecutor_month_stats (name, office_name, yyyymm, case_count, cats)
    SELECT name, cn, yyyymm, case_count, cats FROM _merged;
  tbl := 'prosecutor_month_stats'; SELECT count(*) INTO merged_groups FROM _grp;
  RETURN NEXT;
  DROP TABLE _grp; DROP TABLE _rows; DROP TABLE _cats; DROP TABLE _merged;
END $$ LANGUAGE plpgsql SECURITY DEFINER;

SELECT * FROM merge_dirty_court_names();
