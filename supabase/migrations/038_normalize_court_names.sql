-- 038: 月統計表法院/檢察署名正規化（v3）
-- 早年（~2001 前）裁判書是 OCR 全文，法院名有三類雜質：
--   前綴雜字（「號臺灣高等法院」「公同共有賣房臺灣新北地方法院」）、
--   缺字錯字（「臺灣桃園法院」「壹灣高等法院」「慧財產法院」）、
--   重複段（「板橋臺灣板橋地方法院」「臺灣臺灣新竹地方法院」），
-- 導致同法院被拆成多列、前端名單出現怪名。
-- fix_court_name() 與 scripts/judgment_stats.py 的 normalize_court() 同構
-- （族群判斷＋地名白名單錨定，修不了歸未知），改一邊要同步另一邊。
--
-- merge_dirty_court_names(tbl) 冪等，可重複執行；歷史回填跑完後應再各跑一次。
-- ⚠️ 透過 supabase db query（Management API）呼叫有 ~100s gateway 上限，
--    請一表一次分開呼叫：
--      SELECT * FROM merge_dirty_court_names('judge_month_stats');
--      SELECT * FROM merge_dirty_court_names('lawyer_month_stats');
--      SELECT * FROM merge_dirty_court_names('prosecutor_month_stats');
--    跑完後 refresh：SELECT refresh_judge_judgment_stats(); SELECT refresh_prosecutor_stats();

