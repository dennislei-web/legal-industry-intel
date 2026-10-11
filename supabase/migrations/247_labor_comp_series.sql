-- 247：喆律戰情＞法律產業薪資分析（2026-10-11）
-- 1) labor_comp_series：薪酬／年資「長表」——外部調查、官方統計、法定俸給都以 source×role×metric×category 一列一數字放這裡，
--    前端不寫死數字。visibility='public' 的列可經 RPC 給前端；admin 專用列（將來喆律人資池級）走 RLS。
-- 2) labor_seniority_dist()：律師／法官／檢察官的年資分布（即時算，三種口徑各自標明）。
-- 3) lawyer_cohort_retention()：各年「發證量（檢證字證號序列差）」對「名冊現職」＝仍在執業登錄比例（下限）。
-- 4) 種子：Lawsnote JobBoard《2023 台灣律師職涯市場報告》（問卷 2022-12～2023-01，430 份；已公開發布，可引用）。
--    年薪×年資那條線是讀圖估值（原圖無標數字），其餘為報告標示的百分比。

CREATE TABLE IF NOT EXISTS labor_comp_series (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source      text NOT NULL,                 -- lawsnote_jobboard_2023 / mol_occupation_survey / dgbas_m69 / pay_scale_judge ...
  role        text NOT NULL,                 -- associate_lawyer / law_firm / lawyer_employee / judge / clerk ...
  metric      text NOT NULL,                 -- annual_pay_by_seniority / annual_pay_dist / exit_reason ...
  period      text,                          -- '2023'、'2022-12~2023-01'、'115'
  category    text,                          -- 級距／年資帶／原因等類別標籤
  sort        int  NOT NULL DEFAULT 0,
  stat        text NOT NULL DEFAULT 'share', -- share / median / median_est / mean / min / max / count / p25 / p75
  value       numeric,
  unit        text,                          -- % / 萬元/年 / 千元/月 / 位
  n           int,
  note        text,
  visibility  text NOT NULL DEFAULT 'public',
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (source, role, metric, period, category, stat)
);
CREATE INDEX IF NOT EXISTS idx_lcs_source_metric ON labor_comp_series(source, role, metric);
ALTER TABLE labor_comp_series ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS labor_comp_series_read ON labor_comp_series;
CREATE POLICY labor_comp_series_read ON labor_comp_series FOR SELECT TO authenticated
  USING (visibility = 'public' OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));
COMMENT ON TABLE labor_comp_series IS '法律產業薪酬／年資長表（喆律戰情＞法律產業薪資分析）：一列一數字，source×role×metric×category；public 列由 labor_comp_series_get() 供前端';

-- 前端取數（只給 public 列；admin 專用列將來另開 RPC）
CREATE OR REPLACE FUNCTION labor_comp_series_get(p_source text DEFAULT NULL)
RETURNS SETOF labor_comp_series
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM labor_comp_series
  WHERE visibility = 'public' AND (p_source IS NULL OR source = p_source)
  ORDER BY source, role, metric, sort, id;
$$;
GRANT EXECUTE ON FUNCTION labor_comp_series_get(text) TO authenticated, anon;

