-- 248：法律產業薪資分析第二版（2026-10-11）
-- 1) lawyer_cohort_retention() 修正：原本用「當年最大號－前一年最大號」算發證量，少數離群證號（92 年有一個 6212 號落在
--    93 年號段、96 年有 309 號、104 年有 12802 號、108 年有 566–569 一小撮）讓相鄰年份一高一低，93 年比例衝到 126%。
--    改法：證號依流水號排序，(a) 前後鄰居都不是同一年、或 (b) 離該年中位數超過 3 倍 P05–P95 寬度的證號視為離群剔除；
--    發證量＝次年最小號－本年最小號（最後一年用本年最大號）。
-- 2) 公部門法定薪給種子（labor_comp_series）：法官俸表 24 級俸點（法官法附表）＋115 年俸點對俸額（人事處公教人員給與簡明表 115/03，
--    114/01/01 起未變）＋法官加給例示（立法院議案關係文書 2015：710 俸點法官專業加給 91,070、職務加給 29,370；依 107+3%、111+4%、
--    113+4%、114+3% 通案調幅推算到現行，職務加給推算值 33,730 與現行簡任 13 職等主管加給表相符）＋司法官學員津貼規則（司法院常見問答：
--    委任五職等本俸五級 370 俸點＋專業加給表一委任五職等月支數額）＋法官助理／檢察官助理薪點制（114 年甄選簡章折合率 135、
--    115 年臺北地檢署公告 360 薪點＝50,076 → 折合率 139.1）＋公職王 2026 整理的司法特考各職務月薪（民間整理，含加給估算）。
-- 3) 銓敘部「行政機關公務人員人數按機關別分」司法行政機關類別 102–112 年（法官檢察官人數、平均年齡、平均年資）。

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
  s AS (
    SELECT yr, serial,
           lag(yr) OVER (ORDER BY serial, yr) AS prev_yr,
           lead(yr) OVER (ORDER BY serial, yr) AS next_yr
    FROM p WHERE serial IS NOT NULL AND yr BETWEEN 55 AND 130
  ),
  st AS (
    SELECT yr,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY serial) AS med,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY serial) - percentile_cont(0.05) WITHIN GROUP (ORDER BY serial) AS spread
    FROM s GROUP BY yr
  ),
  clean AS (
    SELECT s.yr, s.serial
    FROM s JOIN st USING (yr)
    WHERE NOT (s.prev_yr IS DISTINCT FROM s.yr AND s.next_yr IS DISTINCT FROM s.yr)
      AND abs(s.serial - st.med) <= GREATEST(3 * st.spread, 200)
  ),
  bounds AS (SELECT yr, min(serial) AS lo_serial, max(serial) AS hi_serial FROM clean GROUP BY yr),
  cnt AS (
    SELECT yr, count(*)::int AS scanned,
           count(*) FILTER (WHERE deregistered_at IS NULL AND state_desc = '正常')::int AS active
    FROM p WHERE yr BETWEEN 55 AND 130 GROUP BY yr
  ),
  d AS (
    SELECT b.yr,
           COALESCE(lead(b.lo_serial) OVER (ORDER BY b.yr) - b.lo_serial, b.hi_serial - b.lo_serial + 1)::int AS issued,
           c.scanned, c.active
    FROM bounds b JOIN cnt c USING (yr)
  )
  SELECT yr, issued, scanned, active,
         CASE WHEN issued > 0 THEN round(active::numeric / issued, 3) END
  FROM d WHERE yr >= 85 AND issued > 0 ORDER BY yr;
$$;
GRANT EXECUTE ON FUNCTION lawyer_cohort_retention() TO authenticated, anon;