CREATE OR REPLACE FUNCTION fix_court_name(t text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  n text := translate(t, '台褔', '臺福');
  m text[];
  loc text;
BEGIN
  -- OCR 常見錯字地名（僅收形近且無歧義者）
  n := replace(n, '土林', '士林'); n := replace(n, '喜義', '嘉義');
  n := replace(n, '彭湖', '澎湖'); n := replace(n, '扳橋', '板橋');
  n := replace(n, '板僑', '板橋'); n := replace(n, '板穚', '板橋');
  n := replace(n, '抬東', '臺東'); n := replace(n, '屏動', '屏東');
  n := replace(n, '壹中', '臺中');
  -- 「行政法院」是 2000 年改制前唯一行政法院的官方名，保留
  IF n IN ('未知法院', '未知檢察署', '行政法院') THEN
    RETURN n;
  END IF;
  IF n LIKE '%少年%' AND (n LIKE '%家事%' OR n LIKE '%高雄%') THEN
    RETURN '臺灣高雄少年及家事法院';
  END IF;
  -- ── 檢察署族 ──
  IF n LIKE '%檢察%' THEN
    IF n LIKE '%最高%' THEN RETURN '最高檢察署'; END IF;
    IF n LIKE '%高等%' THEN
      m := regexp_match(n, '(臺中|臺南|高雄|花蓮|金門)檢?察?分署|(智慧財產)檢?察?分署');
      IF m IS NOT NULL THEN
        loc := coalesce(m[1], m[2]);
        IF loc = '金門' THEN RETURN '福建高等檢察署金門檢察分署'; END IF;
        RETURN '臺灣高等檢察署' || loc || '檢察分署';
      END IF;
      RETURN CASE WHEN n LIKE '%福建%' OR n LIKE '%金門%'
                  THEN '福建高等檢察署' ELSE '臺灣高等檢察署' END;
    END IF;
    m := regexp_match(n, '(臺北|新北|士林|板橋|桃園|新竹|苗栗|臺中|南投|彰化|雲林|嘉義|臺南|高雄|橋頭|屏東|臺東|花蓮|宜蘭|基隆|澎湖|金門|連江)');
    IF m IS NOT NULL THEN
      RETURN CASE WHEN m[1] IN ('金門','連江') THEN '福建' ELSE '臺灣' END
             || m[1] || '地方檢察署';
    END IF;
    RETURN '未知檢察署';
  END IF;
  -- ── 行政法院族 ──
  IF n LIKE '%最高行政%' THEN RETURN '最高行政法院'; END IF;
  m := regexp_match(n, '(臺北|臺中|高雄|北|中|雄)高等.{0,2}[行政]');
  IF m IS NOT NULL THEN
    RETURN CASE m[1] WHEN '北' THEN '臺北' WHEN '中' THEN '臺中'
                     WHEN '雄' THEN '高雄' ELSE m[1] END || '高等行政法院';
  END IF;
  IF n LIKE '%行政%' THEN RETURN '未知法院'; END IF;  -- 光桿「高等行政法院」無從判定北/中/高
  -- ── 高等法院族 ──
  IF n LIKE '%高等%' THEN
    m := regexp_match(n, '高等(法院)?(臺中|臺南|高雄|花蓮)');
    IF m IS NULL THEN
      m := regexp_match(n, '^(臺灣)?(臺中|臺南|高雄|花蓮)高等法院$');
    END IF;
    IF m IS NOT NULL THEN RETURN '臺灣高等法院' || m[2] || '分院'; END IF;
    IF n LIKE '%金門%' THEN RETURN '福建高等法院金門分院'; END IF;
    IF n LIKE '%福建%' THEN RETURN '福建高等法院'; END IF;
    RETURN '臺灣高等法院';
  END IF;
  IF n LIKE '%最高法院%' THEN RETURN '最高法院'; END IF;
  IF n LIKE '%智慧%' OR n LIKE '%慧財產%' THEN
    RETURN CASE WHEN n LIKE '%商業%' THEN '智慧財產及商業法院' ELSE '智慧財產法院' END;
  END IF;
  IF n LIKE '%懲戒%' THEN
    RETURN CASE WHEN n LIKE '%委員會%' THEN '公務員懲戒委員會' ELSE '懲戒法院' END;
  END IF;
  -- ── 地方法院族：地名白名單錨定 ──
  m := regexp_match(n, '(臺北|新北|士林|板橋|桃園|新竹|苗栗|臺中|南投|彰化|雲林|嘉義|臺南|高雄|橋頭|屏東|臺東|花蓮|宜蘭|基隆|澎湖|金門|連江)');
  IF m IS NOT NULL THEN
    RETURN CASE WHEN m[1] IN ('金門','連江') THEN '福建' ELSE '臺灣' END
           || m[1] || '地方法院';
  END IF;
  -- 高等法院缺字錯字（「臺灣等法院」「臺灣高法院」；須含臺/壹/灣/等，
  -- 避免把「疫高法院」（最高法院錯字）誤修成高院）
  IF n ~ '^[一-鿿]{1,3}(高等?|等)法?法院$' AND n ~ '[臺壹灣等]' AND n NOT LIKE '%最%' THEN
    RETURN '臺灣高等法院';
  END IF;
  RETURN CASE WHEN n LIKE '%檢察署%' THEN '未知檢察署' ELSE '未知法院' END;
END $fn$;

-- cats jsonb（案類→件數）key-wise 加總
CREATE OR REPLACE FUNCTION jsonb_add_counts(a jsonb, b jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) FROM (
    SELECT key AS k, sum(value::numeric)::int AS v FROM (
      SELECT * FROM jsonb_each_text(coalesce(a, '{}'::jsonb))
      UNION ALL
      SELECT * FROM jsonb_each_text(coalesce(b, '{}'::jsonb))
    ) u GROUP BY key
  ) s
$$;

CREATE OR REPLACE AGGREGATE jsonb_sum_counts(jsonb) (
  SFUNC = jsonb_add_counts, STYPE = jsonb, INITCOND = '{}');

-- 舊版（無參數、不同回傳型別）需先移除
DROP FUNCTION IF EXISTS merge_dirty_court_names();
DROP FUNCTION IF EXISTS merge_dirty_court_names(text);

-- 把髒名列合併進正規名列（加總 case_count/sum_days/n_days、cats key-wise 相加）。
-- mapping 只在 distinct 名稱層計算（~700 個），避免全表逐列呼叫 plpgsql regex。
-- DELETE...RETURNING + INSERT...ON CONFLICT 單一 statement，原子且冪等。
CREATE OR REPLACE FUNCTION merge_dirty_court_names(p_tbl text)
RETURNS TABLE(tbl text, dirty_names bigint, moved_rows bigint)
SET statement_timeout = '600s'
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  tbl := p_tbl;
  IF p_tbl = 'judge_month_stats' THEN
    CREATE TEMP TABLE _map AS
      SELECT d.court_name AS old, fix_court_name(d.court_name) AS cn
      FROM (SELECT DISTINCT court_name FROM judge_month_stats) d
      WHERE d.court_name <> fix_court_name(d.court_name);
    SELECT count(*) INTO dirty_names FROM _map;
    WITH del AS (
      DELETE FROM judge_month_stats m USING _map p WHERE m.court_name = p.old
      RETURNING m.name, p.cn, m.yyyymm, m.case_count, m.sum_days, m.n_days, m.cats
    ), agg AS (
      SELECT name, cn, yyyymm, sum(case_count)::int AS cc, sum(sum_days)::bigint AS sd,
             sum(n_days)::int AS nd, jsonb_sum_counts(cats) AS cats
      FROM del GROUP BY name, cn, yyyymm
    )
    INSERT INTO judge_month_stats (name, court_name, yyyymm, case_count, sum_days, n_days, cats)
    SELECT name, cn, yyyymm, cc, sd, nd, cats FROM agg
    ON CONFLICT (name, court_name, yyyymm) DO UPDATE SET
      case_count = judge_month_stats.case_count + EXCLUDED.case_count,
      sum_days   = judge_month_stats.sum_days   + EXCLUDED.sum_days,
      n_days     = judge_month_stats.n_days     + EXCLUDED.n_days,
      cats       = jsonb_add_counts(judge_month_stats.cats, EXCLUDED.cats);
    GET DIAGNOSTICS moved_rows = ROW_COUNT;
    DROP TABLE _map;
  ELSIF p_tbl = 'lawyer_month_stats' THEN
    CREATE TEMP TABLE _map AS
      SELECT d.court_name AS old, fix_court_name(d.court_name) AS cn
      FROM (SELECT DISTINCT court_name FROM lawyer_month_stats) d
      WHERE d.court_name <> fix_court_name(d.court_name);
    SELECT count(*) INTO dirty_names FROM _map;
    WITH del AS (
      DELETE FROM lawyer_month_stats m USING _map p WHERE m.court_name = p.old
      RETURNING m.name, p.cn, m.yyyymm, m.case_count, m.cats
    ), agg AS (
      SELECT name, cn, yyyymm, sum(case_count)::int AS cc, jsonb_sum_counts(cats) AS cats
      FROM del GROUP BY name, cn, yyyymm
    )
    INSERT INTO lawyer_month_stats (name, court_name, yyyymm, case_count, cats)
    SELECT name, cn, yyyymm, cc, cats FROM agg
    ON CONFLICT (name, court_name, yyyymm) DO UPDATE SET
      case_count = lawyer_month_stats.case_count + EXCLUDED.case_count,
      cats       = jsonb_add_counts(lawyer_month_stats.cats, EXCLUDED.cats);
    GET DIAGNOSTICS moved_rows = ROW_COUNT;
    DROP TABLE _map;
  ELSIF p_tbl = 'prosecutor_month_stats' THEN
    CREATE TEMP TABLE _map AS
      SELECT d.office_name AS old, fix_court_name(d.office_name) AS cn
      FROM (SELECT DISTINCT office_name FROM prosecutor_month_stats) d
      WHERE d.office_name <> fix_court_name(d.office_name);
    SELECT count(*) INTO dirty_names FROM _map;
    WITH del AS (
      DELETE FROM prosecutor_month_stats m USING _map p WHERE m.office_name = p.old
      RETURNING m.name, p.cn, m.yyyymm, m.case_count, m.cats
    ), agg AS (
      SELECT name, cn, yyyymm, sum(case_count)::int AS cc, jsonb_sum_counts(cats) AS cats
      FROM del GROUP BY name, cn, yyyymm
    )
    INSERT INTO prosecutor_month_stats (name, office_name, yyyymm, case_count, cats)
    SELECT name, cn, yyyymm, cc, cats FROM agg
    ON CONFLICT (name, office_name, yyyymm) DO UPDATE SET
      case_count = prosecutor_month_stats.case_count + EXCLUDED.case_count,
      cats       = jsonb_add_counts(prosecutor_month_stats.cats, EXCLUDED.cats);
    GET DIAGNOSTICS moved_rows = ROW_COUNT;
    DROP TABLE _map;
  ELSE
    RAISE EXCEPTION '未知的表名: %', p_tbl;
  END IF;
  RETURN NEXT;
END $$;
