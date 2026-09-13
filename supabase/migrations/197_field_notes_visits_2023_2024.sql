-- ============================================================
-- 197: 田野筆記回填——雷皓明 2023／2024 拜訪律師名單（Downloads/拜訪律師名單.xlsx）
-- ============================================================
-- 來源：Excel「2023」分頁 27 位有內容（另 7 位只有姓名、無內容，未入庫：余信達／蕭逸泓／雷丘／余宗鳴／
--       鄧湘全／李易撰／林仲豪）＋「2024」分頁 1 位（周宇修二訪）。
-- 日期：原表僅知年份 → interviewed_on 記該年 01-01，date_precision='year'（前端顯示「2023 年」）。
-- 「營收/個人收入」欄原表未區分口徑：受僱／獨立小所視為個人收入（fin.personal_income），
--   主持／合夥所大額視為所（或單位）營收（fin.revenue）；區間取中位、value_qual='~'，原區間寫在 value_text。
-- 事務所名對齊 moj_firm_statistics()：宇恆→宇恒、六合國際→六合、大恆→大恆國際、天晴和永→天晴和永國際商務、
--   法鳴國際→法鳴、永信→永信法律、成鼎→成鼎律師、立勤→立勤國際、KPMG→安侯、眾勤（北所）→眾勤。
-- 律師別字：謝佳頴→謝佳穎、周逸賓→周逸濱、許肇慶→許兆慶（皆以 MOJ 名冊為準）。
-- 本次新增 9 個維度（個人職涯群組等）＋ notes 表補 date_precision 欄。

BEGIN;

ALTER TABLE firm_field_notes
  ADD COLUMN IF NOT EXISTS date_precision text NOT NULL DEFAULT 'day'
  CHECK (date_precision IN ('day','month','year'));

INSERT INTO field_note_dimensions (key, grp, grp_label, label, unit, description, sort) VALUES
  ('comp.self_case_split',      'comp',  '薪酬結構', '自案拆分（律師:所）',   NULL,  '律師自帶案件的收入拆分比例，例 9:1', 16),
  ('org.partnership_dynamics',  'org',   '組織治理', '合夥／拆夥經驗',        NULL,  '合夥成立、拆夥原因、合署轉合夥等', 24),
  ('org.network_affiliation',   'org',   '組織治理', '會所／外國所／聯盟關係', NULL,  '四大會所體系、外國所合作、聯盟的限制與代價', 25),
  ('talent.caseload',           'talent','人才',     '人均在手案件',          '件',  NULL, 72),
  ('talent.training',           'talent','人才',     '培訓／帶人制度',        NULL,  '前輩帶開庭、內訓、分層派案', 73),
  ('fin.personal_income',       'fin',   '財務',     '個人年收入（自述）',    '萬元', '受僱薪資或獨立律師個人年收', 82),
  ('strat.collab_interest',     'strat', '戰略',     '與喆律合作意願',        NULL,  '受訪者主動提及的合作可能', 92),
  ('career.goal',               'career','個人職涯', '職涯目標／對律師工作的想像', NULL, '受訪者自述的目標與心態', 100),
  ('career.side_business',      'career','個人職涯', '副業／跨業經營',        NULL,  '法律科技、創投、不動產、自媒體賣貨等', 101)
ON CONFLICT (key) DO UPDATE SET grp=EXCLUDED.grp, grp_label=EXCLUDED.grp_label, label=EXCLUDED.label,
  unit=EXCLUDED.unit, description=EXCLUDED.description, sort=EXCLUDED.sort;

-- 共用寫法：每筆訪談一段 WITH n AS (INSERT … RETURNING id) INSERT INTO firm_field_facts …
-- facts 欄序：subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort

-- ---------- 1. 洪永志｜丞甫法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('丞甫法律事務所', DATE '2023-01-01', 'year', '主持律師', '洪永志，獨立開所', '拜訪',
   '一人所＋1 合署，個人年收 300–350 萬；案源靠議員關係（環評委員→回收廠法顧）；目標是靠律師工作找投資機會、以投資退休。',
   '執業狀況：獨立開所｜營收/個人收入：300~350｜規模：1律師、1合署｜有透過議員擔任環評委員，有接到回收廠的法顧案件／目標透過律師工作找到其他投資機會 希望透過投資退休') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '丞甫法律事務所', 'fin.personal_income', 325::numeric, '~'::text, '個人年收 300–350 萬（原表「營收/個人收入」欄，獨立一人所視為個人收入）', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '丞甫法律事務所', 'org.headcount', 1, '=', '1 位律師＋1 位合署', 'high', false, 'moj_firm_statistics 2026-09：1 人', NULL, 2),
  ('firm', '丞甫法律事務所', 'mkt.channel_mix', NULL, NULL, '透過議員關係擔任環評委員，藉此接到回收廠法顧案', 'high', false, NULL, '有透過議員擔任環評委員，有接到回收廠的法顧案件', 3),
  ('firm', '丞甫法律事務所', 'career.goal', NULL, NULL, '把律師工作當跳板找投資機會，希望靠投資退休', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 2. 江鎬佑｜祥業法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('祥業法律事務所', DATE '2023-01-01', 'year', '主持律師', '江鎬佑，2 年受僱＋2 年自己執業', '拜訪',
   '一人所，個人年收 200–250 萬；案源＝議員案件＋保險業務員轉介（業務員代做溝通與調解，律師只出庭）＋BNI；目標是透過律師工作找其他工作機會。',
   '年資：2年受雇、2年自己執業｜獨立開所｜200-250｜1律師｜有接議員的案件／有保險業務接洽 會處理當事人和溝通聯絡調解 只有開庭需要出現／有跑ＢＮＩ／目標是透過律師工作找到其他工作機會') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '祥業法律事務所', 'fin.personal_income', 225::numeric, '~'::text, '個人年收 200–250 萬', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '祥業法律事務所', 'org.headcount', 1, '=', '1 位律師', 'high', false, 'moj_firm_statistics 2026-09：2 人', NULL, 2),
  ('firm', '祥業法律事務所', 'mkt.channel_mix', NULL, NULL, '議員案件＋保險業務員轉介（業務員代處理當事人溝通與調解，律師只在開庭出現）＋跑 BNI 商會', 'high', false, NULL, '有保險業務接洽 會處理當事人和溝通聯絡調解 只有開庭需要出現', 3),
  ('firm', '祥業法律事務所', 'career.goal', NULL, NULL, '透過律師工作找到其他工作機會', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 3. 朱浩文｜威律法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('威律法律事務所', DATE '2023-01-01', 'year', '受僱律師', '朱浩文，1 年受僱＋2 年自己執業（原表列「獨立開所」，同年另訪威律主持律師周逸濱）', '拜訪',
   '個人年收 100–150 萬；案源主要靠律師同道介紹（幫其他律師事務所建資訊系統換來的關係）；把律師當工作、重視晚上與假日生活。',
   '年資：1年受雇、2年自己執業｜獨立開所｜100-150｜5律師、6合署｜案件主要來源是律師同道介紹（透過幫律師事務所建立資訊系統交換）／目標把律師工作就是工作希望經營晚上跟假日的生活') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '威律法律事務所', 'fin.personal_income', 125::numeric, '~'::text, '個人年收 100–150 萬', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '威律法律事務所', 'org.headcount', 11, '~', '5 位律師＋6 位合署', 'medium', false, 'moj_firm_statistics 2026-09：15 人；朱浩文現仍登錄威律', NULL, 2),
  ('firm', '威律法律事務所', 'mkt.channel_mix', NULL, NULL, '案源主要是律師同道介紹——以幫其他律師事務所建資訊系統換取轉介', 'high', false, NULL, '透過幫律師事務所建立資訊系統交換', 3),
  ('firm', '威律法律事務所', 'career.goal', NULL, NULL, '律師工作就是工作，重視經營晚上與假日生活', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 4. 陳育祺｜中成國際法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('中成國際法律事務所', DATE '2023-01-01', 'year', '合署律師', '陳育祺，5 年受僱＋4 年自己執業', '拜訪',
   '合署制所（3 律師＋6 合署），個人年收 200–250 萬；案源以自來案與法扶案為主；對律師工作仍有熱情、希望事務所放大。',
   '年資：5年受雇、4年自己執業｜合署｜200-250｜3律師、6合署｜主要自來案、法扶案／對律師工作仍有熱情 希望事務所放大') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '中成國際法律事務所', 'fin.personal_income', 225::numeric, '~'::text, '個人年收 200–250 萬', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '中成國際法律事務所', 'org.headcount', 9, '~', '3 位律師＋6 位合署', 'medium', false, 'moj_firm_statistics 2026-09：12 人', NULL, 2),
  ('firm', '中成國際法律事務所', 'mkt.channel_mix', NULL, NULL, '主要是自來案與法扶案', 'high', false, NULL, NULL, 3),
  ('firm', '中成國際法律事務所', 'career.goal', NULL, NULL, '仍有熱情，希望事務所放大', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 5. 張偉志｜灼然法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('灼然法律事務所', DATE '2023-01-01', 'year', '合署律師', '張偉志，受僱 1.5 年、出來開半年', '拜訪',
   '5 位合署律師多為一年左右年資；個人年收 100–150 萬，案源靠舊客戶介紹；另開法律科技公司做勞資檢核系統，目標放在科技公司。',
   '年資：受僱1.5年，出來開半年｜合署｜100-150｜5律師合署｜舊客戶介紹案件／另有開設法律科技公司做勞資檢核系統／所內合署律師多半為一年左右年資／目標是經營好法律科技公司') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '灼然法律事務所', 'fin.personal_income', 125::numeric, '~'::text, '個人年收 100–150 萬', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '灼然法律事務所', 'org.headcount', 5, '=', '5 位合署律師，多半一年左右年資', 'high', false, 'moj_firm_statistics 2026-09：5 人', NULL, 2),
  ('firm', '灼然法律事務所', 'mkt.channel_mix', NULL, NULL, '舊客戶介紹', 'high', false, NULL, NULL, 3),
  ('firm', '灼然法律事務所', 'career.side_business', NULL, NULL, '另開法律科技公司做勞資檢核系統', 'high', false, NULL, NULL, 4),
  ('firm', '灼然法律事務所', 'career.goal', NULL, NULL, '目標是經營好法律科技公司，律師業務非主軸', 'high', false, NULL, NULL, 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 6. 謝佳穎｜寰瀛法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('寰瀛法律事務所', DATE '2023-01-01', 'year', '受僱律師', '謝佳穎（原表作「謝佳頴」），受僱 8 年', '拜訪',
   '受僱 8 年年收 150–200 萬；寰瀛是大所中氣氛最好的，薪資不高但留得住人（對比萬國氣氛差）；自案拆分律師 1：所 9；2022 起拉 3 位檢察官發展刑事（個資／重金／證交），非訟想做韓文市場。',
   '年資：受僱8年｜受僱｜150-200｜33位律師｜寰瀛是大所中氣氛環境較好的所，而且有很多各類案件，雖然薪資不高但也讓人不想走／去年開始拉了三位檢察官加入，目標發展刑事案件（個資、重金、證交）／非訟想發展韓文市場／律師自案分配：律師1 事務所9／之前在萬國氣氛很差，現在萬國在要搬家找不到地方／目前在事務所相對舒服，不考慮到其他事務所，會思考自己開所或到公司做法務') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '寰瀛法律事務所', 'fin.personal_income', 175::numeric, '~'::text, '受僱 8 年個人年收 150–200 萬', 'high', false, NULL::text, NULL::text, 1),
  ('firm', '寰瀛法律事務所', 'org.headcount', 33, '=', '33 位律師', 'high', false, 'moj_firm_statistics 2026-09：33 人（完全吻合）；謝佳穎現仍登錄寰瀛', NULL, 2),
  ('firm', '寰瀛法律事務所', 'talent.turnover', NULL, NULL, '大所中氣氛環境最好、案件類型多，薪資不高但讓人不想走；受訪者不考慮換所，只會考慮自己開所或去企業當法務', 'high', false, NULL, '雖然薪資不高但也讓人不想走', 3),
  ('firm', '寰瀛法律事務所', 'comp.self_case_split', NULL, NULL, '律師自案拆分：律師 1、事務所 9', 'high', false, NULL, '律師自案分配：律師1 事務所9', 4),
  ('firm', '寰瀛法律事務所', 'biz.niche', NULL, NULL, '2022 年起拉進 3 位檢察官，發展刑事（個資、重大金融、證交）；非訟想開發韓文市場', 'high', false, 'ex_judicial_lawyers 可核對寰瀛前檢察官人數', NULL, 5),
  ('peer', '萬國法律事務所', 'talent.turnover', NULL, NULL, '受訪者曾任職萬國，稱氣氛很差', 'medium', false, NULL::text, '之前在萬國氣氛很差', 6),
  ('peer', '萬國法律事務所', 'org.decision_style', NULL, NULL, '2023 年萬國要搬家但找不到地方', 'low', true, NULL, NULL, 7)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 7. 張恆嘉｜大恆國際法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('大恆國際法律事務所', DATE '2023-01-01', 'year', '主持律師', '張恆嘉，開業 6 年，合署所主持律師', '拜訪',
   '合署所：5 主持＋6 受僱＋5–6 合署；個人年收 300–400 萬；案源原以親友長輩介紹；曾有受僱現無；想發展、正思考建網站或投 FB 廣告。',
   '年資：開業6年｜合署所主持律師｜300-400｜5位主持律師、6位受雇律師、5-6位合署律師｜主要案件原為親友長輩介紹／之前有一位受僱、現在無受僱／目標想要發展，目前思考建構網站或ＦＢ廣告頭放') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '大恆國際法律事務所', 'fin.personal_income', 350::numeric, '~'::text, '主持律師個人年收 300–400 萬（原表未區分營收／收入）', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '大恆國際法律事務所', 'org.headcount', 17, '~', '5 位主持＋6 位受僱＋5–6 位合署', 'high', false, 'moj_firm_statistics 2026-09：19 人', NULL, 2),
  ('firm', '大恆國際法律事務所', 'mkt.channel_mix', NULL, NULL, '案件原以親友長輩介紹為主', 'high', false, NULL, NULL, 3),
  ('firm', '大恆國際法律事務所', 'talent.turnover', NULL, NULL, '受訪者本人曾有一位受僱，2023 時已無', 'high', false, NULL, NULL, 4),
  ('firm', '大恆國際法律事務所', 'career.goal', NULL, NULL, '想發展，思考建網站或投 FB 廣告', 'high', false, 'firm_digital_signals 可核對大恆國際是否已裝 FB Pixel', NULL, 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 8. 沈元楷｜新凱國際法律事務所（現已自設所） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('新凱國際法律事務所', DATE '2023-01-01', 'year', '合署律師', '沈元楷，受僱 8 年（建業 8 年半）＋開業 1 年', '拜訪',
   '離開建業第一年即年收 450–500 萬；透露建業合夥階梯：業績 250 萬→資深合夥人目標 400 萬→主持律師目標 800 萬，自案拆分 9:1。與退下來的檢察官學長合署；思考是否找受僱、想放大。',
   '年資：受僱8年、開業1年｜合署｜450-500｜5位合署律師｜在建業法律事務所待8年半／（在建業業績約250萬、成為資深合夥人目標業績為400萬、主持律師目標業績為800萬，自案拆分9:1）／目前與檢察官退下來的學長合署，出來開第一年／目標還在思考是否找受僱、想放大') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '新凱國際法律事務所', 'fin.personal_income', 475::numeric, '~'::text, '開業第一年個人年收 450–500 萬', 'high', false, NULL::text, NULL::text, 1),
  ('firm', '新凱國際法律事務所', 'org.headcount', 5, '=', '5 位合署律師', 'high', false, 'moj_firm_statistics 2026-09：5 人；沈元楷現已登錄「沈元楷律師事務所」（離開新凱自設）', NULL, 2),
  ('firm', '新凱國際法律事務所', 'org.model_lineage', NULL, NULL, '與檢察官退下來的學長合署', 'high', false, NULL, NULL, 3),
  ('peer', '建業法律事務所', 'org.partner_track', NULL, NULL, '合夥階梯以業績定義：受訪者在建業業績約 250 萬；資深合夥人目標業績 400 萬；主持律師目標 800 萬', 'high', false, 'moj_firm_statistics 2026-09：建業 28 人＋建業高所 6 人', '成為資深合夥人目標業績為400萬、主持律師目標業績為800萬', 4),
  ('peer', '建業法律事務所', 'comp.self_case_split', NULL, NULL, '自案拆分 9:1（律師 9）', 'high', false, NULL, '自案拆分9:1', 5),
  ('firm', '新凱國際法律事務所', 'career.goal', NULL, NULL, '思考是否找受僱、想放大', 'high', false, NULL, NULL, 6)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 9. 蔣昕佑｜天晴和永國際商務法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('天晴和永國際商務法律事務所', DATE '2023-01-01', 'year', '合夥人', '蔣昕佑，合夥所主持律師', '拜訪',
   '5 合夥＋6 受僱＋8 顧問律師（存疑）；一群人從賦詠德章合署出走共同創所（付過半租金卻沒空間）；羅明通門生；想做專案管理系統但合夥制下沒人願意投入時間、無法分配補償；目標中大型所。',
   '合夥所主持律師｜5位合夥律師、6位受僱律師、8位顧問律師（？）｜大家從賦詠德章一起合署後，覺得自己站過半的租金卻沒有足夠空間，所以一起出來開／羅明通的徒弟（同門有吳存富）／去年大家有一起想做專案管理系統，但不知要由哪個合夥律師負責，因為會佔到合夥律師很多時間，大家想不出如何分配或補償／目標想發展成中大型事務所') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '天晴和永國際商務法律事務所', 'org.headcount', 11::numeric, '~'::text, '5 位合夥＋6 位受僱＋8 位顧問律師（顧問數存疑）', 'medium', false, 'moj_firm_statistics 2026-09：10 人'::text, NULL::text, 1),
  ('firm', '天晴和永國際商務法律事務所', 'org.partnership_dynamics', NULL, NULL, '合夥人原在賦詠德章合署，覺得付了過半租金卻沒有足夠空間，一起出來創所', 'high', false, NULL, '覺得自己站過半的租金卻沒有足夠空間，所以一起出來開', 2),
  ('firm', '天晴和永國際商務法律事務所', 'org.model_lineage', NULL, NULL, '羅明通門生（同門有吳存富）', 'high', false, 'moj_lawyers：羅明通現登錄台英國際商務；吳存富現登錄可道律師事務所', NULL, 3),
  ('firm', '天晴和永國際商務法律事務所', 'org.decision_style', NULL, NULL, '合夥制的內部建設困境：想做專案管理系統，但沒有合夥人願意負責——會佔大量時間、想不出如何分配或補償', 'high', false, NULL, '不知要由哪個合夥律師負責，因為會佔到合夥律師很多時間', 4),
  ('firm', '天晴和永國際商務法律事務所', 'career.goal', NULL, NULL, '想發展成中大型事務所', 'high', false, NULL, NULL, 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 10. 賴彥夫｜法鳴法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('法鳴法律事務所', DATE '2023-01-01', 'year', '合夥人', '賴彥夫，合夥人（所內分合夥／直屬合署／一般合署三層）', '拜訪',
   '三層結構：2 合夥＋6 直屬合署＋8 一般合署。直屬合署拆分：所案 所4:律師6、自案 所2:律師8；一般合署付低租金。跨業做不動產媒合／買賣／包租代管並期望獲利在此；主張先找各領域合作對象、案源自然來。',
   '合夥、直屬合署及一般合署｜2位合夥、6位直屬合署、8位一般合署｜希望發展組織化、國際化的法律事務所／開始經營不動產媒合、買賣、包租代管產業，希望未來獲利在這些產業／直屬合署，所案（所4：律師6）、自案（所2、律師8）、一般合署付租金（低、含影印）／覺得應該先找到各領域合作對象先，不用先有案源，有各領域專家了自然會有案源') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '法鳴法律事務所', 'org.headcount', 16::numeric, '~'::text, '2 位合夥＋6 位直屬合署＋8 位一般合署', 'high', false, 'moj_firm_statistics 2026-09：7 人（一般合署多半登錄自己的所）'::text, NULL::text, 1),
  ('firm', '法鳴法律事務所', 'comp.self_case_split', NULL, NULL, '直屬合署：所派案 所 4：律師 6；自案 所 2：律師 8。一般合署只付低額租金（含影印）', 'high', false, NULL, '所案（所4：律師6）、自案（所2、律師8）', 2),
  ('firm', '法鳴法律事務所', 'career.side_business', NULL, NULL, '經營不動產媒合、買賣、包租代管，希望未來獲利在這些產業', 'high', false, NULL, NULL, 3),
  ('firm', '法鳴法律事務所', 'career.goal', NULL, NULL, '希望發展成組織化、國際化的法律事務所', 'high', false, NULL, NULL, 4),
  ('firm', '法鳴法律事務所', 'strat.market_view', NULL, NULL, '應先找齊各領域合作對象，不必先有案源——有專家自然有案源', 'high', false, NULL, '有各領域專家了自然會有案源', 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 11. 黃旭田｜元貞聯合法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('元貞聯合法律事務所', DATE '2023-01-01', 'year', '合夥人', '黃旭田，受僱→合署→合夥（合夥 21 年）', '拜訪',
   '2 合夥＋3 合署＋10 受僱，歷史高峰 35 位律師。第一次合夥談 2 年、合作 6 個月即拆（世代步調不同）；第二次合夥 20 餘年，合夥人陸續因從政（詹順貴）、離世、做大（賴芳玉）而拆；曾有外國所談合併，卡在名稱。',
   '受僱、合署、合夥（21年）｜2位合夥、3位合署、10位受雇｜第一次合夥討論了2年，合作6個月就拆夥，因為年輕律師和資深律師步調不同／目前第二次合夥，經營事務所20餘年，合夥人個別因為做官（詹順貴）、離世（藍律師）、或自己（賴芳玉）做大拆夥，目前另一位合夥人是受僱升上來的合夥人／事務所最多有35位律師，曾有外國法律事務所來談合併，但因為名稱問題談不攏作罷／參與公會事務是因為覺得律師工作的本質較不陽光，公會事務感覺較積極正向') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '元貞聯合法律事務所', 'org.headcount', 15::numeric, '='::text, '2 位合夥＋3 位合署＋10 位受僱；歷史高峰曾達 35 位律師', 'high', false, 'moj_firm_statistics 2026-09：13 人'::text, NULL::text, 1),
  ('firm', '元貞聯合法律事務所', 'org.partnership_dynamics', NULL, NULL, '第一次合夥討論 2 年、合作 6 個月即拆夥（年輕與資深律師步調不同）；第二次合夥 20 餘年，合夥人分別因從政（詹順貴）、離世、自己做大（賴芳玉）而拆夥；現任另一合夥人是受僱升上來的', 'high', false, NULL, '因為年輕律師和資深律師步調不同', 2),
  ('firm', '元貞聯合法律事務所', 'org.network_affiliation', NULL, NULL, '曾有外國法律事務所來談合併，因名稱問題談不攏作罷', 'high', false, NULL, NULL, 3),
  ('firm', '元貞聯合法律事務所', 'career.goal', NULL, NULL, '投入公會事務，因覺得律師工作本質較不陽光，公會事務較積極正向', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 12. 賴瑩真｜鼎峰國際法律事務所（現登錄詠言） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('鼎峰國際法律事務所', DATE '2023-01-01', 'year', '合署律師', '賴瑩真，執業 20 年，合署中、1 位受僱', '拜訪',
   '8 成時間做 YouTube、2 成做律師，案源全部來自 YT 觀眾主動來電但案量不大；認為 YT 帶來的客戶不可能轉給受僱全權處理；目標是以律師身份賣產品（VPN、保健食品最賺）。',
   '執業20年，目前合署中，一位受僱｜3合署、1受僱｜時間8成在做ＹＴ，2成做律師，目前案件源都是ＹＴ來的客戶（會主動來電事務所），案量不大／覺得ＹＴ來的客戶不可能轉給受僱律師全權處理／希望透過ＹＴ經營，以律師身份賣產品賺錢（目前最賺錢是賣ＶＰＮ及保健食品）') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '鼎峰國際法律事務所', 'org.headcount', 4::numeric, '='::text, '3 位合署＋1 位受僱', 'high', false, 'moj_firm_statistics 2026-09：3 人；賴瑩真現登錄「詠言法律事務所」（已離開鼎峰）'::text, NULL::text, 1),
  ('firm', '鼎峰國際法律事務所', 'mkt.channel_mix', NULL, NULL, '案源 100% 來自 YouTube 觀眾主動來電，但案量不大；本人 8 成時間做 YT、2 成做律師', 'high', false, NULL, '時間8成在做ＹＴ，2成做律師', 2),
  ('firm', '鼎峰國際法律事務所', 'org.decision_style', NULL, NULL, '認為自媒體帶來的客戶認的是本人，不可能轉給受僱律師全權處理——個人品牌難以規模化', 'high', false, NULL, '覺得ＹＴ來的客戶不可能轉給受僱律師全權處理', 3),
  ('firm', '鼎峰國際法律事務所', 'career.side_business', NULL, NULL, '以律師身份透過 YT 賣產品賺錢，最賺的是 VPN 與保健食品', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 13. 張譽尹｜永信法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('永信法律事務所', DATE '2023-01-01', 'year', '合夥人', '張譽尹，執業 20 年（曾自己開 2 年，其餘在永信合署／合夥）', '拜訪',
   '7 合夥＋2 受僱＋1 實習。合夥階梯：受僱 2 年可升初級合夥、6 年有機會受邀合夥。合夥人薪資三段：基本保障年薪（隨年資）＋引案獎金（案件金額 10%）＋承辦獎金（案件金額 90%），不足由合夥人共同貼補。',
   '職業20年，有出去自己開2年，其餘均在永信合署合夥｜合夥｜7合夥、2受僱、1實習｜受僱兩年可以升初級合夥、6年有機會被邀請成為合夥人，／成為合夥後薪資有三部分，基本保障年薪（隨年資增加）、引案獎金(案件金額10%)、承辦獎金（案件金額90%），但若不足合夥人們需一起拿錢出來貼') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '永信法律事務所', 'org.headcount', 10::numeric, '='::text, '7 位合夥＋2 位受僱＋1 位實習', 'high', false, 'moj_firm_statistics 2026-09：11 人（吻合）；張譽尹現仍登錄永信'::text, NULL::text, 1),
  ('firm', '永信法律事務所', 'org.partner_track', NULL, NULL, '受僱 2 年可升初級合夥；6 年有機會被邀請成為合夥人', 'high', false, NULL, NULL, 2),
  ('firm', '永信法律事務所', 'comp.bonus_components', NULL, NULL, '合夥人薪資三段：基本保障年薪（隨年資增加）＋引案獎金（案件金額 10%）＋承辦獎金（案件金額 90%）；若不足，合夥人一起拿錢出來貼', 'high', false, NULL, '基本保障年薪（隨年資增加）、引案獎金(案件金額10%)、承辦獎金（案件金額90%）', 3),
  ('firm', '永信法律事務所', 'comp.origination_rate', 10, '=', '引案獎金＝案件金額 10%（合夥人層級）', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 14. 高鳳英、李佩昌｜六合法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('六合法律事務所', DATE '2023-01-01', 'year', '合夥人', '高鳳英（15 年）、李佩昌（25 年以上），執業後一直在六合', '拜訪',
   '7 合夥＋9 受僱；分 7 個部門、部門內所有案件全部門同辦；受僱 3 年以上才轉資深，之前一律有前輩一起開庭；律師幾乎都是實習後一路留下，資深律師多。',
   '執業後一直都待在六合（高15、李25以上）｜合夥｜7合夥、9受僱｜受雇3年以上才能轉資深，未成為資深律師前都會有前輩一起開庭／區分7部門，個別部門的所有案件都會有全部門同辦／律師均為實習後一路待著，資深律師多') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '六合法律事務所', 'org.headcount', 16::numeric, '='::text, '7 位合夥＋9 位受僱', 'high', false, 'moj_firm_statistics 2026-09：18 人；高鳳英現登錄「高鳳英律師事務所」（已離開六合），李佩昌仍在'::text, NULL::text, 1),
  ('firm', '六合法律事務所', 'org.partner_track', NULL, NULL, '受僱 3 年以上才能轉資深律師', 'high', false, NULL, NULL, 2),
  ('firm', '六合法律事務所', 'talent.training', NULL, NULL, '未成為資深律師前一律有前輩一起開庭', 'high', false, NULL, NULL, 3),
  ('firm', '六合法律事務所', 'org.decision_style', NULL, NULL, '分 7 個部門，各部門所有案件由全部門同辦（團隊制而非個人制）', 'high', false, NULL, '個別部門的所有案件都會有全部門同辦', 4),
  ('firm', '六合法律事務所', 'talent.hiring_source', NULL, NULL, '律師均為實習後一路留下，資深律師多，幾乎不對外招募', 'high', false, NULL, NULL, 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 15. 周宇修｜謙眾國際法律事務所（2023 初訪） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('謙眾國際法律事務所', DATE '2023-01-01', 'year', '主持律師', '周宇修，主持律師（2 主持實為合署）', '拜訪',
   '2 主持律師實質合署；做很多公益案件，但受僱認為公益要時間金錢有餘裕才會開心參與；商務（金融法遵）案源主要來自哥大留學學長介紹。',
   '主持律師｜2主持律師（實際亦係合署）｜做很多公益案件，受雇覺得公益要時間金錢有餘裕時才會開心參與／商務案件（金融法遵）主要是哥大留學回來學長介紹') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '謙眾國際法律事務所', 'org.headcount', 2::numeric, '='::text, '2 位主持律師（實質為合署）', 'high', false, 'moj_firm_statistics 2026-09：11 人（登錄數遠高於自述，含其他合署單位）'::text, NULL::text, 1),
  ('firm', '謙眾國際法律事務所', 'biz.niche', NULL, NULL, '公益案件多；商務側做金融法遵', 'high', false, NULL, NULL, 2),
  ('firm', '謙眾國際法律事務所', 'talent.turnover', NULL, NULL, '受僱律師覺得公益案件要時間金錢有餘裕時才會開心參與', 'high', false, NULL, NULL, 3),
  ('firm', '謙眾國際法律事務所', 'mkt.channel_mix', NULL, NULL, '金融法遵商務案主要來自哥倫比亞大學留學同學／學長介紹', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 16. 邱若曄｜眾博法律事務所（2023，早於 2026-09-12 合夥人訪談） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('眾博法律事務所', DATE '2023-01-01', 'year', '合夥人', '邱若曄，執業 10 年（魏千峰事務所→眾博），合夥人', '拜訪',
   '2023 版眾博：1 老闆＋4 合夥＋11 律師，成立約 8 年；許兆慶法官退下來先在國際通商再自立，收費以小時計 1.5 萬以上、刑案可收高；案源一半是國際通商 pass 過來、一半所長人脈；同仁每年調薪 10% 以上；已佈局能源、標到能源局案並派駐 5 人。',
   '執業10年，待過魏千峰事務所，後來一直在眾博｜合夥人｜收入250~300｜1老闆，4合夥，11律師｜許肇慶律師法官退下來後先在國際通商，後出來自己開，費用報很高，都是小時計價，一小時15000以上／事務所案件一部分是國際通商pass案件過來，一部分是所長自己的人脈／刑案可以收蠻高的費用的／事務所成立約八年，同仁每年調薪10％以上／目前在佈局能源相關法律問題，有接到能源局的標案，目前派駐五名同仁在能源局') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '眾博法律事務所', 'fin.personal_income', 275::numeric, '~'::text, '合夥人（執業 10 年）個人年收 250–300 萬', 'high', false, NULL::text, NULL::text, 1),
  ('firm', '眾博法律事務所', 'org.headcount', 16, '=', '1 位老闆＋4 位合夥＋11 位律師；成立約 8 年（2023 時）', 'high', false, 'moj_firm_statistics 2026-09：15 人；firm_profiles.founded_year=2015（2023 時滿 8 年，吻合）；邱若曄現仍登錄眾博', NULL, 2),
  ('firm', '眾博法律事務所', 'org.model_lineage', NULL, NULL, '許兆慶法官退下來後先進國際通商，之後自己開所（原表誤植「許肇慶」）', 'high', false, '與 2026-09-12 合夥人訪談「出身國際通商」一致；ai_analysis：許兆慶前嘉義地院法官 2000–2009', NULL, 3),
  ('firm', '眾博法律事務所', 'client.pricing', 1.5, '>=', '收費報得很高，一律小時計價，每小時 1.5 萬以上；刑案可收相當高的費用', 'high', false, NULL, '都是小時計價，一小時15000以上', 4),
  ('firm', '眾博法律事務所', 'mkt.channel_mix', NULL, NULL, '案源一部分是國際通商 pass 過來的案件，一部分是所長個人人脈', 'high', false, NULL, '一部分是國際通商pass案件過來', 5),
  ('firm', '眾博法律事務所', 'comp.associate_pay_band', 10, '>=', '同仁每年調薪 10% 以上', 'high', false, NULL, NULL, 6),
  ('firm', '眾博法律事務所', 'gov.tender_staffing', 5, '=', '2023 已標到能源局案，派駐 5 名同仁在能源局', 'high', false, 'gov_tenders：能源局案 2021 起連年得標；2026-09-12 訪談稱 3 律師＋2 法務＝5 人，兩次口徑一致', '目前派駐五名同仁在能源局', 7)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 17. 施尚宏｜略策法律事務所（PAMO 創辦人） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('略策法律事務所', DATE '2023-01-01', 'year', '主持律師', '施尚宏，PAMO 創辦人，另設事務所（台中）', '拜訪',
   'PAMO：買 FB 社團做媒合、轉案給非律師賺費用（年收約 100–200 萬）；主要收入來自企業客戶（麥當勞、LINE TAXI、Lalamove）＋600 位一般用戶，月收 40–50 萬打平，前輪估值 3,000 萬；想走保險模式只服務會員；希望與喆律合作推廣一般用戶。台中所主要做放貸公司法顧。',
   '創業做ＰＡＭＯ｜創辦人/有設事務所｜很有商業頭腦:1.買ＦＢ社團做媒合，轉案給非律師賺費用（收入約100~200/年）、希望把ＰＡＭＯ走向保險模式（只服務會員）賺錢／pamo目前主要收入是企業客戶（麥當勞、line taxi、lalamove等）另有600一般民眾用戶，月收約40~50，打平，希望有合作機會協助推廣一般用戶（前一輪估值3000萬）／台中有開事務所，主要做放貸公司的法顧') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '略策法律事務所', 'career.side_business', NULL::numeric, NULL::text, '創辦 PAMO 法律科技平台；買 FB 社團做媒合、把案件轉給非律師賺轉介費（年收約 100–200 萬）；想轉保險模式只服務會員', 'high', false, NULL::text, '買ＦＢ社團做媒合，轉案給非律師賺費用', 1),
  ('firm', '略策法律事務所', 'biz.revenue_line', 45, '~', 'PAMO 月收約 40–50 萬、損益打平；主要收入來自企業客戶（麥當勞、LINE TAXI、Lalamove），另有 600 位一般用戶；前一輪估值 3,000 萬', 'high', false, NULL, NULL, 2),
  ('firm', '略策法律事務所', 'strat.collab_interest', NULL, NULL, '希望與喆律合作推廣 PAMO 一般用戶', 'high', false, NULL, NULL, 3),
  ('firm', '略策法律事務所', 'biz.niche', NULL, NULL, '台中事務所主要做放貸公司的法律顧問', 'high', false, 'moj_firm_statistics 2026-09：略策 4 人', NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 18. Ｐ律師｜事務所未載 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('（未載）Ｐ律師所屬事務所', DATE '2023-01-01', 'year', '主持律師', '「Ｐ律師」（自媒體品牌），原表未載所名', '拜訪',
   '曾 4 人合夥拆到剩 2 人主持——合夥人性質相同無法互補、無助業務推展；案件集中加盟領域；經營「Ｐ律師」品牌主要是興趣，對案件成長幫助小。',
   '主持律師｜2主持律師｜曾經四人合夥，後拆夥剩兩人（主要是覺得合夥人性質相同無法互補，無助業務推展）／案件主要在加盟領域／經營Ｐ律師主要是興趣，對案件成長少有幫助') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '（未載）Ｐ律師所屬事務所', 'org.partnership_dynamics', NULL::numeric, NULL::text, '曾 4 人合夥、後拆夥剩 2 人——合夥人性質相同無法互補、無助業務推展', 'high', false, NULL::text, '合夥人性質相同無法互補', 1),
  ('firm', '（未載）Ｐ律師所屬事務所', 'org.headcount', 2, '=', '2 位主持律師', 'high', false, NULL, NULL, 2),
  ('firm', '（未載）Ｐ律師所屬事務所', 'biz.niche', NULL, NULL, '案件主要在加盟領域', 'high', false, NULL, NULL, 3),
  ('firm', '（未載）Ｐ律師所屬事務所', 'mkt.effect_view', NULL, NULL, '經營自媒體品牌「Ｐ律師」主要是興趣，對案件成長少有幫助', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 19. 陳全正｜眾勤法律事務所（北所） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('眾勤法律事務所', DATE '2023-01-01', 'year', '主持律師', '陳全正，執業 13 年（眾勤 2→普華 5→眾勤 6），北所主持律師', '拜訪',
   '北所營收約 2,000 萬，1 老闆＋5 受僱＋2–4 合署；做智財、股權結構、勞資，案源中小企業處、資策會、客戶介紹。擔心案源與「業績差→付不出薪→受僱流動→更差」負向循環，想往外找合夥（內部升上來的天花板就是自己）。透露普華制度：兩個 BU 各 4–5 小組，BU 年目標 1 億、小組 1,000–3,000 萬，改小組目標後達成與否嚴重影響獎金。',
   '執業13年，眾勤2、普華5、眾勤6｜主持律師｜2000｜1老闆、5受僱、2~4合屬｜普華制度同會計師事務所、主要兩個ＢＵ，每個ＢＵ下4~5個小組，每個ＢＵ年度營業目標1E，每個小組目標1000~3000不等，之前是個人營業目標、現在改小組營業目標，達成與否嚴重影響獎金收入／目前事務所主要做智財、股權結構、勞資，案件多半從中小企業處、資策會及客戶介紹／擔心案源，希望往外找合夥（覺得內部升遷受雇是自己教的，天花板就是自己）／擔心負向循環，業績差>給不了受僱薪水>受僱流動>業績更差／與楊律師分配方式，引案後共同支出成本，獲利依引案比例分配') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '眾勤法律事務所', 'fin.revenue', 2000::numeric, '='::text, '北所營收約 2,000 萬（原表「營收/個人收入」欄）', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '眾勤法律事務所', 'org.headcount', 9, '~', '北所：1 位老闆＋5 位受僱＋2–4 位合署', 'high', false, 'moj_firm_statistics 2026-09：眾勤全所 23 人（含各地分所）；陳全正現仍登錄眾勤', NULL, 2),
  ('peer', '普華商務法律事務所', 'comp.bonus_components', NULL, NULL, '制度同會計師事務所：兩個 BU、各 4–5 個小組；BU 年度營業目標 1 億、小組 1,000–3,000 萬；原為個人營業目標、改為小組目標，達成與否嚴重影響獎金', 'high', false, 'moj_firm_statistics 2026-09：普華 75 人', '每個ＢＵ年度營業目標1E，每個小組目標1000~3000不等', 3),
  ('firm', '眾勤法律事務所', 'biz.niche', NULL, NULL, '智財、股權結構、勞資；案源多來自中小企業處、資策會及客戶介紹', 'high', false, NULL, NULL, 4),
  ('firm', '眾勤法律事務所', 'strat.market_view', NULL, NULL, '擔心案源；擔心負向循環（業績差→付不出受僱薪水→受僱流動→業績更差）；想往外找合夥，因內部升上來的受僱是自己教的、天花板就是自己', 'high', false, NULL, '業績差>給不了受僱薪水>受僱流動>業績更差', 5),
  ('firm', '眾勤法律事務所', 'org.partner_track', NULL, NULL, '與楊律師的分配：引案後共同支出成本，獲利依引案比例分配', 'high', false, NULL, NULL, 6)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 20. 周逸濱｜威律法律事務所（主持） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('威律法律事務所', DATE '2023-01-01', 'year', '主持律師', '周逸濱（原表作「周逸賓」），主持律師，工程背景（前雙榜）', '拜訪',
   '所營收約 1,500 萬，1 老闆＋4 受僱＋2–4 合署；從青創轉做內容產業智財（影視），因青創市場被簡榮宗、黃沛聲佔走過半；擔憂同領域強碰、不知如何成為特定領域最專業；用全律娛樂法委員會主委角色接觸產業辦內訓，讓年輕律師做低價案、自己往中價移。',
   '主持律師｜1500｜1老闆、4受僱、2~4合屬｜之前在雙榜主要做工程，有工程背景／出來後先做青創，後覺得青創被簡榮宗、黃沛聲佔走市場一半以上，黃俐穎又佔了ＡＰＰWORKS的缺，所以轉向做內容產業智慧財產權（目前以影視產業為主）／擔憂與同領域律師強碰，不知道如何成為特定領域最好最專業的律師／透過全律娛樂法委員會主委的角色接觸產業界辦所內內訓並讓年輕律師可以做同領域低價案件，自己往中價案件移動／對剛好及格的律師不知道怎麼處理？') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '威律法律事務所', 'fin.revenue', 1500::numeric, '='::text, '所營收約 1,500 萬', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '威律法律事務所', 'org.headcount', 8, '~', '1 位老闆＋4 位受僱＋2–4 位合署', 'high', false, 'moj_firm_statistics 2026-09：15 人；周逸濱現仍登錄威律', NULL, 2),
  ('firm', '威律法律事務所', 'biz.niche', NULL, NULL, '工程背景出身→青創→轉內容產業智財（影視為主）', 'high', false, NULL, NULL, 3),
  ('firm', '威律法律事務所', 'strat.market_view', NULL, NULL, '青創法律市場被簡榮宗、黃沛聲佔走一半以上，黃俐穎佔了 AppWorks 的缺；擔憂同領域強碰、不知如何成為特定領域最專業的律師', 'high', false, NULL, '青創被簡榮宗、黃沛聲佔走市場一半以上', 4),
  ('firm', '威律法律事務所', 'mkt.channel_mix', NULL, NULL, '以全律娛樂法委員會主委角色接觸產業界', 'high', false, NULL, NULL, 5),
  ('firm', '威律法律事務所', 'talent.training', NULL, NULL, '辦所內內訓，讓年輕律師做同領域低價案件、自己往中價案件移動；對「剛好及格」的律師不知怎麼處理', 'high', false, NULL, NULL, 6)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 21. 翁振德｜晉凱法律事務所（現登錄德承） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('晉凱法律事務所', DATE '2023-01-01', 'year', '受僱律師', '翁振德，執業 1.5 年，受僱／合署（原表所名空白，內容描述晉凱、推定為其任職所）', '拜訪',
   '晉凱：大量進用年輕律師、薪資高（執業 1.5 年月薪 6.8 萬），大量廣告＋免費諮詢收案，案件單價低（4.5 萬一件訴訟也收），一位律師背 70 件；台中起家發展快、想擴到其他地區。',
   '執業1年半｜受僱、合署｜6.8萬/月｜晉凱法律事務所，大量進用年輕律師，薪資高，大量以廣告及免費諮詢收案件，案件價格低（4.5萬一件訴訟也收），一個律師身上背70件／發展快速，以台中起家，希望擴展到其他地區') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '晉凱法律事務所', 'comp.associate_pay_band', 6.8::numeric, '='::text, '執業 1.5 年受僱月薪 6.8 萬（受訪者自述），所方形容「薪資高」', 'high', false, NULL::text, NULL::text, 1),
  ('firm', '晉凱法律事務所', 'talent.hiring_source', NULL, NULL, '大量進用年輕律師', 'high', false, 'moj_firm_statistics 2026-09：7 人；翁振德現登錄「德承法律事務所」（已離開）', NULL, 2),
  ('firm', '晉凱法律事務所', 'mkt.channel_mix', NULL, NULL, '大量廣告＋免費諮詢收案（B2C 行銷型）', 'high', false, 'firm_digital_signals / firm_analysis_facts.type 可核對晉凱型態', NULL, 3),
  ('firm', '晉凱法律事務所', 'client.pricing', 4.5, '<=', '案件價格低，一件訴訟 4.5 萬也收', 'high', false, NULL, '4.5萬一件訴訟也收', 4),
  ('firm', '晉凱法律事務所', 'talent.caseload', 70, '=', '一位律師身上背 70 件', 'high', false, NULL, NULL, 5),
  ('firm', '晉凱法律事務所', 'strat.market_view', NULL, NULL, '台中起家、發展快速，希望擴展到其他地區', 'medium', false, NULL, NULL, 6)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 22. 沈以軒｜宇恒法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('宇恒法律事務所', DATE '2023-01-01', 'year', '主持律師', '沈以軒，主持律師（原表作「宇恆」，MOJ 登錄名為宇恒）', '拜訪',
   '自稱台灣勞資第一大所：勞方案件起家→主動演講接觸人資→現以資方案件為主；1 老闆＋12 受僱；營收「接近 1 億？」（存疑）；前同仁出走開同型所（勝綸）。',
   '主持律師｜接近1Ｅ？｜1老闆、12受僱｜以勞資為主的事務所，先以勞方案件起家，後主動演講接觸人資，現主要處理資方案件，台灣勞資第一大所／之前同仁出來開類似事務所（勝綸法律事務所）') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '宇恒法律事務所', 'fin.revenue', 10000::numeric, '~'::text, '營收「接近 1 億？」——原表帶問號，僅供參考', 'low', false, 'firm_analysis_facts.rev_low/high 可對照 AI 推估'::text, NULL::text, 1),
  ('firm', '宇恒法律事務所', 'org.headcount', 13, '=', '1 位老闆＋12 位受僱', 'high', false, 'moj_firm_statistics 2026-09：18 人；沈以軒現仍登錄宇恒', NULL, 2),
  ('firm', '宇恒法律事務所', 'biz.niche', NULL, NULL, '勞資專門所：勞方案件起家→主動辦演講接觸人資→現以資方案件為主；自稱台灣勞資第一大所', 'high', false, 'lawyer_cause_stats 可核對宇恒勞資案由占比', '先以勞方案件起家，後主動演講接觸人資', 3),
  ('firm', '宇恒法律事務所', 'mkt.channel_mix', NULL, NULL, '以演講接觸企業人資取得資方案源', 'high', false, NULL, NULL, 4),
  ('firm', '宇恒法律事務所', 'talent.turnover', NULL, NULL, '前同仁出去開同型的勞資事務所（勝綸）', 'high', false, 'moj_firm_statistics 2026-09：勝綸 12 人', NULL, 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 23. 洪士軒｜安侯法律事務所（KPMG） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('安侯法律事務所', DATE '2023-01-01', 'year', '受僱律師', '洪士軒，執業 6 年，早稻田碩士（MOJ 名冊查無此名，或以其他登錄）', '拜訪',
   'KPMG 律所：5 合夥＋30 律師；受僱 6 年年收 200 萬；月薪 14 個月＋年終紅利約年薪 25–30%、旅遊補助 3 萬、請假自由。對比：寰瀛前三年月薪不到 7 萬；萬國起薪 5.8 萬但年終可能達年薪一半。會所體系風控限制多（外國客戶／政治風險案不准接），且律所要付 KPMG 營業額（或獲利）20% 授權金。',
   '執業6年，日本早稻田碩士生｜受僱｜200｜5個合夥老闆，30位律師｜ＫＰＭＧ薪資結構，月薪14個月，年終紅利約年薪的25~30%，員工旅遊補助3萬，請假算自由／之前在寰瀛，前三年月薪不到7萬，好友萬國起薪5.8萬，但年終紅利可能是年薪的一半／會所下律所因為風控制度有很多限制（與國外客戶有相關、政治風險相關等等都會不准接案），而且律所要ＫＰＭＧ給營業額（或著是獲利？）20%的授權金') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '安侯法律事務所', 'fin.personal_income', 200::numeric, '='::text, '受僱 6 年個人年收 200 萬', 'high', false, NULL::text, NULL::text, 1),
  ('firm', '安侯法律事務所', 'org.headcount', 35, '=', '5 位合夥老闆＋30 位律師', 'high', false, 'moj_firm_statistics 2026-09：安侯僅 7 人登錄——多數律師可能登錄於其他單位或未登錄，MOJ 名冊嚴重低估會所律所', NULL, 2),
  ('firm', '安侯法律事務所', 'comp.associate_pay_band', NULL, NULL, '月薪 14 個月＋年終紅利約年薪 25–30%；員工旅遊補助 3 萬；請假自由', 'high', false, NULL, '月薪14個月，年終紅利約年薪的25~30%', 3),
  ('firm', '安侯法律事務所', 'comp.bonus_ratio_to_base', 0.3, '~', '年終紅利約年薪 25–30%（約 3–4 個月）', 'high', false, NULL, NULL, 4),
  ('peer', '寰瀛法律事務所', 'comp.associate_pay_band', 7, '<', '前三年月薪不到 7 萬（受訪者親身經歷）', 'high', false, NULL, '之前在寰瀛，前三年月薪不到7萬', 5),
  ('peer', '萬國法律事務所', 'comp.associate_pay_band', 5.8, '=', '起薪 5.8 萬，但年終紅利可能達年薪一半（好友轉述）', 'medium', true, NULL, '好友萬國起薪5.8萬，但年終紅利可能是年薪的一半', 6),
  ('peer', '萬國法律事務所', 'comp.bonus_ratio_to_base', 0.5, '~', '年終紅利可能達年薪一半（轉述）', 'low', true, NULL, NULL, 7),
  ('firm', '安侯法律事務所', 'org.network_affiliation', 20, '=', '會所體系律所風控限制多（涉外國客戶、政治風險的案件不准接）；律所須付 KPMG 營業額（或獲利，受訪者不確定）20% 授權金', 'medium', false, NULL, '律所要ＫＰＭＧ給營業額（或著是獲利？）20%的授權金', 8)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 24. 蔡昆洲｜尚澄法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('尚澄法律事務所', DATE '2023-01-01', 'year', '主持律師', '蔡昆洲，主持律師（檢察事務官→櫃買中心／金管會→律師；倫敦大學、柏克萊 LLM）', '拜訪',
   '1 老闆＋6 受僱；商務為主但領域不斷變動（兩岸→區塊鏈→新創）；常參與國際會議開拓案源；希望事務所法人化；曾任北律理事現邊緣化。',
   '檢察事務官／櫃買中心&金管會／律師／倫敦大學、柏克萊大學ＬＬＭ｜主持律師｜1老闆、6受僱｜主要職業領域不斷變動，以商務為主，先做兩岸，後座區塊鏈、新創／常參與國際會議開拓案源／有希望事務所法人化／曾參與北律活動擔任理事，但現在邊緣化，在委員會任委員') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '尚澄法律事務所', 'org.headcount', 7::numeric, '='::text, '1 位老闆＋6 位受僱', 'high', false, 'moj_firm_statistics 2026-09：僅 1 人登錄（蔡昆洲）——受僱多未以此所登錄或已離開'::text, NULL::text, 1),
  ('firm', '尚澄法律事務所', 'biz.niche', NULL, NULL, '商務為主，領域隨潮流變動：兩岸→區塊鏈→新創', 'high', false, NULL, NULL, 2),
  ('firm', '尚澄法律事務所', 'mkt.channel_mix', NULL, NULL, '常參與國際會議開拓案源', 'high', false, NULL, NULL, 3),
  ('firm', '尚澄法律事務所', 'career.goal', NULL, NULL, '希望事務所法人化', 'high', false, NULL, NULL, 4),
  ('firm', '尚澄法律事務所', 'strat.market_view', NULL, NULL, '曾任北律理事、現在公會邊緣化只任委員', 'medium', false, NULL, NULL, 5)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 25. 劉韋廷｜立勤國際法律事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('立勤國際法律事務所', DATE '2023-01-01', 'year', '主持律師', '劉韋廷，主持律師（有電視節目「律由經」）', '拜訪',
   '全所約 29 律師＋14 合署、均採合署制，劉的單位 20–30 人，營收據稱 6,000 萬。靠媒體聲量吸案但價格不易高（10–15 萬）、媒體是雙面刃；堅持合署不合夥（不讓人搭便車，認為合夥是不好的制度）；外國合作所與社團案件都不獲利；EMBA 對管理思維有幫助。',
   '主持律師｜據稱6000｜全所約29位律師、14位合署律師／均採合署制，劉的單位可能20~30人｜手上有一個電視節目（律由經）／有媒體聲量，透過媒體聲量吸引案，但價格不容易爆高（10~15），媒體是兩面刃／堅持合署，不想讓人搭便車，認為合夥是不好的制度／外國合作所純粹有趣，零星案件不獲利／社團案件零星，投入產出不划算／ＥＭＢＡ對管理思維有幫助') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '立勤國際法律事務所', 'fin.revenue', 6000::numeric, '~'::text, '營收「據稱 6,000 萬」（劉的單位或全所不明）', 'low', false, 'firm_analysis_facts.rev_low/high 可對照'::text, NULL::text, 1),
  ('firm', '立勤國際法律事務所', 'org.headcount', 43, '~', '全所約 29 位律師＋14 位合署，均採合署制；劉的單位 20–30 人', 'high', false, 'moj_firm_statistics 2026-09：42 人（吻合）；劉韋廷、黃沛聲現仍登錄立勤', NULL, 2),
  ('firm', '立勤國際法律事務所', 'mkt.channel_mix', NULL, NULL, '電視節目「律由經」＋媒體聲量吸引案件；媒體是雙面刃', 'high', false, NULL, '媒體是兩面刃', 3),
  ('firm', '立勤國際法律事務所', 'client.pricing', 12.5, '~', '媒體帶來的案件價格不易衝高，約 10–15 萬', 'high', false, NULL, '價格不容易爆高（10~15）', 4),
  ('firm', '立勤國際法律事務所', 'org.partner_track', NULL, NULL, '堅持合署制、不合夥——不想讓人搭便車，認為合夥是不好的制度', 'high', false, NULL, '堅持合署，不想讓人搭便車', 5),
  ('firm', '立勤國際法律事務所', 'org.network_affiliation', NULL, NULL, '外國合作所純粹有趣，零星案件不獲利', 'high', false, NULL, NULL, 6),
  ('firm', '立勤國際法律事務所', 'mkt.effect_view', NULL, NULL, '社團案件零星、投入產出不划算；EMBA 對管理思維有幫助', 'high', false, NULL, NULL, 7)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 26. 梁維珊｜成鼎律師事務所 ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('成鼎律師事務所', DATE '2023-01-01', 'year', '主持律師', '梁維珊，執業 13 年，與先生共同開所', '拜訪',
   '營收約 1,000 萬；梁下 1 受僱＋2 實習；高價家事定價（一審離婚 25 萬＋定暫時狀態 15 萬，涉外／外縣市另加），能收高價因隨時聯絡得上、英文好、懂家事法、能處理情緒，手上有夏克立、福原愛等知名國際案；認為管理是難題；轉述蘇奕銓經營法（工讀生潛入群組接案、重輪轉率、自己處理客訴、能不寫狀就不寫）；提到希望與喆律合作。',
   '執業13年｜主持律師｜1000｜與先生共同開鎖，目前梁下面一位受僱兩位實習｜收費較高，一審離親收25萬＋定暫15萬，涉外另加、外縣市另加／認為可收高價的原因（讓當事人隨時聯絡得上、英文好、懂家事法、能處理當事人情緒），手上有知名國際案件 ＥＸ夏克立、福原愛／覺得管理是難題／有聊到蘇奕銓的經營方式（找工讀生加入可能發生問題的群組接案、案件重視輪轉率（反正案件本質也決定了勝敗）、自己處理客訴、能不寫狀就不寫狀）／希望跟喆律合作？') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '成鼎律師事務所', 'fin.revenue', 1000::numeric, '='::text, '營收約 1,000 萬', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '成鼎律師事務所', 'org.headcount', 5, '~', '夫妻共同開所；梁下 1 位受僱＋2 位實習', 'high', false, 'moj_firm_statistics 2026-09：6 人；梁維珊現仍登錄成鼎', NULL, 2),
  ('firm', '成鼎律師事務所', 'client.pricing', 25, '=', '高價家事：一審離婚收 25 萬＋定暫時狀態處分 15 萬；涉外、外縣市另加', 'high', false, NULL, '一審離親收25萬＋定暫15萬', 3),
  ('firm', '成鼎律師事務所', 'biz.niche', NULL, NULL, '高價家事定位——能收高價的理由：當事人隨時聯絡得上、英文好、懂家事法、能處理當事人情緒；手上有知名國際案（夏克立、福原愛）', 'high', false, NULL, NULL, 4),
  ('firm', '成鼎律師事務所', 'org.decision_style', NULL, NULL, '覺得管理是難題', 'high', false, NULL, NULL, 5),
  ('peer', '（蘇奕銓律師所屬所，未載）', 'org.decision_style', NULL, NULL, '蘇奕銓經營法（轉述）：派工讀生加入可能出事的群組接案、案件重視輪轉率（案件本質決定勝敗）、自己處理客訴、能不寫狀就不寫狀', 'medium', true, NULL, '案件重視輪轉率（反正案件本質也決定了勝敗）', 6),
  ('firm', '成鼎律師事務所', 'strat.collab_interest', NULL, NULL, '提到希望與喆律合作（原表帶問號，意願待確認）', 'low', false, NULL, '希望跟喆律合作？', 7)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 27. 黃沛聲｜立勤國際法律事務所（黃的單位） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('立勤國際法律事務所', DATE '2023-01-01', 'year', '主持律師', '黃沛聲，主持律師（立勤合署制下自己的單位，10 位律師以下）', '拜訪',
   '單位營收 2,000–3,000 萬、10 位律師以下；一半時間做創投（主投美國市場）；法律業務在青創圈（同圈競爭者：簡榮宗、王俐瑩、蔡坤洲）；提及台灣沒有信託牌的信託業務機會；自稱與政界學界關係好，與政大合辦法律簡報大賽。',
   '主持律師｜2000~3000｜黃的單位10位律師以下｜一半時間在做創投（主投針對美國市場服務）／法律業務主要在青創圈（主要競爭者有黃沛聲、簡榮宗、王俐瑩、蔡坤洲、）／提及信託業務（台灣目前沒有信託牌）／稱與政界學界關係良好，與政大合辦法律簡報大賽') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '立勤國際法律事務所', 'fin.revenue', 2500::numeric, '~'::text, '黃沛聲單位營收 2,000–3,000 萬（立勤合署制，非全所）', 'medium', false, NULL::text, NULL::text, 1),
  ('firm', '立勤國際法律事務所', 'org.headcount', 10, '<', '黃的單位 10 位律師以下', 'high', false, NULL, NULL, 2),
  ('firm', '立勤國際法律事務所', 'career.side_business', NULL, NULL, '一半時間做創投，主投針對美國市場的服務', 'high', false, NULL, NULL, 3),
  ('firm', '立勤國際法律事務所', 'biz.niche', NULL, NULL, '法律業務主要在青創圈；同圈主要競爭者：簡榮宗、王俐瑩、蔡坤洲', 'high', false, '與威律周逸濱訪談互證：青創市場由黃沛聲、簡榮宗佔過半', NULL, 4),
  ('firm', '立勤國際法律事務所', 'strat.market_view', NULL, NULL, '看好信託業務（台灣目前沒有信託牌）', 'medium', false, NULL, NULL, 5),
  ('firm', '立勤國際法律事務所', 'mkt.channel_mix', NULL, NULL, '自稱與政界學界關係良好，與政大合辦法律簡報大賽', 'medium', false, NULL, NULL, 6)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 28. 周宇修｜謙眾國際法律事務所（2024 再訪） ----------
