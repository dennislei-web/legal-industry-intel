-- ============================================================
-- 255: 事務所版圖「損害賠償」子類下拉（8 子類）
-- ============================================================
-- 需求（雷 2026-11-03）：事務所版圖選「民事｜損害賠償」後要能再往下細分。
-- 素材：lawyer_month_stats.causes 存的是原始案由（鍵＝「民事|侵權行為損害賠償(交通)」），
--   損害賠償桶在 cause_group_map 有 3,068 鍵、近 5 年有件數的 372 種。
-- 不直接列原始字串的原因：同義異寫多（損害賠償／請求損害賠償／損害賠償等…），
--   且約 83% 件數的案由根本沒標類型。改用關鍵字歸成 8 個子類：
--     交通事故／侵害配偶權／醫療糾紛／智慧財產／國家賠償／債務不履行（契約）／
--     再審及程序事件／未標明類型
-- 規則依序比對、先中先贏；主題優先於程序（「(交通)再審之訴」算交通事故）。
--   最高法院裁定的案由常是整句（「一、台○○醫院與○○間請求損害賠償…事件」）、含當事人名，
--   所以刻意不用「醫院」「國家」「股份」這類會撞到當事人名稱的詞。
--   「再審及程序事件」＝再審之外再併入聲請／抗告／假扣押／管轄／承受訴訟等程序裁定，
--   否則這些字串會混進「未標明類型」。
--   近 5 年實測（律師端件數）：未標明 ≈14.1 萬、交通 ≈2.6 萬、債務不履行 ≈1,900、
--   配偶權 ≈750、再審及程序 ≈500、國賠 ≈290、智財 ≈240、醫療 ≈70；
--   名譽、詐欺、傷害等其他候選詞近 5 年都只有個位數，不另立子類。
--   ⚠️ 子類標註是法院近年才普及的加註習慣（套用後實測）：「(交通)」2021 年 326 件 → 2022 年 2,277
--   → 2025 年 7,200；「(侵害配偶身分法益)」2025 年以前合計 5 件、2026 年 1–8 月 745 件。
--   早年同類案件落在「未標明類型」，子類逐年變化≠市場變化；前端註腳已提醒優先看最近一年。
--
-- 實作：
--   cause_group_map.sub_group：generated column（規則寫在 DDL）。judgment_stats.py
--     upsert 新鍵只送 ck/cat/cause/cause_group，子類由 DB 自動算，不必改 ETL；
--     cause_map.py 改大類歸屬時也會跟著重算。要細分別的種類，在外層 CASE 加一支即可。
--   lawyer_cause_sub_stats：律師×子類×期間物化表。yr=0＝近 5 年滾動窗（同 lawyer_cause_stats），
--     其餘＝西元年（同 lawyer_cause_year_stats；只算滾動窗起始年以後，事務所版圖年度下拉只到這裡）。
--     掛進 refresh_lawyer_cause_stats() 尾端月更（整段重建實測約 6 秒）。
--   firm_cause_sub_ranking：事務所排名（歸戶口徑同 firm_cause_ranking：lawyers_combined 姓名唯一）。
--   cause_sub_group_list：子類下拉清單（近 5 年件數）。
-- 口徑同案由種類層：名目（律師人次，案由層沒有去重素材）、全國（法院篩選不適用）、
--   公開裁判書＝下限、事務所按現任名冊回溯。
--
-- ⚠️ 撈 causes 時用 JOIN cause_group_map（hash join）；寫成 k.key = ANY(<三千鍵陣列>)
--   或 causes ?| <陣列> 會逐列線性比對，同一段查詢從 6 秒變成超過 120 秒 timeout。

-- 1) 子類對照（generated column）
ALTER TABLE cause_group_map ADD COLUMN IF NOT EXISTS sub_group text GENERATED ALWAYS AS (
  CASE WHEN cause_group = '損害賠償' THEN
    CASE
      WHEN cause ~ '交通|車禍' THEN '交通事故'
      WHEN cause ~ '配偶|妨害婚姻|通姦|相姦' THEN '侵害配偶權'
      WHEN cause ~ '醫療|醫議|醫事|[(]醫[)]' THEN '醫療糾紛'
      WHEN cause ~ '智財|智慧財產|[(]智[)]|著作|專利|商標|營業秘密|植物品種' THEN '智慧財產'
      WHEN cause ~ '國家損害|國家賠償|國賠|[(]國家[)]' THEN '國家賠償'
      WHEN cause ~ '債務不履行|不完全給付|契約|違約' THEN '債務不履行（契約）'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任'
        THEN '再審及程序事件'
      ELSE '未標明類型'
    END
  END) STORED;
