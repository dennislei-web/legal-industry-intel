-- 249：法律產業薪資分析——勞動部職類別薪資調查官方序列（2026-10-12）
-- 法律服務業（行業 6910／691）× 律師（2003–2010 職類名「律師」、2011 起「律師及相關專業人員」）每年 7 月調查：
--   2003–2019：政大勞工所碩士論文《台灣受僱律師勞動條件之研究》（2020）表 3-26 整理自勞動部動態查詢（2007 年缺）；
--   2020–2025：各年《職類別薪資調查報告》表 15「專業、科學及技術服務業全時受僱員工」法律服務業欄（109、110 年報為 7 月總薪資／經常性／非經常性；
--   111 年報起改列「前一年全年薪資所得」：111 年報為 110/8–111/7 的 12 個月總薪資，112 年報起為前一年扣繳憑單薪資所得）。
--   同表另有法務人員、專利工程師及公證人、土地代書、專業秘書（111 年報起）與法律服務業全體全時員工。
-- period＝西元年（7 月調查年；全年所得列為所得年），sort＝西元年，n＝該列人數（薪資列）。取代先前只引述報告區間的 mol_occupation_survey_quoted。

DELETE FROM labor_comp_series WHERE source = 'mol_occupation_survey_quoted';

INSERT INTO labor_comp_series (source, role, metric, period, category, sort, stat, value, unit, n, note) VALUES
-- 律師：人數
('mol_occupation_survey','lawyer_employee','employees','2003','2003 年 7 月',2003,'count',334,'位',NULL,'政大論文表 3-26（勞動部動態查詢）'),
('mol_occupation_survey','lawyer_employee','employees','2004','2004 年 7 月',2004,'count',418,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2005','2005 年 7 月',2005,'count',280,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2006','2006 年 7 月',2006,'count',600,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2008','2008 年 7 月',2008,'count',770,'位',NULL,'2007 年動態查詢缺'),
('mol_occupation_survey','lawyer_employee','employees','2009','2009 年 7 月',2009,'count',586,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2010','2010 年 7 月',2010,'count',507,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2011','2011 年 7 月',2011,'count',592,'位',NULL,'2011 起職類改「律師及相關專業人員」'),
('mol_occupation_survey','lawyer_employee','employees','2012','2012 年 7 月',2012,'count',530,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2013','2013 年 7 月',2013,'count',595,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2014','2014 年 7 月',2014,'count',864,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2015','2015 年 7 月',2015,'count',1209,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2016','2016 年 7 月',2016,'count',990,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2017','2017 年 7 月',2017,'count',1515,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2018','2018 年 7 月',2018,'count',1249,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2019','2019 年 7 月',2019,'count',1406,'位',NULL,NULL),
('mol_occupation_survey','lawyer_employee','employees','2020','2020 年 7 月',2020,'count',1328,'位',NULL,'109 年報表 15'),
('mol_occupation_survey','lawyer_employee','employees','2021','2021 年 7 月',2021,'count',1390,'位',NULL,'110 年報表 15'),
('mol_occupation_survey','lawyer_employee','employees','2022','2022 年 7 月',2022,'count',1125,'位',NULL,'111 年報表 15'),
('mol_occupation_survey','lawyer_employee','employees','2023','2023 年 7 月',2023,'count',1940,'位',NULL,'112 年報表 15（人數依普查基準校正，與歷年不宜比較）'),
('mol_occupation_survey','lawyer_employee','employees','2024','2024 年 7 月',2024,'count',2025,'位',NULL,'113 年報表 15'),
('mol_occupation_survey','lawyer_employee','employees','2025','2025 年 7 月',2025,'count',1968,'位',NULL,'114 年報表 15'),
-- 律師：7 月經常性薪資（元／月）
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2003','2003 年 7 月',2003,'mean',85984,'元/月',334,'政大論文表 3-26'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2004','2004 年 7 月',2004,'mean',81246,'元/月',418,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2005','2005 年 7 月',2005,'mean',85390,'元/月',280,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2006','2006 年 7 月',2006,'mean',53885,'元/月',600,'該年異常低'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2008','2008 年 7 月',2008,'mean',89500,'元/月',770,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2009','2009 年 7 月',2009,'mean',75319,'元/月',586,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2010','2010 年 7 月',2010,'mean',81229,'元/月',507,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2011','2011 年 7 月',2011,'mean',78295,'元/月',592,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2012','2012 年 7 月',2012,'mean',76426,'元/月',530,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2013','2013 年 7 月',2013,'mean',93545,'元/月',595,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2014','2014 年 7 月',2014,'mean',79494,'元/月',864,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2015','2015 年 7 月',2015,'mean',79036,'元/月',1209,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2016','2016 年 7 月',2016,'mean',93146,'元/月',990,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2017','2017 年 7 月',2017,'mean',88809,'元/月',1515,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2018','2018 年 7 月',2018,'mean',93805,'元/月',1249,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2019','2019 年 7 月',2019,'mean',93607,'元/月',1406,NULL),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2020','2020 年 7 月',2020,'mean',91933,'元/月',1328,'109 年報表 15'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2021','2021 年 7 月',2021,'mean',90469,'元/月',1390,'110 年報表 15'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2022','2022 年 7 月',2022,'mean',92326,'元/月',1125,'111 年報表 15'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2023','2023 年 7 月',2023,'mean',96262,'元/月',1940,'112 年報表 15'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2024','2024 年 7 月',2024,'mean',93143,'元/月',2025,'113 年報表 15'),
('mol_occupation_survey','lawyer_employee','monthly_regular_pay','2025','2025 年 7 月',2025,'mean',95337,'元/月',1968,'114 年報表 15'),
-- 律師：7 月總薪資（經常＋非經常，元／月；2021 年止）
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2003','2003 年 7 月',2003,'mean',90324,'元/月',334,'政大論文表 3-26'),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2004','2004 年 7 月',2004,'mean',82695,'元/月',418,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2005','2005 年 7 月',2005,'mean',94249,'元/月',280,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2006','2006 年 7 月',2006,'mean',55352,'元/月',600,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2008','2008 年 7 月',2008,'mean',89540,'元/月',770,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2009','2009 年 7 月',2009,'mean',75587,'元/月',586,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2010','2010 年 7 月',2010,'mean',119166,'元/月',507,'非經常性 37,937'),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2011','2011 年 7 月',2011,'mean',100408,'元/月',592,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2012','2012 年 7 月',2012,'mean',88797,'元/月',530,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2013','2013 年 7 月',2013,'mean',109228,'元/月',595,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2014','2014 年 7 月',2014,'mean',89921,'元/月',864,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2015','2015 年 7 月',2015,'mean',88344,'元/月',1209,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2016','2016 年 7 月',2016,'mean',100569,'元/月',990,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2017','2017 年 7 月',2017,'mean',92879,'元/月',1515,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2018','2018 年 7 月',2018,'mean',105319,'元/月',1249,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2019','2019 年 7 月',2019,'mean',101452,'元/月',1406,NULL),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2020','2020 年 7 月',2020,'mean',100512,'元/月',1328,'109 年報表 15'),
('mol_occupation_survey','lawyer_employee','monthly_total_pay','2021','2021 年 7 月',2021,'mean',98056,'元/月',1390,'110 年報表 15'),
-- 律師：全年薪資所得（萬元／年；period＝所得年）
('mol_occupation_survey','lawyer_employee','annual_pay','2021','2021/8–2022/7',2021,'mean',159.7,'萬元/年',1125,'111 年報表 15：110 年 8 月至 111 年 7 月總薪資'),
('mol_occupation_survey','lawyer_employee','annual_pay','2022','2022 年全年',2022,'mean',171.9,'萬元/年',1940,'112 年報表 15：111 年全年薪資所得（扣繳憑單）'),
('mol_occupation_survey','lawyer_employee','annual_pay','2023','2023 年全年',2023,'mean',159.0,'萬元/年',2025,'113 年報表 15：112 年全年薪資所得'),
('mol_occupation_survey','lawyer_employee','annual_pay','2024','2024 年全年',2024,'mean',165.3,'萬元/年',1968,'114 年報表 15：113 年全年薪資所得'),
-- 法務人員（法律服務業）
('mol_occupation_survey','legal_staff','employees','2022','2022 年 7 月',2022,'count',1032,'位',NULL,'111 年報表 15'),
('mol_occupation_survey','legal_staff','employees','2023','2023 年 7 月',2023,'count',1626,'位',NULL,'112 年報表 15'),
('mol_occupation_survey','legal_staff','employees','2024','2024 年 7 月',2024,'count',1591,'位',NULL,'113 年報表 15'),
('mol_occupation_survey','legal_staff','employees','2025','2025 年 7 月',2025,'count',1502,'位',NULL,'114 年報表 15'),
('mol_occupation_survey','legal_staff','monthly_regular_pay','2022','2022 年 7 月',2022,'mean',42960,'元/月',1032,NULL),
('mol_occupation_survey','legal_staff','monthly_regular_pay','2023','2023 年 7 月',2023,'mean',40054,'元/月',1626,NULL),
('mol_occupation_survey','legal_staff','monthly_regular_pay','2024','2024 年 7 月',2024,'mean',41416,'元/月',1591,NULL),
('mol_occupation_survey','legal_staff','monthly_regular_pay','2025','2025 年 7 月',2025,'mean',44286,'元/月',1502,NULL),
('mol_occupation_survey','legal_staff','annual_pay','2021','2021/8–2022/7',2021,'mean',61.5,'萬元/年',1032,NULL),
('mol_occupation_survey','legal_staff','annual_pay','2022','2022 年全年',2022,'mean',60.2,'萬元/年',1626,NULL),
('mol_occupation_survey','legal_staff','annual_pay','2023','2023 年全年',2023,'mean',62.5,'萬元/年',1591,NULL),
('mol_occupation_survey','legal_staff','annual_pay','2024','2024 年全年',2024,'mean',69.1,'萬元/年',1502,NULL),
-- 專利工程師及公證人（法律服務業）
('mol_occupation_survey','patent_notary','employees','2022','2022 年 7 月',2022,'count',1449,'位',NULL,NULL),
('mol_occupation_survey','patent_notary','employees','2023','2023 年 7 月',2023,'count',2302,'位',NULL,NULL),
('mol_occupation_survey','patent_notary','employees','2024','2024 年 7 月',2024,'count',2183,'位',NULL,NULL),
('mol_occupation_survey','patent_notary','employees','2025','2025 年 7 月',2025,'count',2220,'位',NULL,NULL),
('mol_occupation_survey','patent_notary','monthly_regular_pay','2022','2022 年 7 月',2022,'mean',62187,'元/月',1449,NULL),
('mol_occupation_survey','patent_notary','monthly_regular_pay','2023','2023 年 7 月',2023,'mean',60028,'元/月',2302,NULL),
('mol_occupation_survey','patent_notary','monthly_regular_pay','2024','2024 年 7 月',2024,'mean',61166,'元/月',2183,NULL),
('mol_occupation_survey','patent_notary','monthly_regular_pay','2025','2025 年 7 月',2025,'mean',59396,'元/月',2220,NULL),
('mol_occupation_survey','patent_notary','annual_pay','2021','2021/8–2022/7',2021,'mean',93.0,'萬元/年',1449,NULL),
('mol_occupation_survey','patent_notary','annual_pay','2022','2022 年全年',2022,'mean',91.1,'萬元/年',2302,NULL),
('mol_occupation_survey','patent_notary','annual_pay','2023','2023 年全年',2023,'mean',93.9,'萬元/年',2183,NULL),
('mol_occupation_survey','patent_notary','annual_pay','2024','2024 年全年',2024,'mean',90.3,'萬元/年',2220,NULL),
-- 土地代書（地政士）（法律服務業）
('mol_occupation_survey','land_agent','employees','2024','2024 年 7 月',2024,'count',561,'位',NULL,NULL),
('mol_occupation_survey','land_agent','employees','2025','2025 年 7 月',2025,'count',568,'位',NULL,NULL),
('mol_occupation_survey','land_agent','monthly_regular_pay','2024','2024 年 7 月',2024,'mean',36830,'元/月',561,NULL),
('mol_occupation_survey','land_agent','monthly_regular_pay','2025','2025 年 7 月',2025,'mean',40291,'元/月',568,NULL),
('mol_occupation_survey','land_agent','annual_pay','2023','2023 年全年',2023,'mean',44.8,'萬元/年',561,NULL),
('mol_occupation_survey','land_agent','annual_pay','2024','2024 年全年',2024,'mean',53.6,'萬元/年',568,NULL),
-- 專業秘書（法律服務業）
('mol_occupation_survey','secretary','employees','2022','2022 年 7 月',2022,'count',441,'位',NULL,NULL),
('mol_occupation_survey','secretary','employees','2023','2023 年 7 月',2023,'count',528,'位',NULL,NULL),
('mol_occupation_survey','secretary','employees','2024','2024 年 7 月',2024,'count',569,'位',NULL,NULL),
('mol_occupation_survey','secretary','employees','2025','2025 年 7 月',2025,'count',540,'位',NULL,NULL),
('mol_occupation_survey','secretary','monthly_regular_pay','2022','2022 年 7 月',2022,'mean',52365,'元/月',441,NULL),
('mol_occupation_survey','secretary','monthly_regular_pay','2023','2023 年 7 月',2023,'mean',56034,'元/月',528,NULL),
('mol_occupation_survey','secretary','monthly_regular_pay','2024','2024 年 7 月',2024,'mean',53646,'元/月',569,NULL),
('mol_occupation_survey','secretary','monthly_regular_pay','2025','2025 年 7 月',2025,'mean',55633,'元/月',540,NULL),
('mol_occupation_survey','secretary','annual_pay','2021','2021/8–2022/7',2021,'mean',81.2,'萬元/年',441,NULL),
('mol_occupation_survey','secretary','annual_pay','2022','2022 年全年',2022,'mean',89.8,'萬元/年',528,NULL),
('mol_occupation_survey','secretary','annual_pay','2023','2023 年全年',2023,'mean',80.6,'萬元/年',569,NULL),
('mol_occupation_survey','secretary','annual_pay','2024','2024 年全年',2024,'mean',90.3,'萬元/年',540,NULL),
-- 法律服務業全體全時受僱員工
('mol_occupation_survey','law_firm_all','employees','2020','2020 年 7 月',2020,'count',12308,'位',NULL,'109 年報表 15 總計列'),
('mol_occupation_survey','law_firm_all','employees','2021','2021 年 7 月',2021,'count',11657,'位',NULL,'110 年報表 15 總計列'),
('mol_occupation_survey','law_firm_all','employees','2025','2025 年 7 月',2025,'count',16970,'位',NULL,'114 年報表 1（主管 1,398／專業 4,455／技術員及助理 3,226／事務支援 7,865）'),
('mol_occupation_survey','law_firm_all','monthly_regular_pay','2020','2020 年 7 月',2020,'mean',48029,'元/月',12308,NULL),
('mol_occupation_survey','law_firm_all','monthly_regular_pay','2021','2021 年 7 月',2021,'mean',47194,'元/月',11657,NULL),
('mol_occupation_survey','law_firm_all','monthly_total_pay','2020','2020 年 7 月',2020,'mean',68739,'元/月',12308,NULL),
('mol_occupation_survey','law_firm_all','monthly_total_pay','2021','2021 年 7 月',2021,'mean',53244,'元/月',11657,NULL)
ON CONFLICT (source, role, metric, period, category, stat) DO UPDATE
  SET value = EXCLUDED.value, unit = EXCLUDED.unit, n = EXCLUDED.n, note = EXCLUDED.note, sort = EXCLUDED.sort;

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency)
VALUES
  ('勞動部職類別薪資調查 法律服務業×律師', 'https://www.mol.gov.tw/statistics/19111/', '每年 7 月調查、年報次年 5 月出（statdb.mol.gov.tw/html/s3/svyNN/NN35all.pdf 表 15，文字層無中文需 OCR）；2003–2019 取自政大論文表 3-26；種子入 labor_comp_series（mig 249），年更手動', 'salary', 'manual', 'yearly')
ON CONFLICT (name) DO NOTHING;

DO $$
DECLARE c int;
BEGIN
  SELECT count(*) INTO c FROM labor_comp_series WHERE source = 'mol_occupation_survey' AND role = 'lawyer_employee' AND metric = 'monthly_regular_pay';
  IF c <> 22 THEN RAISE EXCEPTION 'mol regular pay rows=% (<>22)', c; END IF;
  SELECT count(*) INTO c FROM labor_comp_series WHERE source = 'mol_occupation_survey_quoted';
  IF c <> 0 THEN RAISE EXCEPTION 'quoted rows still present'; END IF;
END $$;
