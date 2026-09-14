-- ============================================================
-- 200: 面試筆記情報第一版入庫（雷皓明 2026-09-14 拍板；草案 scripts/.interview_work/mig200_facts_draft.md）
-- ============================================================
-- 來源：北所面試筆記 109–115 年第一版抽取（38 塊／409 位候選人；10 塊逐字查核；律師類 15 塊已與 MOJ 名冊比對）。
-- 三層：
--   (1) interview_market_bands 新表＝規模級距（名冊律師數）×職位×年度 的數字市場帶（≥3 位不同候選人才入、≥5 位才給四分位）
--   (2) firm_field_facts subject_scope='peer'＝事務所層質性觀察（≥3 位不同候選人、仍在職者條目排除、文字改寫、secondhand=true）
--   (3) 喆律層：期待薪資（bands size_band='zhelu'）＋雇主品牌主題＋人才競爭雇主（facts subject_scope='firm'）
-- 去識別化：無候選人姓名／參照碼／面試日期；無逐字引述；健康婚育與指控類不入；主持律師姓名改職稱；喆律自身前東家 4 筆排除。
-- 拍板：Q1 小所也開事務所層（吳弘鵬、南昌，名冊 1 位）；Q2 安侯保留、標單一來源；Q3 期待薪資入庫；
--       Q4 數字帶用新表；Q5 加 comp.bonus_months；Q6 未查核 3 家（萬國、理律、巨展）先入庫、信心 low。
-- 權限：新表 admin-only（仿 196）。重算：scripts/.interview_work/bands.ps1（零 token）。前端「面試筆記市場帶」面板另做。
BEGIN;

-- ---------- 1. 維度 17 個 ----------
INSERT INTO field_note_dimensions (key, grp, grp_label, label, unit, description, sort) VALUES
  ('comp.staff_pay_band',           'comp',   '薪酬結構', '法務／助理薪資帶',       '千元/月', '律所非律師人員底薪（面試筆記口徑）', 17),
  ('comp.trainee_pay',              'comp',   '薪酬結構', '實習律師月薪',           '千元/月', '實習律師與實習轉受僱初期月薪', 18),
  ('comp.new_case_bonus',           'comp',   '薪酬結構', '新案獎金',               '元/件',   '每承接一件新案的獎金', 19),
  ('comp.overtime_pay',             'comp',   '薪酬結構', '加班費制度',             NULL,      '有／無／補休（類別）', 20),
  ('comp.benefits',                 'comp',   '薪酬結構', '福利項目',               NULL,      '公會費、餐費、公務機等', 21),
  ('comp.bonus_months',             'comp',   '薪酬結構', '年終＋三節月數',         '月',      '年終與三節合計相當於幾個月底薪（與 comp.bonus_ratio_to_base 倍數口徑不同）', 22),
  ('work.hours',                    'work',   '工時',     '工時與加班頻率',         '小時/週', '常態工時、加班頻率、責任制', 45),
  ('org.lawyer_staff_ratio',        'org',    '組織治理', '律師對非律師比',         '比值',    '律師人數／非律師人數', 26),
  ('org.tools',                     'org',    '組織治理', '案件管理系統與工具',     NULL,      '案管系統、工時申報、雲端例稿等', 27),
  ('org.distress_signal',           'org',    '組織治理', '所況警訊',               '事件數',  '資遣、縮編、拆夥、合夥人離開', 28),
  ('biz.case_mix_share',            'biz',    '業務線',   '案型占比',               '%',       '民事／刑事／家事／非訟占比（自述）', 53),
  ('talent.tenure',                 'talent', '人才',     '在職月數',               '月',      '候選人在該所任職月數', 72),
  ('talent.exit_reason_mix',        'talent', '人才',     '離職原因結構',           '%',       '離職原因主題占比', 73),
  ('talent.trainee_conversion',     'talent', '人才',     '實習轉正情形',           NULL,      '實習律師是否獲留任及原因', 74),
  ('talent.competing_employer',     'talent', '人才',     '人才競爭雇主',           '次',      '候選人同時應徵或拿到錄取的雇主', 75),
  ('talent.applicant_expected_pay', 'talent', '人才',     '應徵喆律者期待薪資',     '千元/月', '面試時的期待月薪（彙總，n≥5）', 76),
  ('strat.employer_brand',          'strat',  '戰略',     '喆律雇主品牌認知',       '%',       '候選人對喆律印象的主題占比', 92)
ON CONFLICT (key) DO UPDATE SET grp=EXCLUDED.grp, grp_label=EXCLUDED.grp_label, label=EXCLUDED.label,
  unit=EXCLUDED.unit, description=EXCLUDED.description, sort=EXCLUDED.sort;

-- ---------- 2. 新表：規模級距數字市場帶 ----------
CREATE TABLE IF NOT EXISTS interview_market_bands (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  note_id        bigint REFERENCES firm_field_notes(id) ON DELETE CASCADE,   -- 錨點（channel='面試筆記彙整'）
  dimension_key  text NOT NULL REFERENCES field_note_dimensions(key),
  level          text NOT NULL,        -- band×pos×year / band×pos / pos×year / pos / role×year / role
  size_band      text NOT NULL,        -- 1-3 / 4-10 / 11-30 / 31+ / unknown / all / zhelu（前東家在 MOJ 名冊的登錄律師數）
  position_kind  text NOT NULL,        -- lawyer / trainee-lawyer / legal-staff-admin / part-time / other / all；喆律層放職缺名
  year           int,                  -- 面試民國年；NULL＝全部年度
  unit           text NOT NULL,
  n_entries      int NOT NULL,
  n_candidates   int NOT NULL,         -- 不同候選人數（發布門檻 ≥3）
  n_firms        int,
  median         numeric,
  p25            numeric,              -- n_candidates ≥5 才有
  p75            numeric,
  cat_counts     jsonb,                -- 類別型（加班費 {"有":2,"無":11,"補休":0}）
  verified_share int,                  -- 已逐字查核條目占比 %
  source_version text NOT NULL DEFAULT 'v1-38chunks',
  computed_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (dimension_key, level, size_band, position_kind, year, source_version)
);
CREATE INDEX IF NOT EXISTS idx_imb_dim_band ON interview_market_bands(dimension_key, size_band);
ALTER TABLE interview_market_bands ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS interview_market_bands_admin_read ON interview_market_bands;
CREATE POLICY interview_market_bands_admin_read ON interview_market_bands
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));
COMMENT ON TABLE interview_market_bands IS '面試筆記彙整的數字市場帶（admin 限定）：名冊級距×職位×年度×維度；n_candidates≥3 才入、≥5 才有四分位；由 scripts/.interview_work/bands.ps1 重算';