CREATE INDEX IF NOT EXISTS idx_cgm_sub ON cause_group_map (cause_group, sub_group) WHERE sub_group IS NOT NULL;

-- 2) 律師×子類×期間 物化表
CREATE TABLE IF NOT EXISTS lawyer_cause_sub_stats (
  cause_group text NOT NULL,
  sub_group   text NOT NULL,
  yr          int  NOT NULL,   -- 0＝近 5 年滾動窗；其餘＝西元年
  name        text NOT NULL,
  case_count  int  NOT NULL,
  PRIMARY KEY (cause_group, sub_group, yr, name)
);

ALTER TABLE lawyer_cause_sub_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_lcss" ON lawyer_cause_sub_stats;
CREATE POLICY "auth_read_lcss" ON lawyer_cause_sub_stats FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION refresh_lawyer_cause_sub_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET statement_timeout TO '900s' AS $$
DECLARE cutoff text;
BEGIN
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM')
    INTO cutoff FROM lawyer_month_stats WHERE causes IS NOT NULL;
  IF cutoff IS NULL THEN RETURN; END IF;

  DROP TABLE IF EXISTS _lcsub;
  CREATE TEMP TABLE _lcsub ON COMMIT DROP AS
    SELECT l.name, l.yyyymm, m.cause_group, m.sub_group, sum((k.value)::int)::int AS n
    FROM lawyer_month_stats l
    CROSS JOIN LATERAL jsonb_each_text(l.causes) k
    JOIN cause_group_map m ON m.ck = k.key AND m.sub_group IS NOT NULL
    WHERE l.causes IS NOT NULL AND l.yyyymm >= left(cutoff, 4) || '01'
    GROUP BY 1, 2, 3, 4;

  TRUNCATE lawyer_cause_sub_stats;
  INSERT INTO lawyer_cause_sub_stats (cause_group, sub_group, yr, name, case_count)
  SELECT cause_group, sub_group, 0, name, sum(n)::int
  FROM _lcsub WHERE yyyymm >= cutoff
  GROUP BY cause_group, sub_group, name
  UNION ALL
  SELECT cause_group, sub_group, left(yyyymm, 4)::int, name, sum(n)::int
  FROM _lcsub
  GROUP BY cause_group, sub_group, left(yyyymm, 4)::int, name;
END $$;
-- Supabase 預設權限會對新函式明確 GRANT anon/authenticated，只 REVOKE public 收不掉（實測 2026-11-03）
REVOKE EXECUTE ON FUNCTION refresh_lawyer_cause_sub_stats() FROM anon, authenticated, public;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_sub_stats() TO service_role;

-- 3) 事務所×子類 排名（p_year NULL＝近 5 年滾動窗）
CREATE OR REPLACE FUNCTION firm_cause_sub_ranking(p_group text, p_sub text, p_limit int DEFAULT 1000, p_year int DEFAULT NULL)
RETURNS TABLE (rank int, firm_name text, cases bigint, lawyer_count int) AS $$
  WITH per AS (
    SELECT s.name, s.case_count AS c
    FROM lawyer_cause_sub_stats s
    WHERE s.cause_group = p_group AND s.sub_group = p_sub AND s.yr = coalesce(p_year, 0)
  ), firm AS (  -- 歸戶口徑＝firm_cause_ranking／firm_court_ranking 的 firm CTE
    SELECT name, min(coalesce(substring(firm_name from '^(.*?事務所)'), firm_name)) AS firm_name,
           count(*) AS n
    FROM lawyers_combined
    WHERE firm_name IS NOT NULL AND firm_name NOT LIKE '%未提供%'
    GROUP BY name
  ), agg AS (
    SELECT f.firm_name, sum(p.c)::bigint AS cases, count(*)::int AS lawyer_count
    FROM per p JOIN firm f USING (name)
    WHERE f.n = 1
    GROUP BY f.firm_name
  )
  SELECT row_number() OVER (ORDER BY cases DESC, firm_name)::int, firm_name, cases, lawyer_count
  FROM agg ORDER BY cases DESC, firm_name LIMIT p_limit;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION firm_cause_sub_ranking(text, text, int, int) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION firm_cause_sub_ranking(text, text, int, int) TO anon, authenticated;