-- 年資帶（全站統一七段）
CREATE OR REPLACE FUNCTION labor_band(yrs int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN yrs IS NULL THEN NULL
              WHEN yrs <= 2 THEN '0–2 年' WHEN yrs <= 5 THEN '3–5 年' WHEN yrs <= 10 THEN '6–10 年'
              WHEN yrs <= 15 THEN '11–15 年' WHEN yrs <= 20 THEN '16–20 年' WHEN yrs <= 30 THEN '21–30 年'
              ELSE '31 年以上' END;
$$;
CREATE OR REPLACE FUNCTION labor_band_sort(yrs int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN yrs IS NULL THEN NULL
              WHEN yrs <= 2 THEN 1 WHEN yrs <= 5 THEN 2 WHEN yrs <= 10 THEN 3
              WHEN yrs <= 15 THEN 4 WHEN yrs <= 20 THEN 5 WHEN yrs <= 30 THEN 6 ELSE 7 END;
$$;

-- 年資結構：律師＝法務部名冊 practice_start_date（執業起始年，與證號年 99.85% 一致）；
-- 法官＝judges_combined.seniority_years（司法院名冊無到職日，全部是裁判書首判年推估）；
-- 檢察官＝裁判書首現年，現職口徑同 prosecutor_active_summary（近 12 個月具名且累計具名 ≥12 個資料月）。
CREATE OR REPLACE FUNCTION labor_seniority_dist()
RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH yr AS (SELECT extract(year from now())::int AS y),
  lw AS (
    SELECT (SELECT y FROM yr) - left(practice_start_date, 4)::int AS yrs
    FROM moj_lawyers
    WHERE deregistered_at IS NULL AND state_desc = '正常' AND practice_start_date ~ '^[0-9]{4}'
  ),
  jd AS (
    SELECT seniority_years AS yrs FROM judges_combined WHERE has_jy AND seniority_years IS NOT NULL
  ),
  pm AS (
    SELECT name, min(yyyymm) AS first_m, max(yyyymm) AS last_m, count(DISTINCT yyyymm) AS months
    FROM prosecutor_month_stats GROUP BY name
  ),
  latest AS (SELECT max(yyyymm) AS m FROM prosecutor_month_stats),
  pr AS (
    SELECT (SELECT y FROM yr) - left(first_m, 4)::int AS yrs
    FROM pm
    WHERE months >= 12
      AND last_m >= to_char(to_date((SELECT m FROM latest), 'YYYYMM') - interval '11 months', 'YYYYMM')
  ),
  agg AS (
    SELECT 'lawyers' AS role, yrs FROM lw WHERE yrs BETWEEN 0 AND 70
    UNION ALL SELECT 'judges', yrs FROM jd WHERE yrs BETWEEN 0 AND 70
    UNION ALL SELECT 'prosecutors', yrs FROM pr WHERE yrs BETWEEN 0 AND 70
  ),
  bands AS (
    SELECT role, labor_band_sort(yrs) AS sort, labor_band(yrs) AS band, count(*)::int AS n
    FROM agg GROUP BY 1, 2, 3
  ),
  stats AS (
    SELECT role, count(*)::int AS n,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY yrs)::numeric, 1) AS median,
           round(avg(yrs)::numeric, 1) AS mean,
           round(100.0 * count(*) FILTER (WHERE yrs <= 5) / count(*), 1) AS share_le5,
           round(100.0 * count(*) FILTER (WHERE yrs > 20) / count(*), 1) AS share_gt20
    FROM agg GROUP BY role
  ),
  per_role AS (
    SELECT s.role, json_build_object(
      'n', s.n, 'median', s.median, 'mean', s.mean, 'share_le5', s.share_le5, 'share_gt20', s.share_gt20,
      'bands', (SELECT json_agg(json_build_object('band', b.band, 'sort', b.sort, 'n', b.n) ORDER BY b.sort) FROM bands b WHERE b.role = s.role)
    ) AS j
    FROM stats s
  )
  SELECT json_build_object(
    'asof', to_char(now(), 'YYYY-MM-DD'),
    'year', (SELECT y FROM yr),
    'latest_pros_month', (SELECT m FROM latest),
    'lawyers', (SELECT j FROM per_role WHERE role = 'lawyers'),
    'judges', (SELECT j FROM per_role WHERE role = 'judges'),
    'prosecutors', (SELECT j FROM per_role WHERE role = 'prosecutors')
  );
$$;
GRANT EXECUTE ON FUNCTION labor_seniority_dist() TO authenticated, anon;