-- ---------- 種子：法官俸表 24 級（俸點＋115 年俸額）----------
INSERT INTO labor_comp_series (source, role, metric, period, category, sort, stat, value, unit, n, note) VALUES
('moj_judge_scale','judge','grade','115','第1級',1,'points',800,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第2級',2,'points',790,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第3級',3,'points',780,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第4級',4,'points',750,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第5級',5,'points',730,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第6級',6,'points',710,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第7級',7,'points',690,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第8級',8,'points',670,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第9級',9,'points',650,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第10級',10,'points',630,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第11級',11,'points',610,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第12級',12,'points',590,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第13級',13,'points',550,'俸點',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第14級',14,'points',535,'俸點',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第15級',15,'points',520,'俸點',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第16級',16,'points',505,'俸點',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第17級',17,'points',490,'俸點',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第18級',18,'points',475,'俸點',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第19級',19,'points',460,'俸點',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第20級',20,'points',445,'俸點',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第21級',21,'points',430,'俸點',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第22級',22,'points',415,'俸點',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第23級',23,'points',400,'俸點',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第24級',24,'points',385,'俸點',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第1級',1,'base_pay',63570,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第2級',2,'base_pay',60290,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第3級',3,'base_pay',59520,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第4級',4,'base_pay',57220,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第5級',5,'base_pay',55690,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第6級',6,'base_pay',54160,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第7級',7,'base_pay',52630,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第8級',8,'base_pay',51100,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第9級',9,'base_pay',49560,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第10級',10,'base_pay',48030,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第11級',11,'base_pay',46500,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第12級',12,'base_pay',44970,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第13級',13,'base_pay',41900,'元/月',NULL,'實任'),
('moj_judge_scale','judge','grade','115','第14級',14,'base_pay',40760,'元/月',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第15級',15,'base_pay',39610,'元/月',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第16級',16,'base_pay',38460,'元/月',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第17級',17,'base_pay',37310,'元/月',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第18級',18,'base_pay',36160,'元/月',NULL,'試署'),
('moj_judge_scale','judge','grade','115','第19級',19,'base_pay',35010,'元/月',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第20級',20,'base_pay',33860,'元/月',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第21級',21,'base_pay',32710,'元/月',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第22級',22,'base_pay',31560,'元/月',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第23級',23,'base_pay',30410,'元/月',NULL,'候補'),
('moj_judge_scale','judge','grade','115','第24級',24,'base_pay',29270,'元/月',NULL,'候補'),
-- 起敘級（法官法 §71）
('moj_judge_scale','judge','entry_grade','115','候補法官起敘',1,'grade',24,'級',NULL,'法官法 §71；候補 5 年、每年晉一級'),
('moj_judge_scale','judge','entry_grade','115','試署法官起敘',2,'grade',22,'級',NULL,'法官法 §71'),
('moj_judge_scale','judge','entry_grade','115','實任法官起敘',3,'grade',20,'級',NULL,'法官法 §71'),
('moj_judge_scale','judge','entry_grade','115','律師執業 6 年轉任',4,'grade',22,'級',NULL,'法官法 §71 第 5 項'),
('moj_judge_scale','judge','entry_grade','115','律師執業 8 年轉任',5,'grade',21,'級',NULL,NULL),
('moj_judge_scale','judge','entry_grade','115','律師執業 10 年轉任',6,'grade',20,'級',NULL,NULL),
('moj_judge_scale','judge','entry_grade','115','律師執業 14 年轉任',7,'grade',17,'級',NULL,NULL),
('moj_judge_scale','judge','entry_grade','115','律師執業 18 年轉任',8,'grade',15,'級',NULL,NULL),
-- 法官加給例示（立法院議案關係文書 2015）與推算
('ly_doc_2015','judge','allowance_example','2015','專業加給（710 俸點法官）',1,'amount',91070,'元/月',NULL,'立法院第 8 屆第 7 會期議案關係文書：原薦任九職等年功俸七級 710 俸點法官改任換敘後本俸 6 級'),
('ly_doc_2015','judge','allowance_example','2015','職務加給（710 俸點法官）',2,'amount',29370,'元/月',NULL,'同上'),
('ly_doc_2015','judge','allowance_est','115','專業加給（710 俸點法官，推算）',1,'amount',104500,'元/月',NULL,'91,070 × 1.03（107）× 1.04（111）× 1.04（113）× 1.03（114）；115/7/1 起另定額加 2,000（行政院 116 年待遇方案追溯）'),
('ly_doc_2015','judge','allowance_est','115','職務加給（710 俸點法官，推算）',2,'amount',33730,'元/月',NULL,'29,370 × 同幅度＝33,730，與現行簡任 13 職等主管職務加給表 33,730 相符'),
('ly_doc_2015','judge','allowance_est','115','專業加給定額調增（115/7/1 起）',3,'amount',2000,'元/月',NULL,'行政院 116 年軍公教待遇方案：專業加給、主管職務加給定額調增 2,000，追溯自 115/7/1'),
-- 司法官學員津貼（司法院常見問答規則 × 115 年官方表）
('tpi_trainee_rule','judicial_trainee','monthly_allowance','115','本俸（委任五職等本俸五級 370 俸點）',1,'amount',28120,'元/月',NULL,'司法院常見問答：學員津貼比照委任第五職等本俸五級 370 俸點'),
('tpi_trainee_rule','judicial_trainee','monthly_allowance','115','專業加給（表一委任五職等）',2,'amount',22730,'元/月',NULL,'公務人員專業加給表【一】委任第五職等月支數額（115/03 簡明表）；115/7/1 起另加 2,000'),
('tpi_trainee_rule','judicial_trainee','monthly_allowance','115','合計',3,'amount',50850,'元/月',NULL,'106 年問答之合計為 46,460（26,200＋20,260）'),
-- 法官助理／檢察官助理（薪點制）
('court_assistant_notice','judge_assistant','monthly_pay_by_points','114','大學 360 薪點',1,'amount',48600,'元/月',NULL,'114 年聘用法官助理（法律專長）甄選簡章，折合率 135'),
('court_assistant_notice','judge_assistant','monthly_pay_by_points','114','大學＋專技高考 376 薪點',2,'amount',50760,'元/月',NULL,NULL),
('court_assistant_notice','judge_assistant','monthly_pay_by_points','114','碩士 392 薪點',3,'amount',52920,'元/月',NULL,NULL),
('court_assistant_notice','judge_assistant','monthly_pay_by_points','114','碩士＋專技高考 408 薪點',4,'amount',55080,'元/月',NULL,NULL),
('court_assistant_notice','judge_assistant','monthly_pay_by_points','114','博士 424 薪點',5,'amount',57240,'元/月',NULL,NULL),
('court_assistant_notice','judge_assistant','monthly_pay_by_points','114','博士＋專技高考 440 薪點',6,'amount',59400,'元/月',NULL,NULL),
('court_assistant_notice','prosecutor_assistant','monthly_pay_by_points','115','360 薪點起敘',1,'amount',50076,'元/月',NULL,'臺北地檢署約用檢察官助理徵選公告（1111 轉載），折合率 139.1'),
('court_assistant_notice','prosecutor_assistant','monthly_pay_by_points','115','高考及格 376 薪點',2,'amount',52301,'元/月',NULL,NULL),
-- 司法特考各職務月薪（公職王 2026 整理，民間、含加給估算）
('public_com_tw_2026','court_staff','monthly_pay_est','115','三等法院書記官（薦任六職等）',1,'amount',56000,'元/月',NULL,'另有紀錄加給 6,070 與加班費；116 年試算約 60,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','四等法院書記官（委任三職等）',2,'amount',43000,'元/月',NULL,'另有值勤費、加班費等；116 年試算約 47,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','法警（委任三職等）',3,'amount',47000,'元/月',NULL,'含危險加給；116 年約 51,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','執達員／執行員（委任三職等）',4,'amount',43000,'元/月',NULL,'116 年約 47,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','錄事／庭務員（委任一職等）',5,'amount',35000,'元/月',NULL,'116 年約 38,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','司法事務官／檢察事務官（薦任七職等）',6,'amount',91000,'元/月',NULL,'116 年約 97,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','觀護人／家事調查官（薦任七職等）',7,'amount',65000,'元/月',NULL,'116 年約 70,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','法院公證人（薦任七職等）',8,'amount',60000,'元/月',NULL,'116 年約 64,000'),
('public_com_tw_2026','court_staff','monthly_pay_est','115','行政執行官（薦任八職等）',9,'amount',100000,'元/月',NULL,'頁面寫 10 萬以上'),
-- 銓敘部：司法行政機關（法院＋檢察機關）公務人員
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','102','102',102,'mean',14.12,'年',NULL,'銓敘部「行政機關公務人員人數按機關別分」司法行政機關類別'),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','103','103',103,'mean',14.33,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','104','104',104,'mean',14.37,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','105','105',105,'mean',14.41,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','106','106',106,'mean',14.53,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','107','107',107,'mean',14.61,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','108','108',108,'mean',14.57,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','109','109',109,'mean',14.70,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','110','110',110,'mean',14.98,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','111','111',111,'mean',14.97,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_seniority','112','112',112,'mean',14.90,'年',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_age','102','102',102,'mean',42.62,'歲',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','avg_age','112','112',112,'mean',43.94,'歲',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','judge_prosecutor_count','102','102',102,'count',3353,'位',NULL,'官等別「法官檢察官」欄'),
('mocs_judicial_admin','judicial_admin_staff','judge_prosecutor_count','107','107',107,'count',3476,'位',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','judge_prosecutor_count','112','112',112,'count',3614,'位',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','total_staff','102','102',102,'count',25133,'位',NULL,NULL),
('mocs_judicial_admin','judicial_admin_staff','total_staff','112','112',112,'count',27247,'位',NULL,NULL)
ON CONFLICT (source, role, metric, period, category, stat) DO UPDATE
  SET value = EXCLUDED.value, unit = EXCLUDED.unit, n = EXCLUDED.n, note = EXCLUDED.note, sort = EXCLUDED.sort;

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('法官俸表／公務人員俸額表（法定薪給階梯）', 'https://law.moj.gov.tw/LawClass/LawSingle.aspx?pcode=A0030243&flno=71', '法官法附表 24 級俸點＋115 年俸點對俸額（公教人員給與簡明表）＋立法院 2015 加給例示推算；種子入 labor_comp_series（mig 248），調薪時手動更新', 'salary', 'manual', 'yearly'),
  ('銓敘部 行政機關公務人員人數按機關別分', 'https://data.gov.tw/dataset/152198', '司法行政機關類別 102–112 年：法官檢察官人數、平均年齡、平均年資（cp950 CSV，年更不定期）', 'salary', 'manual', 'yearly')
ON CONFLICT (name) DO NOTHING;

DO $$
DECLARE c int; bad int; yrs int;
BEGIN
  SELECT count(*) INTO c FROM labor_comp_series WHERE source = 'moj_judge_scale' AND metric = 'grade';
  IF c <> 48 THEN RAISE EXCEPTION 'judge scale rows=% (<>48)', c; END IF;
  SELECT count(*) INTO bad FROM lawyer_cohort_retention() WHERE ratio > 1 OR ratio < 0.2 OR issued > 2000;
  IF bad > 0 THEN RAISE EXCEPTION 'cohort retention still has implausible rows: %', bad; END IF;
  SELECT count(*) INTO yrs FROM lawyer_cohort_retention() WHERE lic_year BETWEEN 90 AND 115;
  IF yrs <> 26 THEN RAISE EXCEPTION 'cohort retention years 90-115 = % (<>26)', yrs; END IF;
END $$;