-- 4) 子類下拉清單（近 5 年件數；具名子類依件數排，程序事件與未標明殿後）
CREATE OR REPLACE FUNCTION cause_sub_group_list()
RETURNS TABLE (cause_group text, sub_group text, cases bigint, lawyers int) AS $$
  SELECT cause_group, sub_group, sum(case_count)::bigint, count(*)::int
  FROM lawyer_cause_sub_stats
  WHERE yr = 0
  GROUP BY 1, 2
  ORDER BY 1, CASE sub_group WHEN '未標明類型' THEN 2 WHEN '再審及程序事件' THEN 1 ELSE 0 END, 3 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_sub_group_list() SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_sub_group_list() TO anon, authenticated;

-- 5) 掛進月更鏈：重建 refresh_lawyer_cause_stats（沿用 182 全文＝線上 2026-11-03 dump 版，尾端多一個 PERFORM）
CREATE OR REPLACE FUNCTION refresh_lawyer_cause_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout TO '900s' AS $$
DECLARE cutoff text;
BEGIN
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM')
    INTO cutoff FROM lawyer_month_stats WHERE causes IS NOT NULL;
  IF cutoff IS NULL THEN RETURN; END IF;

  CREATE TEMP TABLE _lc ON COMMIT DROP AS
    SELECT l.name, k.key AS ck, sum((k.value)::int)::int AS n
    FROM lawyer_month_stats l, jsonb_each_text(l.causes) k
    WHERE l.causes IS NOT NULL AND l.yyyymm >= cutoff
    GROUP BY 1, 2;

  TRUNCATE lawyer_cause_stats;
  INSERT INTO lawyer_cause_stats (name, cases_5yr, by_group, top_causes)
  SELECT c.name, c.total, g.by_group, t.top_causes
  FROM (SELECT name, sum(n)::int AS total FROM _lc GROUP BY 1) c
  JOIN (
    SELECT name, jsonb_object_agg(grp, gn) AS by_group FROM (
      SELECT l.name, coalesce(m.cause_group, split_part(l.ck, '|', 1)) AS grp,
             sum(l.n)::int AS gn
      FROM _lc l LEFT JOIN cause_group_map m ON m.ck = l.ck
      GROUP BY 1, 2) s
    GROUP BY name) g USING (name)
  JOIN (
    SELECT name, jsonb_agg(jsonb_build_array(ck, n) ORDER BY n DESC) AS top_causes FROM (
      SELECT name, ck, n, row_number() OVER (PARTITION BY name ORDER BY n DESC) AS rn
      FROM _lc) s
    WHERE rn <= 20
    GROUP BY name) t USING (name);

  -- 案由種類鑽取表（同一份 _lc，多一次 rollup）
  TRUNCATE cause_group_causes;
  INSERT INTO cause_group_causes (cause_group, cat, total, distinct_causes, top_causes)
  WITH agg AS (
    SELECT coalesce(m.cause_group, split_part(l.ck, '|', 1)) AS grp,
           coalesce(m.cat, split_part(l.ck, '|', 1)) AS cat,
           coalesce(m.cause, split_part(l.ck, '|', 2)) AS cause,
           sum(l.n)::bigint AS n
    FROM _lc l LEFT JOIN cause_group_map m ON m.ck = l.ck
    GROUP BY 1, 2, 3
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY grp ORDER BY n DESC) AS rn FROM agg
  )
  SELECT grp, min(cat), sum(n)::bigint, count(*)::int,
         coalesce(jsonb_agg(jsonb_build_array(cause, n) ORDER BY n DESC)
                  FILTER (WHERE rn <= 40), '[]'::jsonb)
  FROM ranked GROUP BY grp;

  -- 年度下鑽表（mig 098；巢狀呼叫有自己的 statement_timeout）
  PERFORM refresh_lawyer_cause_year_stats();
  -- 法院層物化表（mig 182）
  PERFORM refresh_lawyer_cause_court_stats();
  -- 損害賠償子類物化表（mig 255）
  PERFORM refresh_lawyer_cause_sub_stats();
END $$;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_stats() TO service_role;

-- 首次建置子類物化表
SELECT refresh_lawyer_cause_sub_stats();
NOTIFY pgrst, 'reload schema';