WITH n AS (INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, summary, raw_notes) VALUES
  ('謙眾國際法律事務所', DATE '2024-01-01', 'year', '主持律師', '周宇修，年資 16 年（2024 再訪）', '拜訪',
   '事務所兩位主要合夥人分房租（合署形式），周自己帶一位受僱；受僱不特別喜歡無償公益案，除非另有收入；銀行案件從金融研訓院演講起家；職涯希望出一本反歧視法著作。',
   '年資16｜事務所有兩個主要合夥人分房租（合署形式），周律師自己一個受雇／周有讓受雇參與公益案件，受僱其實不特別喜歡無償公益案件，除非另外有收入／銀行相關案件主要是從去金融研訓院演講開始做起／律師職涯希望出一本反歧視法的著作') RETURNING id)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '謙眾國際法律事務所', 'org.headcount', NULL::numeric, NULL::text, '兩位主要合夥人分房租（合署形式）；周自己帶一位受僱', 'high', false, 'moj_firm_statistics 2026-09：11 人；周宇修現仍登錄謙眾'::text, NULL::text, 1),
  ('firm', '謙眾國際法律事務所', 'talent.turnover', NULL, NULL, '受僱不特別喜歡無償公益案件，除非另有收入（與 2023 訪談一致）', 'high', false, NULL, NULL, 2),
  ('firm', '謙眾國際法律事務所', 'mkt.channel_mix', NULL, NULL, '銀行相關案件從去金融研訓院演講開始做起', 'high', false, NULL, NULL, 3),
  ('firm', '謙眾國際法律事務所', 'career.goal', NULL, NULL, '希望出一本反歧視法的著作', 'high', false, NULL, NULL, 4)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

COMMIT;