-- ---------- 3. 錨點 note ----------
INSERT INTO firm_field_notes (firm, interviewed_on, date_precision, source_role, source_desc, channel, interviewer, summary, raw_notes)
VALUES (
  '喆律法律事務所', DATE '2026-09-14', 'day', '其他',
  '北所面試筆記 109–115 年彙整（第一版：38 塊／409 位候選人；律師類 15 塊已與 MOJ 名冊比對；第二版 32 塊由夜間管線續抽）',
  '面試筆記彙整', 'Claude（雷皓明委託）',
  '409 位候選人揭露 236 家所的前東家情報；受僱律師底薪集中 60 千元、名冊級距間差異小，差距在年終月數與加班費；' ||
  '主流是主持律師一人掌接案、受僱自行開庭；離職首因是學不到與帶人方式，非薪資。',
  NULL
);

-- ---------- 4. 事務所層 peer facts（10 家）----------
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM
  (SELECT id FROM firm_field_notes WHERE channel = '面試筆記彙整' AND interviewed_on = DATE '2026-09-14' ORDER BY id DESC LIMIT 1) n,
  (VALUES
  -- 任遠國際法律事務所（名冊 12 位；候選人 5、113–115 年、已查核 5/5）
  ('peer', '任遠國際法律事務所', 'org.headcount', 12::numeric, '~'::text,
     '自述 2 位主持律師（法官退下）＋受僱律師 4 位＋部門主管、助理、工讀；自述受僱數低於名冊 12 位', 'medium', true, 'moj_firm_statistics：12 位；名冊平均案量 150', NULL::text, 1),
  ('peer', '任遠國際法律事務所', 'comp.associate_pay_band', 6, '>=',
     '受僱律師月薪 6–7.5 萬（2 筆，114 年）；年終 2 個月＋三節半個月（1 筆，另 1 筆年資不足未領）', 'medium', true, NULL, NULL, 2),
  ('peer', '任遠國際法律事務所', 'talent.caseload', 50, '~',
     '受僱律師每人在手約 50 件、實際推動 30–45 件；候選人自認能兼顧品質的量是 30–40 件', 'medium', true, '名冊平均案量 150（所級口徑，分母 12 位）', NULL, 3),
  ('peer', '任遠國際法律事務所', 'org.decision_style', NULL, NULL,
     '接案與分案集中在所長；同案分派兩位律師、權責不清；所長對個案掌握度低、書狀回饋少；出缺勤不管理、責任制', 'high', true, '2 位受僱律師口徑一致', NULL, 4),
  ('peer', '任遠國際法律事務所', 'client.mix', NULL, NULL,
     '訴訟為主：民事 7–8 成（金融詐騙、車禍）、刑事 2–3 成；不挑案', 'medium', true, NULL, NULL, 5),
  ('peer', '任遠國際法律事務所', 'talent.turnover', NULL, NULL,
     '流動率高，受僱最資深約 1 年；5 位候選人（律師 2、法務 1、工讀 2）皆於 2 年內離開', 'medium', true, 'moj_lawyer_changes 可回查 2026-07 起異動', NULL, 6),
  ('peer', '任遠國際法律事務所', 'work.hours', NULL, NULL,
     '法務／行政端經常性加班；律師端責任制、無出缺勤管理', 'medium', true, NULL, NULL, 7),
  -- 群勝國際法律事務所（名冊 5 位；候選人 3、114 年、已查核 2/3）
  ('peer', '群勝國際法律事務所', 'org.headcount', 10, '~',
     '自述約 10 位律師＋2 位顧問＋行政 3 位（含秘書），實習律師多；名冊僅 5 位，名冊低估（實習律師未登錄）', 'medium', true, 'moj_firm_statistics：5 位；名冊平均案量 46', NULL, 11),
  ('peer', '群勝國際法律事務所', 'biz.niche', NULL, NULL,
     '涉外所：外國客戶 7–8 成（性侵性騷、企業法顧、勞資、外籍家事、白領犯罪）；主打英文、與海外律師合作', 'high', true, NULL, NULL, 12),
  ('peer', '群勝國際法律事務所', 'mkt.channel_mix', NULL, NULL,
     '所長以商會開源（BNI、獅子會、扶輪社）；得獎後獲推薦；案源多元', 'medium', true, NULL, NULL, 13),
  ('peer', '群勝國際法律事務所', 'comp.associate_pay_band', 6, '~',
     '實習 5.5 萬→受僱 6 萬；另一位受僱 6.5 萬；三節不固定（數千至 1 萬）、年終 1–2 個月（依律師為所貢獻計算）', 'medium', true, NULL, NULL, 14),
  ('peer', '群勝國際法律事務所', 'comp.overtime_pay', NULL, NULL,
     '有加班費制度，但申報多者三節與其他獎金減少，實質抑制申報（2 筆一致）', 'high', true, NULL, NULL, 15),
  ('peer', '群勝國際法律事務所', 'comp.staff_pay_band', 50, '=',
     '法務助理 5 萬／月（2 年資，年薪約 70 萬）；法務工作多被實習律師分走', 'medium', true, NULL, NULL, 16),
  ('peer', '群勝國際法律事務所', 'client.pricing', NULL, NULL,
     '法顧按時數計費；報價含主持律師與受僱律師雙人時數及內部會議時數', 'low', true, NULL, NULL, 17),
  ('peer', '群勝國際法律事務所', 'work.hours', NULL, NULL,
     '常態加班：平日約 10 小時、忙季 12–14 小時延續一個月；假日偶需工作', 'medium', true, NULL, NULL, 18),
  ('peer', '群勝國際法律事務所', 'talent.turnover', NULL, NULL,
     '主管律師離職連帶新進律師離開；法務因無專設法務工作離職', 'medium', true, NULL, NULL, 19),
  -- 誠瀛法律事務所（名冊 11 位；候選人 3、113–114 年、已查核 1/3）
  ('peer', '誠瀛法律事務所', 'org.headcount', 11, '=',
     '自述 1 主持＋1 顧問律師＋2 合夥＋7 律師＋4 實習律師；非律師 3＋工讀 2；與名冊一致', 'high', true, 'moj_firm_statistics：11 位；名冊平均案量 50', NULL, 21),
  ('peer', '誠瀛法律事務所', 'mkt.channel_mix', NULL, NULL,
     '案源含國際通商轉介（候選人口述，未詳）', 'low', true, NULL, NULL, 22),
  ('peer', '誠瀛法律事務所', 'talent.trainee_conversion', NULL, NULL,
     '3 位實習律師僅留 1 位（舊人回流補足人力）；工讀無轉正、不擴編', 'medium', true, NULL, NULL, 23),
  ('peer', '誠瀛法律事務所', 'org.decision_style', NULL, NULL,
     '所長統領、其餘水平無階級；主管律師風格差異大（忙碌無細節／即時稱讚但標準不一／彈性）；秘書統一指派工讀；老闆會交辦私人事務', 'medium', true, NULL, NULL, 24),
  ('peer', '誠瀛法律事務所', 'client.mix', NULL, NULL,
     '民事家事為主、偶有刑事；金融案件（金保法評議）、確認收養、法顧審約；客戶自民眾到金融大公司', 'medium', true, NULL, NULL, 25),
  ('peer', '誠瀛法律事務所', 'talent.caseload', 18, '~',
     '實習律師在手 16–20 件（法顧家數也算 1 件）', 'medium', true, NULL, NULL, 26),
  ('peer', '誠瀛法律事務所', 'work.hours', NULL, NULL,
     '加班少：前兩個月每週 2–3 小時，之後幾乎不加班', 'medium', true, NULL, NULL, 27),
  -- 崇錦法律事務所（名冊 12 位；候選人 3、114 年、已查核 2/3）
  ('peer', '崇錦法律事務所', 'org.headcount', 12, '~',
     '4 位合夥（3 訴訟＋1 非訟）＋顧問 1–2＋律師 8＋法務 1＋會計 1；行政 3＋工讀 2；與名冊一致', 'high', true, 'moj_firm_statistics：12 位；名冊平均案量 90', NULL, 31),
  ('peer', '崇錦法律事務所', 'biz.niche', NULL, NULL,
     '非訟比重高（能源案場租約、化妝品／食品／醫美廣告合規、法律意見書、SPA）；訴訟以民事家事為主；法人客戶集中能源、食品、化妝品業', 'high', true, NULL, NULL, 32),
  ('peer', '崇錦法律事務所', 'comp.trainee_pay', 55, '~',
     '實習→受僱 55–60 千元（試用 55、正式 58、受僱 60）', 'high', true, NULL, NULL, 33),
  ('peer', '崇錦法律事務所', 'comp.bonus_months', 2, '~',
     '年終保底 2 個月（另一筆記為 13 個月年薪）；三節 6 千–1 萬；不定期獎金 1–2 萬', 'medium', true, NULL, NULL, 34),
  ('peer', '崇錦法律事務所', 'comp.overtime_pay', NULL, NULL,
     '無加班費（2 筆一致）', 'high', true, NULL, NULL, 35),
  ('peer', '崇錦法律事務所', 'work.hours', NULL, NULL,
     '非訟組常態加班至 20–22 點；訴訟組加班亦不少', 'medium', true, NULL, NULL, 36),
  ('peer', '崇錦法律事務所', 'org.decision_style', NULL, NULL,
     '老闆接案分配→新進律師初稿→資深律師審→合夥人再改；訴訟由合夥親帶並即時說明修改原因；審約回饋則少', 'medium', true, NULL, NULL, 37),
  ('peer', '崇錦法律事務所', 'org.partnership_dynamics', NULL, NULL,
     '2 位合夥人預告離開、業務受影響；4 位合夥各自獨立、部分合作', 'medium', true, 'moj_lawyer_changes 可回查', NULL, 38),
  ('peer', '崇錦法律事務所', 'talent.turnover', NULL, NULL,
     '3 位候選人皆於受僱 10–18 個月內離開：案型比例與談定不符、想轉訴訟、合夥變動', 'medium', true, NULL, NULL, 39),
  -- 萬國法律事務所（名冊 104 位；候選人 3、113–115 年、已查核 0/3 → 全部 low）
  ('peer', '萬國法律事務所', 'org.decision_style', NULL, NULL,
     '一案配置合夥＋資深＋資淺＋實習的分層協作；受僱律師好溝通，合夥人較少直接談處理方式', 'low', true, 'moj_firm_statistics：104 位；未逐字查核', NULL, 41),
  ('peer', '萬國法律事務所', 'org.lawyer_staff_ratio', 4.5, '~',
     '行政助理 1 人配 4–5 位律師（訴訟組）', 'low', true, '未逐字查核', NULL, 42),
  ('peer', '萬國法律事務所', 'talent.trainee_conversion', NULL, NULL,
     '實習期滿無受僱缺額，同期 2 位皆未留', 'low', true, '未逐字查核', NULL, 43),
  ('peer', '萬國法律事務所', 'client.mix', NULL, NULL,
     '新當事人來電先由實習律師初步了解、經利衝查詢確定接案後才回覆', 'low', true, '未逐字查核', NULL, 44),
  ('peer', '萬國法律事務所', 'work.hours', NULL, NULL,
     '實習律師密集 8 小時；行政秘書一週加班 3 天，隨律師案量', 'low', true, '未逐字查核', NULL, 45),
  ('peer', '萬國法律事務所', 'comp.staff_pay_band', 35, '=',
     '行政秘書 3.5 萬／月（6 年資）', 'low', true, '未逐字查核', NULL, 46),
  -- 理律法律事務所（名冊 209 位；候選人 3、114–115 年、已查核 0/3 → 全部 low）
  ('peer', '理律法律事務所', 'org.decision_style', NULL, NULL,
     '部門分工細（訴訟／投資／商標）；實習律師只做法律研究、不知案件全貌；主管不押期限但急迫、少指導', 'low', true, 'moj_firm_statistics：209 位；未逐字查核', NULL, 51),
  ('peer', '理律法律事務所', 'work.hours', NULL, NULL,
     '實習律師 9–22 點、返家續作；工時系統每日申報上限 4 小時；法務行政準時下班、一年加班 2 次', 'low', true, '未逐字查核', NULL, 52),
  ('peer', '理律法律事務所', 'comp.staff_pay_band', 50, '=',
     '法務行政 5 萬／月＋三節＋年終 3–4 個月（年薪約 80 萬）＋推薦獎金', 'low', true, '未逐字查核', NULL, 53),
  ('peer', '理律法律事務所', 'talent.trainee_conversion', NULL, NULL,
     '留職停薪者回任致同期 3 位實習皆未留', 'low', true, '未逐字查核', NULL, 54),
  ('peer', '理律法律事務所', 'org.tools', NULL, NULL,
     '工時申報系統；非法律系事務員有專線詢問法律見解', 'low', true, '未逐字查核', NULL, 55),
  -- 巨展法律事務所（名冊 6 位；候選人 3、114–115 年、已查核 0/3 → 全部 low）
  ('peer', '巨展法律事務所', 'org.partnership_dynamics', NULL, NULL,
     '4 位合夥各自部門、溝通少、很少開會，運作近似合署', 'low', true, 'moj_firm_statistics：6 位；未逐字查核', NULL, 61),
  ('peer', '巨展法律事務所', 'org.model_lineage', NULL, NULL,
     '主持律師檢察官出身', 'low', true, 'ex_judicial 徽章可對照；未逐字查核', NULL, 62),
  ('peer', '巨展法律事務所', 'client.mix', NULL, NULL,
     '實習組刑事 6 成、民事 2–3 成、家事 1 成；他組偏民事債務、契約、分割共有物', 'low', true, '未逐字查核', NULL, 63),
  ('peer', '巨展法律事務所', 'org.decision_style', NULL, NULL,
     '主持律師每週進所 1–3 天，不在時實習須向別組受僱請教；行政 SOP 嚴（每日下班前對大表）；不趕時教學耐心', 'low', true, '未逐字查核', NULL, 64),
  ('peer', '巨展法律事務所', 'work.hours', NULL, NULL,
     '實習不被要求加班（書狀作業期 3–10 天）；法務找判決無形加班', 'low', true, '未逐字查核', NULL, 65),
  ('peer', '巨展法律事務所', 'talent.turnover', NULL, NULL,
     '人才流失快、一人當兩人用；實習婉拒轉正（受僱模式不扎實）', 'low', true, '未逐字查核', NULL, 66),
  -- 安侯法律事務所（名冊 7 位；候選人 3 但實質來源 1 位受僱律師（已查核），雷拍板保留、標單一來源）
  ('peer', '安侯法律事務所', 'comp.associate_pay_band', 120, '~',
     '受僱律師 3 年資年薪 120–130 萬含獎金（年終固定 2 個月＋績效約 2 個月）——年薪口徑（單一來源）', 'medium', true, 'moj_firm_statistics：7 位；名冊平均案量 2；單一來源、已查核', NULL, 71),
  ('peer', '安侯法律事務所', 'biz.niche', NULL, NULL,
     '商務非訟：併購、跨境（日本／歐洲）交易、藥廠和解、公司登記；大型公司法顧為主、中小企業僅 5%（單一來源）', 'medium', true, '名冊平均案量 2，非訟所口徑吻合；單一來源', NULL, 72),
  ('peer', '安侯法律事務所', 'client.pricing', NULL, NULL,
     '既定範本多、依客戶預算安排（單一來源）', 'low', true, '單一來源', NULL, 73),
  ('peer', '安侯法律事務所', 'org.decision_style', NULL, NULL,
     '主持律師分案並對客戶，受僱多為第二手訊息；大案配資深律師共同報告（單一來源）', 'medium', true, '單一來源', NULL, 74),
  -- 吳弘鵬律師事務所（名冊 1 位；候選人 5、113–115 年、已查核 3/5；雷拍板 Q1 B 小所也開）
  ('peer', '吳弘鵬律師事務所', 'org.headcount', 6, '~',
     '自述 2 位所長（台北所＋新莊所）＋受僱律師 2 位＋各所 1 位法務櫃檯；另一時期 2 位律師＋4 位助理；名冊僅登錄 1 位、嚴重低估', 'high', true, 'moj_firm_statistics：1 位；名冊平均案量 503（分母失真）', NULL, 81),
  ('peer', '吳弘鵬律師事務所', 'mkt.channel_mix', NULL, NULL,
     '免費法律諮詢是主要案源：當事人事前填表→所長標重點→受僱單獨諮詢，每週 3–4 場；受僱約 5–7 場成一件、所長約 3 場成一件', 'high', true, '2 筆已查核一致', NULL, 82),
  ('peer', '吳弘鵬律師事務所', 'talent.caseload', 65, '~',
     '受僱在手 60–70 件（2 筆）、另一位 80–90 件；民事 4 成、家事 2 成、刑事 4 成', 'high', true, NULL, NULL, 83),
  ('peer', '吳弘鵬律師事務所', 'comp.trainee_pay', 60, '=',
     '實習→受僱 60 千元；三節各 1 萬、年終 1 個月；有加班費、配公務機（2 筆一致）', 'high', true, NULL, NULL, 84),
  ('peer', '吳弘鵬律師事務所', 'comp.overtime_pay', NULL, NULL,
     '有加班費；工時 09–18，一般加班到 19 點離開；下班後非緊急不用回訊息', 'high', true, NULL, NULL, 85),
  ('peer', '吳弘鵬律師事務所', 'org.decision_style', NULL, NULL,
     '諮詢後由受僱全權聯繫當事人、法院與開庭；所長不挑案（品質差的案也接）；打卡與離開報備制、公務機群組', 'high', true, NULL, NULL, 86),
  ('peer', '吳弘鵬律師事務所', 'client.mix', NULL, NULL,
     '民事家事刑事綜合小案（車禍和解、土地分割、藥師法行政罰、公然侮辱）；不挑案', 'high', true, NULL, NULL, 87),
  ('peer', '吳弘鵬律師事務所', 'talent.turnover', NULL, NULL,
     '法務櫃檯約 3 個月一換；3 位實習轉受僱者各任職約 1 年後離開（家庭因素、想去台北大所歷練、案量累）；離職者仍有意願回任', 'medium', true, NULL, NULL, 88),
  -- 南昌法律事務所（名冊 1 位；候選人 3、113–114 年、已查核 1/3；雷拍板 Q1 B 小所也開）
  ('peer', '南昌法律事務所', 'org.headcount', 4, '~',
     '自述 1 位老闆＋受僱 2＋實習 1＋助理 3；助理與律師一對一；名冊僅登錄 1 位', 'medium', true, 'moj_firm_statistics：1 位；名冊平均案量 321（分母失真）', NULL, 91),
  ('peer', '南昌法律事務所', 'mkt.channel_mix', NULL, NULL,
     '老闆親友與商會；國產署標案（複代理人）；網路諮詢；企業法顧駐點；村里服務諮詢（轉換低）', 'medium', true, 'gov_tenders 可查國產署複代理人標案', NULL, 92),
  ('peer', '南昌法律事務所', 'comp.associate_pay_band', 8, '=',
     '受僱約 2 年資實拿 8 萬／月；年終 0.5–1 個月、偶有節金、達業績量有年底抽成（單一來源、已查核）', 'medium', true, '單一來源', NULL, 93),
  ('peer', '南昌法律事務所', 'talent.caseload', 100, '~',
     '受僱約 2 年在手約 100 件（面試官另記 150）；實習訴訟約 10 件＋網路諮詢＋2 家法顧', 'medium', true, NULL, NULL, 94),
  ('peer', '南昌法律事務所', 'org.decision_style', NULL, NULL,
     '老闆以 LINE 交辦、分案隨機；書狀多未經審閱直接出；受僱把庶務與寫狀交給實習再回報；老闆偶爾開庭；案件單純就套舊範本、效率優先', 'medium', true, '2 筆口徑一致（範本、交辦）', NULL, 95),
  ('peer', '南昌法律事務所', 'talent.training', NULL, NULL,
     '實習有月別進程：第 1 月寫狀、第 2 月接觸當事人、第 3 月負責特定當事人、第 5–6 月跟庭', 'low', true, '未逐字查核', NULL, 96),
  ('peer', '南昌法律事務所', 'work.hours', NULL, NULL,
     '彈性上班、開完庭可回家；但需兼做老闆的研究與寫狀', 'low', true, NULL, NULL, 97),
  ('peer', '南昌法律事務所', 'talent.turnover', NULL, NULL,
     '主管律師離職後實習直接對老闆而結束實習；受僱約 2.7 年後離開（環境過於自由、無人可問）', 'medium', true, NULL, NULL, 98),
  ('peer', '南昌法律事務所', 'client.mix', NULL, NULL,
     '民事家事 8 成、刑事 1 成、政府採購 1 成（機關當事人省溝通成本）', 'medium', true, NULL, NULL, 99)
  ) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 5. 喆律層 facts（雇主品牌主題＋人才競爭雇主）----------
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM
  (SELECT id FROM firm_field_notes WHERE channel = '面試筆記彙整' AND interviewed_on = DATE '2026-09-14' ORDER BY id DESC LIMIT 1) n,
  (VALUES
  ('firm', '喆律法律事務所', 'strat.employer_brand', 23::numeric, '='::text, '吸引：熟人推薦與內部口碑是最大拉力（全部 23%、律師職缺 41%）', 'medium', true,
     '第一版分析主題編碼：有實質內容者 n=365、律師職缺 n=71、法顧律師 n=20；未逐條複核', NULL::text, 101),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 23, '=', '吸引：案件多元與家事專長（全部 23%、律師職缺 39%）', 'medium', true, '同上', NULL, 102),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 22, '=', '吸引：氛圍口碑（全部 22%、律師職缺 23%）', 'medium', true, '同上', NULL, 103),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 18, '=', '吸引：制度、培訓、系統（全部 18%、律師職缺 34%）', 'medium', true, '同上', NULL, 104),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 17, '=', '吸引：品牌與自媒體曝光（全部 17%、律師職缺 17%）', 'medium', true, '同上', NULL, 105),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 15, '=', '吸引：規模帶來的案件與交流機會（全部 15%、律師職缺 27%）', 'medium', true, '同上', NULL, 106),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 13, '=', '疑慮：加班與工時是最大負債（全部 13%、律師職缺 20%、法顧律師 35%）', 'medium', true, '同上', NULL, 107),
  ('firm', '喆律法律事務所', 'strat.employer_brand', 3, '=', '疑慮：案量與分案；候選人聽到的案量數字互相矛盾（全部 3%、律師職缺 8%、法顧律師 15%）', 'medium', true, '同上', NULL, 108),
  ('firm', '喆律法律事務所', 'talent.competing_employer', NULL, NULL, '律師職缺：對手以中小型訴訟所為主（律所 24 筆，已查核 11）；大所僅個位數', 'medium', true, '第一版分析；competing_offers 欄 218/409 有記載', NULL, 111),
  ('firm', '喆律法律事務所', 'talent.competing_employer', NULL, NULL, '法務職缺：近半同時應徵企業法務（48／114）', 'medium', true, '第一版分析', NULL, 112),
  ('firm', '喆律法律事務所', 'talent.competing_employer', NULL, NULL, '法顧律師職缺：對手幾乎是企業內部法務（5／13：建商、藥廠、加密貨幣、日商）', 'medium', true, '第一版分析', NULL, 113)
  ) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