-- 發證世代留存：檢證字證號流水號跨年連續，當年發證量＝該年最大號－前一年最大號；
-- 名冊現職（正常、未除名）÷發證量＝仍在執業登錄比例。補證字／外檢證字排除。
-- 注意：名冊是證號遍歷掃到的（最新一兩年新科律師尚未入會登錄＋每週掃描時差），近兩年比例偏低屬正常。
CREATE OR REPLACE FUNCTION lawyer_cohort_retention()
RETURNS TABLE(lic_year int, issued int, scanned int, active int, ratio numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH p AS (
    SELECT (substring(lic_no from '^[(]?([0-9]+)'))::int AS yr,
           (substring(lic_no from '第([0-9]+)號'))::int AS serial,
           deregistered_at, state_desc
    FROM moj_lawyers
    WHERE lic_no LIKE '%檢證字%' AND lic_no NOT LIKE '%補證%' AND lic_no NOT LIKE '%外檢%'
  ),
  y AS (
    SELECT yr, max(serial) AS mx, count(*)::int AS scanned,
           count(*) FILTER (WHERE deregistered_at IS NULL AND state_desc = '正常')::int AS active
    FROM p WHERE yr BETWEEN 60 AND 130 AND serial IS NOT NULL GROUP BY yr
  ),
  d AS (
    SELECT yr, (mx - lag(mx) OVER (ORDER BY yr))::int AS issued, scanned, active FROM y
  )
  SELECT yr, issued, scanned, active,
         CASE WHEN issued > 0 THEN round(active::numeric / issued, 3) END
  FROM d WHERE yr >= 85 AND issued IS NOT NULL ORDER BY yr;
$$;
GRANT EXECUTE ON FUNCTION lawyer_cohort_retention() TO authenticated, anon;

-- ---------- 種子：Lawsnote JobBoard 2023 ----------
INSERT INTO labor_comp_series (source, role, metric, period, category, sort, stat, value, unit, n, note) VALUES
-- 樣本
('lawsnote_jobboard_2023','meta','sample','2023','總份數',1,'count',430,'份',NULL,'問卷 2022-12～2023-01，2023-03 發布；受僱律師與律所兩部分'),
('lawsnote_jobboard_2023','meta','sample','2023','受僱律師問卷',2,'count',320,'份',NULL,'約數，由圖中最小百分比 0.3% 反推'),
('lawsnote_jobboard_2023','meta','sample','2023','律所問卷',3,'count',110,'份',NULL,'約數，由圖中最小百分比 0.9% 反推'),
-- 受僱律師：年薪×年資（讀圖估值）
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','1 年以下',1,'median_est',60,'萬元/年',NULL,'p.15 折線讀圖估值；年薪含年終與獎金、不含自接案抽成'),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','1–3 年',2,'median_est',80,'萬元/年',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','3–5 年',3,'median_est',100,'萬元/年',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','5–7 年',4,'median_est',100,'萬元/年',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','7–9 年',5,'median_est',100,'萬元/年',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','9–11 年',6,'median_est',100,'萬元/年',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','11–13 年',7,'median_est',120,'萬元/年',NULL,'11 年以上三段合計僅約 7.5% 樣本'),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','13–15 年',8,'median_est',130,'萬元/年',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_by_seniority','2023','15 年以上',9,'median_est',180,'萬元/年',NULL,'報告：11 年以上多任職中大所'),
-- 受僱律師：年資分布
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','1 年以下',1,'share',20.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','1–3 年',2,'share',29.7,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','3–5 年',3,'share',21.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','5–7 年',4,'share',10.6,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','7–9 年',5,'share',6.8,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','9–11 年',6,'share',3.8,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','11–13 年',7,'share',2.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','13–15 年',8,'share',1.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','seniority_dist','2023','15 年以上',9,'share',3.1,'%',NULL,NULL),
-- 受僱律師：年薪分布
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','50 萬以下',1,'share',5.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','51–70 萬',2,'share',15.6,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','71–90 萬',3,'share',35.3,'%',NULL,'眾數區間'),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','91–110 萬',4,'share',23.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','111–130 萬',5,'share',7.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','131–150 萬',6,'share',1.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','151–170 萬',7,'share',3.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','171–190 萬',8,'share',1.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','191–210 萬',9,'share',2.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','211–230 萬',10,'share',1.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','231–250 萬',11,'share',0.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','annual_pay_dist','2023','251 萬以上',12,'share',3.2,'%',NULL,NULL),
-- 受僱律師：離開前所原因
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','不滿意薪資待遇',1,'share',21.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','想轉換其他案件類型',2,'share',17.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','其他規劃（開業、in-house、公務）',3,'share',15.0,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','工時太長',4,'share',14.0,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','和老闆相處不睦',5,'share',13.4,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','其他',6,'share',6.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','exit_reason','2023','和同事相處不睦',7,'share',6.3,'%',NULL,NULL),
-- 受僱律師：期待薪資
('lawsnote_jobboard_2023','associate_lawyer','expected_next_pay','2023','目前年薪 80 萬者',1,'median',105,'萬元/年',NULL,'對下一份工作的期待年薪；漲幅中位約 25 萬；各薪資段的漲幅中位多在 50 萬以下'),
-- 受僱律師：輪廓
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','25 歲以下',1,'share',1.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','26–30 歲',2,'share',41.8,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','31–35 歲',3,'share',32.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','36–40 歲',4,'share',11.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','41–45 歲',5,'share',6.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','46–50 歲',6,'share',5.6,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','age_dist','2023','51 歲以上',7,'share',1.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','台北',1,'share',74,'%',NULL,'公會口徑北律約 60%'),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','台中',2,'share',9,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','高雄',3,'share',6.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','台南',4,'share',3.4,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','桃園',5,'share',3.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','新竹',6,'share',1.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','region_dist','2023','其他',7,'share',2.8,'%',NULL,'苗栗、嘉義、屏東、離島合計'),
('lawsnote_jobboard_2023','associate_lawyer','education_dist','2023','國內碩士',1,'share',54.4,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','education_dist','2023','大學',2,'share',36.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','education_dist','2023','國外碩士',3,'share',6.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','education_dist','2023','國內外博士',4,'share',1.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','gender_dist','2023','生理男',1,'share',57.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','associate_lawyer','gender_dist','2023','生理女',2,'share',38.8,'%',NULL,'男女薪資分布無明顯差異（p.14）'),
-- 律所端
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','90–110 萬',1,'share',56.3,'%',NULL,'律所內受僱律師最高年薪'),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','111–130 萬',2,'share',10.0,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','131–150 萬',3,'share',12.7,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','151–170 萬',4,'share',5.4,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','171–190 萬',5,'share',3.6,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','191–210 萬',6,'share',4.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','211–230 萬',7,'share',2.7,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','251–290 萬',8,'share',1.8,'%',NULL,'251–270 與 271–290 各 0.9%'),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','331–370 萬',9,'share',1.8,'%',NULL,'331–350 與 351–370 各 0.9%'),
('lawsnote_jobboard_2023','law_firm','top_associate_pay_dist','2023','411 萬以上',10,'share',1.8,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','origination_share','2023','自接案抽成',1,'mean',32.8,'%',NULL,'受僱律師自接案可抽成比例'),
('lawsnote_jobboard_2023','law_firm','origination_share','2023','自接案抽成',1,'median',30,'%',NULL,'半數律所抽成 ≤30%，不少為 0'),
('lawsnote_jobboard_2023','law_firm','origination_share','2023','自接案抽成',1,'min',0,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','origination_share','2023','自接案抽成',1,'max',100,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','associate_tenure_dist','2023','1 年以下',1,'share',6.8,'%',NULL,'律所觀察：一位受僱律師平均待多久'),
('lawsnote_jobboard_2023','law_firm','associate_tenure_dist','2023','1–3 年',2,'share',61.6,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','associate_tenure_dist','2023','3–5 年',3,'share',21.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','associate_tenure_dist','2023','5–7 年',4,'share',4.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','associate_tenure_dist','2023','7–9 年',5,'share',1.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','associate_tenure_dist','2023','9 年以上',6,'share',4.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','independent_after_dist','2023','1 年以下',1,'share',9.2,'%',NULL,'律所觀察：受僱律師執業多久可獨立作業'),
('lawsnote_jobboard_2023','law_firm','independent_after_dist','2023','1–3 年',2,'share',52.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','independent_after_dist','2023','3–5 年',3,'share',32.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','independent_after_dist','2023','5–7 年',4,'share',5.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','independent_after_dist','2023','7–9 年',5,'share',0.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','founder_seniority_dist','2023','1 年以下',1,'share',15.5,'%',NULL,'創辦人執業多久出來開業'),
('lawsnote_jobboard_2023','law_firm','founder_seniority_dist','2023','1–3 年',2,'share',30.9,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','founder_seniority_dist','2023','3–5 年',3,'share',21.8,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','founder_seniority_dist','2023','5–7 年',4,'share',16.4,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','founder_seniority_dist','2023','7–9 年',5,'share',5.5,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','founder_seniority_dist','2023','10 年以上',6,'share',10.0,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','interviews_to_hire_dist','2023','1–5 位',1,'share',61.6,'%',NULL,'補一個受僱律師缺要面試幾位'),
('lawsnote_jobboard_2023','law_firm','interviews_to_hire_dist','2023','6–10 位',2,'share',30.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','interviews_to_hire_dist','2023','11–15 位',3,'share',8.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','1 人',1,'share',26.3,'%',NULL,'填答律所規模'),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','2 人',2,'share',12.7,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','3–5 人',3,'share',32.7,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','6–10 人',4,'share',18.1,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','11–20 人',5,'share',6.3,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','21–50 人',6,'share',1.8,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','firm_size_dist','2023','51 人以上',7,'share',2.1,'%',NULL,'餘數推算'),
('lawsnote_jobboard_2023','law_firm','benefit_share','2023','提供實質指導',1,'share',96,'%',NULL,'律所自述'),
('lawsnote_jobboard_2023','law_firm','benefit_share','2023','補助常年會費／跨區執業費',2,'share',82,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','benefit_share','2023','提供教育訓練',3,'share',73,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','benefit_share','2023','補助入會費',4,'share',69,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','benefit_share','2023','可遠端工作',5,'share',68,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','benefit_share','2023','僱用前會做資歷查核',6,'share',94.6,'%',NULL,'5.4% 不會'),
('lawsnote_jobboard_2023','law_firm','hiring_caseload_trigger_dist','2023','20 件以下',1,'share',5.5,'%',NULL,'律所評估需再請一位受僱律師的案件量'),
('lawsnote_jobboard_2023','law_firm','hiring_caseload_trigger_dist','2023','21–30 件',2,'share',26.0,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','hiring_caseload_trigger_dist','2023','31–40 件',3,'share',19.2,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','hiring_caseload_trigger_dist','2023','41–50 件',4,'share',24.7,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','hiring_caseload_trigger_dist','2023','51–60 件',5,'share',16.4,'%',NULL,NULL),
('lawsnote_jobboard_2023','law_firm','hiring_caseload_trigger_dist','2023','61 件以上',6,'share',8.2,'%',NULL,'61–70 4.1%、71–80 2.7%、81 以上 1.4%'),
-- 報告引述的勞動部職類別薪資調查（法律服務業×律師及相關專業人員，近五年月總薪資）
('mol_occupation_survey_quoted','lawyer_employee','monthly_total_pay_range','2018–2022','月總薪資下限',1,'min',98,'千元/月',NULL,'Lawsnote 報告 p.12 引述勞動部職類別薪資調查動態查詢；報告稱逐年倒退'),
('mol_occupation_survey_quoted','lawyer_employee','monthly_total_pay_range','2018–2022','月總薪資上限',2,'max',105,'千元/月',NULL,NULL)
ON CONFLICT (source, role, metric, period, category, stat) DO UPDATE
  SET value = EXCLUDED.value, unit = EXCLUDED.unit, n = EXCLUDED.n, note = EXCLUDED.note, sort = EXCLUDED.sort;

-- 資料來源登記
INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('Lawsnote JobBoard 律師職涯市場報告 2023', 'https://jobboard.lawsnote.com/', '問卷 2022-12～2023-01、430 份（受僱律師約 320／律所約 110）；受僱律師年薪×年資、年薪分布、離職原因、在職年限、抽成等；種子入 labor_comp_series（mig 247）', 'salary', 'manual', 'once')
ON CONFLICT (name) DO NOTHING;

-- 驗證
DO $$
DECLARE c int;
BEGIN
  SELECT count(*) INTO c FROM labor_comp_series WHERE source = 'lawsnote_jobboard_2023';
  IF c < 100 THEN RAISE EXCEPTION 'lawsnote seed rows=% (<100)', c; END IF;
  PERFORM labor_seniority_dist();
  PERFORM count(*) FROM lawyer_cohort_retention();
END $$;