-- ---------- 6. 規模級距數字市場帶（由 bands.ps1 產出的 CSV 轉入；n_candidates ≥3）----------
INSERT INTO interview_market_bands (note_id, dimension_key, level, size_band, position_kind, year, unit, n_entries, n_candidates, n_firms, median, p25, p75, cat_counts, verified_share)
SELECT n.id, b.dimension_key, b.level, b.size_band, b.position_kind, b.year::int, b.unit, b.n_entries::int, b.n_candidates::int, b.n_firms::int, b.median::numeric, b.p25::numeric, b.p75::numeric, b.cat_counts::jsonb, b.verified_share::int FROM
  (SELECT id FROM firm_field_notes WHERE channel = '面試筆記彙整' AND interviewed_on = DATE '2026-09-14' ORDER BY id DESC LIMIT 1) n,
  (VALUES
  ('comp.staff_pay_band', 'band×pos×year', '1-3', 'legal-staff-admin', 115, '千元/月', 4, 4, 4, 35.8, NULL, NULL, NULL, 100),
  ('comp.staff_pay_band', 'band×pos×year', '4-10', 'legal-staff-admin', 115, '千元/月', 3, 3, 3, 35, NULL, NULL, NULL, 67),
  ('comp.associate_pay_band', 'band×pos×year', '4-10', 'lawyer', 115, '千元/月', 5, 5, 5, 70, 60, 90, NULL, 100),
  ('comp.trainee_pay', 'band×pos×year', '1-3', 'trainee-lawyer', 115, '千元/月', 4, 4, 3, 60, NULL, NULL, NULL, 75),
  ('comp.trainee_pay', 'band×pos×year', '4-10', 'trainee-lawyer', 115, '千元/月', 3, 3, 3, 57, NULL, NULL, NULL, 67),
  ('comp.associate_pay_band', 'band×pos×year', '1-3', 'lawyer', 114, '千元/月', 4, 4, 4, 63.5, NULL, NULL, NULL, 50),
  ('comp.trainee_pay', 'band×pos×year', '1-3', 'trainee-lawyer', 114, '千元/月', 4, 4, 4, 62.5, NULL, NULL, NULL, 75),
  ('comp.associate_pay_band', 'band×pos×year', '4-10', 'lawyer', 114, '千元/月', 9, 9, 8, 60, 60, 65, NULL, 78),
  ('comp.trainee_pay', 'band×pos×year', '4-10', 'trainee-lawyer', 114, '千元/月', 5, 5, 4, 50, 30, 60, NULL, 80),
  ('comp.trainee_pay', 'band×pos×year', '11-30', 'trainee-lawyer', 114, '千元/月', 4, 4, 3, 59, NULL, NULL, NULL, 100),
  ('comp.associate_pay_band', 'band×pos×year', '11-30', 'lawyer', 114, '千元/月', 4, 4, 3, 60, NULL, NULL, NULL, 50),
  ('comp.staff_pay_band', 'band×pos×year', '4-10', 'legal-staff-admin', 113, '千元/月', 7, 6, 7, 35, 30, 42, NULL, 0),
  ('comp.staff_pay_band', 'band×pos×year', '1-3', 'legal-staff-admin', 113, '千元/月', 6, 6, 6, 32.5, 27.5, 35, NULL, 0),
  ('comp.staff_pay_band', 'band×pos', 'unknown', 'legal-staff-admin', NULL, '千元/月', 6, 6, 0, 32, 31, 32, NULL, 50),
  ('comp.staff_pay_band', 'band×pos', '1-3', 'legal-staff-admin', NULL, '千元/月', 12, 12, 12, 35.5, 28.59, 37, NULL, 42),
  ('comp.staff_pay_band', 'band×pos', '4-10', 'legal-staff-admin', NULL, '千元/月', 12, 11, 12, 35, 30, 44, NULL, 33),
  ('comp.staff_pay_band', 'band×pos', '31+', 'legal-staff-admin', NULL, '千元/月', 5, 4, 5, 35, NULL, NULL, NULL, 0),
  ('comp.trainee_pay', 'band×pos', '11-30', 'trainee-lawyer', NULL, '千元/月', 6, 6, 5, 58, 33, 58, NULL, 100),
  ('comp.associate_pay_band', 'band×pos', '4-10', 'lawyer', NULL, '千元/月', 14, 14, 13, 62.5, 60, 70, NULL, 86),
  ('comp.trainee_pay', 'band×pos', 'unknown', 'trainee-lawyer', NULL, '千元/月', 4, 3, 0, 32.5, NULL, NULL, NULL, 100),
  ('comp.associate_pay_band', 'band×pos', '11-30', 'lawyer', NULL, '千元/月', 6, 6, 5, 60, 60, 60, NULL, 67),
  ('comp.associate_pay_band', 'band×pos', '1-3', 'lawyer', NULL, '千元/月', 6, 6, 6, 63.5, 60, 65, NULL, 67),
  ('comp.trainee_pay', 'band×pos', '1-3', 'trainee-lawyer', NULL, '千元/月', 8, 8, 7, 60, 50, 75, NULL, 75),
  ('comp.trainee_pay', 'band×pos', '4-10', 'trainee-lawyer', NULL, '千元/月', 8, 8, 7, 53.5, 30, 60, NULL, 75),
  ('comp.associate_pay_band', 'band×pos', 'unknown', 'lawyer', NULL, '千元/月', 3, 3, 0, 70, NULL, NULL, NULL, 67),
  ('comp.staff_pay_band', 'pos×year', 'all', 'legal-staff-admin', 115, '千元/月', 10, 9, 8, 36.5, 33, 38, NULL, 80),
  ('comp.staff_pay_band', 'pos×year', 'all', 'part-time', 115, '千元/月', 3, 3, 2, 34, NULL, NULL, NULL, 67),
  ('comp.trainee_pay', 'pos×year', 'all', 'trainee-lawyer', 115, '千元/月', 13, 13, 10, 58, 35, 60, NULL, 77),
  ('comp.associate_pay_band', 'pos×year', 'all', 'lawyer', 115, '千元/月', 10, 10, 9, 70, 60, 71, NULL, 100),
  ('comp.associate_pay_band', 'pos×year', 'all', 'lawyer', 114, '千元/月', 20, 19, 16, 61, 60, 65, NULL, 60),
  ('comp.trainee_pay', 'pos×year', 'all', 'trainee-lawyer', 114, '千元/月', 15, 14, 11, 50, 33, 60, NULL, 87),
  ('comp.staff_pay_band', 'pos×year', 'all', 'legal-staff-admin', 114, '千元/月', 7, 7, 5, 37, 32, 38, NULL, 57),
  ('comp.staff_pay_band', 'pos×year', 'all', 'legal-staff-admin', 113, '千元/月', 19, 15, 17, 32, 30, 35, NULL, 0),
  ('comp.staff_pay_band', 'pos', 'all', 'legal-staff-admin', NULL, '千元/月', 36, 31, 30, 35, 31, 38, NULL, 33),
  ('comp.staff_pay_band', 'pos', 'all', 'part-time', NULL, '千元/月', 4, 4, 3, 32.5, NULL, NULL, NULL, 75),
  ('comp.trainee_pay', 'pos', 'all', 'trainee-lawyer', NULL, '千元/月', 28, 27, 21, 57.5, 35, 60, NULL, 82),
  ('comp.associate_pay_band', 'pos', 'all', 'lawyer', NULL, '千元/月', 30, 29, 25, 63.5, 60, 70, NULL, 73),
  ('talent.tenure', 'band×pos', 'unknown', 'legal-staff-admin', NULL, '月', 22, 19, 0, 9.5, 7, 16, NULL, 45),
  ('talent.tenure', 'band×pos', '1-3', 'legal-staff-admin', NULL, '月', 35, 30, 34, 10, 5, 20, NULL, 34),
  ('talent.tenure', 'band×pos', '11-30', 'part-time', NULL, '月', 5, 5, 4, 9, 2, 12, NULL, 40),
  ('talent.tenure', 'band×pos', '4-10', 'legal-staff-admin', NULL, '月', 24, 22, 22, 20.5, 7, 45, NULL, 38),
  ('talent.tenure', 'band×pos', '31+', 'legal-staff-admin', NULL, '月', 6, 5, 6, 12.5, 12, 13, NULL, 17),
  ('talent.tenure', 'band×pos', '11-30', 'legal-staff-admin', NULL, '月', 7, 6, 7, 13, 7, 15, NULL, 43),
  ('talent.tenure', 'band×pos', '4-10', 'part-time', NULL, '月', 8, 8, 7, 6, 2, 11, NULL, 25),
  ('talent.tenure', 'band×pos', '1-3', 'part-time', NULL, '月', 8, 8, 8, 4, 2, 4, NULL, 12),
  ('talent.tenure', 'band×pos', '11-30', 'trainee-lawyer', NULL, '月', 16, 16, 14, 7, 6, 16, NULL, 69),
  ('talent.tenure', 'band×pos', '4-10', 'lawyer', NULL, '月', 14, 14, 13, 12, 6, 31, NULL, 86),
  ('talent.tenure', 'band×pos', '4-10', 'trainee-lawyer', NULL, '月', 25, 25, 24, 6, 6, 15, NULL, 72),
  ('talent.tenure', 'band×pos', 'unknown', 'trainee-lawyer', NULL, '月', 8, 8, 0, 5.5, 3, 7, NULL, 75),
  ('talent.tenure', 'band×pos', '11-30', 'lawyer', NULL, '月', 8, 7, 7, 12.5, 7, 26, NULL, 62),
  ('talent.tenure', 'band×pos', 'unknown', 'lawyer', NULL, '月', 5, 5, 0, 3, 1, 4, NULL, 60),
  ('talent.tenure', 'band×pos', '1-3', 'lawyer', NULL, '月', 16, 15, 15, 13, 7, 15, NULL, 56),
  ('talent.tenure', 'band×pos', '1-3', 'trainee-lawyer', NULL, '月', 27, 27, 21, 7, 6, 12, NULL, 67),
  ('talent.tenure', 'band×pos', '31+', 'trainee-lawyer', NULL, '月', 7, 7, 6, 6, 5, 6, NULL, 14),
  ('talent.tenure', 'band×pos', 'unknown', 'part-time', NULL, '月', 6, 5, 0, 1.5, 1, 2, NULL, 67),
  ('talent.tenure', 'band×pos', '31+', 'part-time', NULL, '月', 3, 3, 3, 10, NULL, NULL, NULL, 33),
  ('talent.tenure', 'pos', 'all', 'legal-staff-admin', NULL, '月', 94, 65, 69, 12, 7, 22, NULL, 37),
  ('talent.tenure', 'pos', 'all', 'part-time', NULL, '月', 30, 28, 22, 4, 2, 10, NULL, 33),
  ('talent.tenure', 'pos', 'all', 'other', NULL, '月', 5, 4, 2, 5, NULL, NULL, NULL, 20),
  ('talent.tenure', 'pos', 'all', 'trainee-lawyer', NULL, '月', 83, 80, 65, 6, 6, 12, NULL, 65),
  ('talent.tenure', 'pos', 'all', 'lawyer', NULL, '月', 44, 38, 36, 12, 6, 18, NULL, 66),
  ('comp.bonus_months', 'band×pos', '1-3', 'legal-staff-admin', NULL, '月', 3, 3, 3, 1.5, NULL, NULL, NULL, 33),
  ('comp.bonus_months', 'band×pos', '4-10', 'legal-staff-admin', NULL, '月', 4, 4, 4, 1, NULL, NULL, NULL, 50),
  ('comp.bonus_months', 'band×pos', '11-30', 'trainee-lawyer', NULL, '月', 5, 5, 4, 2, 1.5, 2, NULL, 100),
  ('comp.bonus_months', 'band×pos', '11-30', 'lawyer', NULL, '月', 3, 3, 3, 2, NULL, NULL, NULL, 33),
  ('comp.bonus_months', 'band×pos', '1-3', 'lawyer', NULL, '月', 5, 5, 5, 1, 1, 1.5, NULL, 60),
  ('comp.bonus_months', 'band×pos', '4-10', 'lawyer', NULL, '月', 8, 8, 7, 1.5, 0, 2, NULL, 88),
  ('comp.bonus_months', 'pos', 'all', 'legal-staff-admin', NULL, '月', 10, 9, 9, 1.5, 1, 1.5, NULL, 40),
  ('comp.bonus_months', 'pos', 'all', 'trainee-lawyer', NULL, '月', 11, 11, 10, 2, 0, 2, NULL, 82),
  ('comp.bonus_months', 'pos', 'all', 'lawyer', NULL, '月', 16, 16, 15, 1.2, 1, 2, NULL, 69),
  ('comp.overtime_pay', 'pos', 'all', 'legal-staff-admin', NULL, '件', 10, 10, NULL, NULL, NULL, NULL, '{"有":6,"無":4,"補休":0}', NULL),
  ('comp.overtime_pay', 'pos', 'all', 'lawyer', NULL, '件', 13, 13, NULL, NULL, NULL, NULL, '{"有":2,"無":11,"補休":0}', NULL),
  ('comp.overtime_pay', 'pos', 'all', 'trainee-lawyer', NULL, '件', 15, 15, NULL, NULL, NULL, NULL, '{"有":4,"無":11,"補休":0}', NULL),
  ('comp.overtime_pay', 'band×pos', '4-10', 'legal-staff-admin', NULL, '件', 5, 5, NULL, NULL, NULL, NULL, '{"有":3,"無":2,"補休":0}', NULL),
  ('comp.overtime_pay', 'band×pos', '4-10', 'lawyer', NULL, '件', 7, 7, NULL, NULL, NULL, NULL, '{"有":1,"無":6,"補休":0}', NULL),
  ('comp.overtime_pay', 'band×pos', '1-3', 'lawyer', NULL, '件', 4, 4, NULL, NULL, NULL, NULL, '{"有":0,"無":4,"補休":0}', NULL),
  ('comp.overtime_pay', 'band×pos', '1-3', 'trainee-lawyer', NULL, '件', 4, 4, NULL, NULL, NULL, NULL, '{"有":2,"無":2,"補休":0}', NULL),
  ('comp.overtime_pay', 'band×pos', '4-10', 'trainee-lawyer', NULL, '件', 4, 4, NULL, NULL, NULL, NULL, '{"有":2,"無":2,"補休":0}', NULL),
  ('comp.overtime_pay', 'band×pos', '11-30', 'trainee-lawyer', NULL, '件', 5, 5, NULL, NULL, NULL, NULL, '{"有":0,"無":5,"補休":0}', NULL),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法務', 115, '千元/月', 18, 18, NULL, 40, 37, 43, NULL, 83),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '律師', 115, '千元/月', 23, 23, NULL, 65, 60, 75, NULL, 74),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '客戶關係', 115, '千元/月', 14, 14, NULL, 45, 44, 45, NULL, 0),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法顧律師', 115, '千元/月', 8, 8, NULL, 85, 75, 100, NULL, 100),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '律師', 114, '千元/月', 29, 29, NULL, 68, 60, 70, NULL, 59),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法務', 114, '千元/月', 28, 28, NULL, 35.5, 35, 40, NULL, 21),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法顧律師', 114, '千元/月', 9, 9, NULL, 60, 60, 65, NULL, 100),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '人資', 114, '千元/月', 7, 7, NULL, 42, 35, 50, NULL, 0),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法務', 113, '千元/月', 71, 59, NULL, 35, 33, 40, NULL, 14),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '法務', NULL, '千元/月', 117, 105, NULL, 36, 35, 40, NULL, 26),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '律師', NULL, '千元/月', 52, 52, NULL, 65, 60, 72, NULL, 65),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '客戶關係', NULL, '千元/月', 14, 14, NULL, 45, 44, 45, NULL, 0),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '法顧律師', NULL, '千元/月', 17, 17, NULL, 75, 60, 80, NULL, 100),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '人資', NULL, '千元/月', 7, 7, NULL, 42, 35, 50, NULL, 0)
  ) AS b(dimension_key, level, size_band, position_kind, year, unit, n_entries, n_candidates, n_firms, median, p25, p75, cat_counts, verified_share);

COMMIT;
