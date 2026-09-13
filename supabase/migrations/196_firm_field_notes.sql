-- ============================================================
-- 196: 合夥律師訪談田野筆記（firm_field_notes / firm_field_facts，admin 限定）
-- ============================================================
-- 背景：雷皓明 2026-09 起陸續與各所合夥律師面談（首例：眾博法律事務所合夥人，2026-09-12）。
-- 面談取得的薪酬結構、引案抽成、公關預算、標案人力門檻等「非公開資料線」，
-- 是裁判書/標案/名冊等公開訊號抓不到的產業細節；用結構化維度記錄，之後才能跨所比較。
--
-- 結構：
--   field_note_dimensions  觀察維度目錄（key 固定，前端 pivot 用；新增維度只要 INSERT）
--   firm_field_notes       一次訪談＝一列（來源角色、日期、摘要、原始口述）
--   firm_field_facts       訪談拆出的原子觀察（維度 × 對象事務所 × 數值/文字 × 信心 × DB 佐證）
--     subject_scope：firm＝關於受訪所本身／peer＝受訪者談別家／industry＝產業通則
-- 權限：仿 117 ip_watchlist，三表 SELECT 限 admin（面談內容屬商業敏感，鎖在 DB 端）。
-- 寫入：由 Claude 依 docs/field-notes/README.md 規格整理後以 SQL 寫入，不做前端表單。
-- 前端：事務所 modal「田野筆記」tab（admin 才顯示）＋ 喆律戰情＞合夥人訪談筆記（維度 pivot）。

BEGIN;

CREATE TABLE IF NOT EXISTS field_note_dimensions (
  key         text PRIMARY KEY,           -- 例：comp.origination_rate
  grp         text NOT NULL,              -- 群組：comp/org/mkt/gov/biz/client/talent/fin/strat
  grp_label   text NOT NULL,
  label       text NOT NULL,
  unit        text,                       -- %／倍／萬元／人／(空=文字)
  description text,
  sort        int  NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS firm_field_notes (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  firm           text NOT NULL,           -- 受訪者所屬事務所（對齊 moj_firm_statistics().firm_name）
  interviewed_on date NOT NULL,
  source_role    text NOT NULL,           -- 合夥人／所長／受僱律師／法務／其他
  source_desc    text,                    -- 補述（不具名亦可；勿放個資）
  channel        text NOT NULL DEFAULT '面談',
  interviewer    text NOT NULL DEFAULT '雷皓明',
  summary        text NOT NULL,           -- 三行以內重點
  raw_notes      text,                    -- 原始口述／訊息全文（保留原話，供日後重新拆解）
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_firm_field_notes_firm ON firm_field_notes(firm);

CREATE TABLE IF NOT EXISTS firm_field_facts (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  note_id       bigint NOT NULL REFERENCES firm_field_notes(id) ON DELETE CASCADE,
  subject_scope text NOT NULL DEFAULT 'firm' CHECK (subject_scope IN ('firm','peer','industry')),
  subject_firm  text,                     -- firm/peer 時必填；industry 為 null
  dimension_key text NOT NULL REFERENCES field_note_dimensions(key),
  value_num     numeric,                  -- 可量化者填（單位依維度）
  value_qual    text CHECK (value_qual IN ('=', '<', '<=', '>', '>=', '~')),  -- 數值修飾：<20% 記 value_num=20,'<'
  value_text    text NOT NULL,            -- 人話結論（一句）
  confidence    text NOT NULL DEFAULT 'medium' CHECK (confidence IN ('high','medium','low')),
  secondhand    boolean NOT NULL DEFAULT false,  -- 受訪者轉述他人／他所＝true
  db_crosscheck text,                     -- 本站資料佐證（表名＋數字），無則 null
  quote         text,                     -- 原話片段
  sort          int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_firm_field_facts_subject ON firm_field_facts(subject_firm);
CREATE INDEX IF NOT EXISTS idx_firm_field_facts_dim ON firm_field_facts(dimension_key);

ALTER TABLE field_note_dimensions ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_field_notes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_field_facts      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS field_note_dimensions_admin_read ON field_note_dimensions;
CREATE POLICY field_note_dimensions_admin_read ON field_note_dimensions
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));
DROP POLICY IF EXISTS firm_field_notes_admin_read ON firm_field_notes;
CREATE POLICY firm_field_notes_admin_read ON firm_field_notes
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));
DROP POLICY IF EXISTS firm_field_facts_admin_read ON firm_field_facts;
CREATE POLICY firm_field_facts_admin_read ON firm_field_facts
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'));

COMMENT ON TABLE firm_field_notes IS '合夥律師訪談田野筆記（admin 限定）；一次訪談一列，原子觀察在 firm_field_facts';
COMMENT ON TABLE firm_field_facts IS '訪談拆出的原子觀察：維度×對象所×數值/文字×信心×DB 佐證；subject_scope firm/peer/industry';

-- ---------- 維度目錄（新增維度直接 INSERT；key 不要改，前端 pivot 依 key）----------
INSERT INTO field_note_dimensions (key, grp, grp_label, label, unit, description, sort) VALUES
  ('comp.base_model',           'comp', '薪酬結構', '底薪／年終模式',        NULL,  '低底薪高年終／高底薪低獎金／純分潤等', 10),
  ('comp.bonus_ratio_to_base',  'comp', '薪酬結構', '年終≈全年本薪倍數',     '倍',  '年終總額相對全年本薪', 11),
  ('comp.bonus_components',     'comp', '薪酬結構', '年終組成',              NULL,  '引案／案件處理／其他考核項目與權重', 12),
  ('comp.origination_rate',     'comp', '薪酬結構', '律師引案抽成率',        '%',   '受僱律師自帶案件的抽成上限或區間', 13),
  ('comp.partner_expense',      'comp', '薪酬結構', '合夥人公關交際費',      NULL,  '合夥律師是否另有交際費額度及規模', 14),
  ('comp.associate_pay_band',   'comp', '薪酬結構', '受僱律師薪資帶',        '萬元', '月薪或年薪區間（註明口徑）', 15),
  ('org.model_lineage',         'org',  '組織治理', '運作模式師承',          NULL,  '創所者出身所／制度沿襲來源', 20),
  ('org.partner_track',         'org',  '組織治理', '合夥制度／升遷',        NULL,  '合夥人產生方式、分潤制、股權', 21),
  ('org.headcount',             'org',  '組織治理', '人力規模（自述）',      '人',  '律師／法務／行政人數（受訪者口徑）', 22),
  ('org.decision_style',        'org',  '組織治理', '決策與管理風格',        NULL,  NULL, 23),
  ('mkt.event_spend',           'mkt',  '行銷公關', '單場活動花費',          '萬元', '餐會／音樂會／冠名等單一活動支出', 30),
  ('mkt.annual_budget',         'mkt',  '行銷公關', '年度行銷公關預算',      '萬元', NULL, 31),
  ('mkt.channel_mix',           'mkt',  '行銷公關', '獲客管道結構',          NULL,  '轉介／機構／數位／活動的比重', 32),
  ('mkt.effect_view',           'mkt',  '行銷公關', '成效自評',              NULL,  '受訪者對行銷支出成效的看法', 33),
  ('gov.tender_annual_amount',  'gov',  '機構標案', '標案年收',              '萬元', '單一標案或標案線年收', 40),
  ('gov.tender_staffing',       'gov',  '機構標案', '標案人力要求',          NULL,  '駐點人數／年資／法務配置', 41),
  ('gov.entry_barrier',         'gov',  '機構標案', '標案護城河',            NULL,  '人力門檻、利益衝突、機關黏著等進入障礙', 42),
  ('gov.spillover',             'gov',  '機構標案', '標案衍生業務',          NULL,  '由機構案帶出的仲裁／企業案／轉介', 43),
  ('biz.niche',                 'biz',  '業務線',   '利基領域',              NULL,  NULL, 50),
  ('biz.intl_arbitration',      'biz',  '業務線',   '國際仲裁',              NULL,  '案源、收益感受', 51),
  ('biz.revenue_line',          'biz',  '業務線',   '營收線觀察',            NULL,  '各業務線貢獻與獲利感受', 52),
  ('client.mix',                'client','客戶',     '客戶結構',              NULL,  NULL, 60),
  ('client.pricing',            'client','客戶',     '收費行情',              NULL,  '時薪／案件費／顧問費口徑', 61),
  ('talent.turnover',           'talent','人才',     '流動與留才',            NULL,  NULL, 70),
  ('talent.hiring_source',      'talent','人才',     '招募來源',              NULL,  NULL, 71),
  ('fin.revenue',               'fin',  '財務',     '營收（自述）',          '萬元', NULL, 80),
  ('fin.margin',                'fin',  '財務',     '利潤率（自述）',        '%',   NULL, 81),
  ('strat.zhelu_implication',   'strat','戰略',     '對喆律的啟示',          NULL,  '雷皓明面談後的判讀（非受訪者說法）', 90),
  ('strat.market_view',         'strat','戰略',     '受訪者市場觀',          NULL,  '受訪者對產業趨勢的看法', 91)
ON CONFLICT (key) DO UPDATE SET grp=EXCLUDED.grp, grp_label=EXCLUDED.grp_label, label=EXCLUDED.label,
  unit=EXCLUDED.unit, description=EXCLUDED.description, sort=EXCLUDED.sort;

-- ---------- 首筆：眾博法律事務所合夥人（2026-09-12 面談）----------
WITH n AS (
  INSERT INTO firm_field_notes (firm, interviewed_on, source_role, source_desc, channel, summary, raw_notes)
  VALUES (
    '眾博法律事務所', DATE '2026-09-12', '合夥人', '眾博合夥律師（未具名）', '面談',
    '所長許兆慶出身國際通商，制度沿襲大所：低底薪高年終（年終≈全年本薪，分引案＋案件處理），引案抽成 <20%，合夥人另有交際費。' ||
    '公關活動大手筆（10 週年餐會 300 萬、慈善音樂會 200 萬、冠名國家音樂廳演奏會），成效不明。' ||
    '能源署標案年收 1,350 萬，要求 3 律師＋2 法務全日駐點——小所沒人力、大所有能源企業利衝，眾博卡到獨特位置，並衍生收益不錯的能源國際仲裁。',
    '眾博所長許兆慶是國際通商出來的 所以運作模式類似國際通商 台灣大所的運作模式均類似 薪資是採低底薪高年終 年終分數個部分 主要是引案 跟案件處理 ' ||
    '律師引案抽成均在20%以下 年終可能跟一整年的本薪差不多 合夥律師會額外有公關交際費用 眾博去年辦了一場10周年餐會花了300萬 辦了場慈善音樂會花了200萬 ' ||
    '辦了場冠名國家音樂廳的演奏會可能也花費不少 不確定成效。另外眾博近年重點的能源案 標到了能源局的標案 年收1350萬 這個標案有一個特別的地方 ' ||
    '要求要駐守能源局律師3位(4年以上年資2位 1年以上年資1位) 法務2位 這些人一整天都要在能源局 所以小所很難有這個人力 然後大所可能有皆能源企業案件有利衝 ' ||
    '他們佔到了一個很好的位置。事務所也因為這樣接了一些能源國際仲裁 收益很不錯'
  ) RETURNING id
)
INSERT INTO firm_field_facts (note_id, subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort)
SELECT n.id, f.* FROM n, (VALUES
  ('firm', '眾博法律事務所', 'org.model_lineage', NULL::numeric, NULL::text,
     '所長許兆慶出身國際通商法律事務所，事務所運作模式沿襲國際通商', 'high', false,
     'firm_profiles.ai_analysis：許兆慶前嘉義地院法官（2000-2009）後轉跨國所合夥；moj_lawyer_changes 2026-08 唐琪縉自眾博轉國際通商（雙向人才通道）',
     '所長許兆慶是國際通商出來的 所以運作模式類似國際通商', 1),
  ('industry', NULL, 'comp.base_model', NULL, NULL,
     '台灣大所運作模式均類似：薪資採低底薪、高年終', 'medium', true, NULL,
     '台灣大所的運作模式均類似 薪資是採低底薪高年終', 2),
  ('firm', '眾博法律事務所', 'comp.base_model', NULL, NULL,
     '低底薪高年終', 'high', false, NULL, NULL, 3),
  ('firm', '眾博法律事務所', 'comp.bonus_components', NULL, NULL,
     '年終分數個部分，主要兩塊：引案、案件處理', 'high', false, NULL,
     '年終分數個部分 主要是引案 跟案件處理', 4),
  ('firm', '眾博法律事務所', 'comp.origination_rate', 20, '<',
     '律師引案抽成均在 20% 以下', 'high', false, NULL, '律師引案抽成均在20%以下', 5),
  ('firm', '眾博法律事務所', 'comp.bonus_ratio_to_base', 1, '~',
     '年終總額約等於一整年本薪（＝年薪約 24 個月本薪）', 'medium', false, NULL,
     '年終可能跟一整年的本薪差不多', 6),
  ('firm', '眾博法律事務所', 'comp.partner_expense', NULL, NULL,
     '合夥律師額外有公關交際費用額度', 'high', false, NULL, '合夥律師會額外有公關交際費用', 7),
  ('firm', '眾博法律事務所', 'mkt.event_spend', 300, '=',
     '2025 年 10 週年餐會花費 300 萬', 'high', false,
     'firm_profiles.founded_year=2015 → 2025 滿 10 年，口徑吻合', '去年辦了一場10周年餐會花了300萬', 8),
  ('firm', '眾博法律事務所', 'mkt.event_spend', 200, '=',
     '慈善音樂會花費 200 萬', 'high', false, NULL, '辦了場慈善音樂會花了200萬', 9),
  ('firm', '眾博法律事務所', 'mkt.event_spend', NULL, NULL,
     '冠名國家音樂廳演奏會，金額未透露、推測不低', 'low', false, NULL,
     '辦了場冠名國家音樂廳的演奏會可能也花費不少', 10),
  ('firm', '眾博法律事務所', 'mkt.effect_view', NULL, NULL,
     '受訪者對上述公關活動（合計已知 ≥500 萬）成效表示不確定', 'medium', false,
     'firm_digital_signals：無 FB Pixel／Google Ads 碼，非數位廣告驅動，行銷支出走實體活動與關係', '不確定成效', 11),
  ('firm', '眾博法律事務所', 'gov.tender_annual_amount', 1350, '=',
     '能源局（署）標案年收 1,350 萬', 'high', false,
     'gov_tenders：經濟部能源署「強化我國能源法律事務推動計畫」114 年度 1,350 萬、115 年度 1,330 萬；2021–2025 連 5 年得標累計 6,241 萬', '年收1350萬', 12),
  ('firm', '眾博法律事務所', 'gov.tender_staffing', NULL, NULL,
     '標案要求全日駐點能源局：律師 3 位（4 年以上年資 2 位、1 年以上 1 位）＋法務 2 位', 'high', false, NULL,
     '要求要駐守能源局律師3位(4年以上年資2位 1年以上年資1位) 法務2位 這些人一整天都要在能源局', 13),
  ('firm', '眾博法律事務所', 'gov.entry_barrier', NULL, NULL,
     '護城河＝人力門檻×利衝：小所抽不出 5 人全日駐點；大所多有能源企業客戶而有利益衝突。眾博（15 人、無能源企業客戶）卡到獨特位置', 'medium', false,
     'firm_analysis_facts.lawyer_count=15；標案 5 戰 5 勝＝投標即得標，與「無競爭者」判讀一致', '小所很難有這個人力 然後大所可能有皆能源企業案件有利衝 他們佔到了一個很好的位置', 14),
  ('firm', '眾博法律事務所', 'gov.spillover', NULL, NULL,
     '因能源標案的機關關係，衍生承接能源國際仲裁案', 'high', false, NULL, '事務所也因為這樣接了一些能源國際仲裁', 15),
  ('firm', '眾博法律事務所', 'biz.intl_arbitration', NULL, NULL,
     '能源國際仲裁收益「很不錯」（金額未透露）', 'medium', false, NULL, '收益很不錯', 16),
  ('firm', '眾博法律事務所', 'strat.zhelu_implication', NULL, NULL,
     '機構標案的真門檻是「駐點人力＋無利衝」而非價格；喆律 68 位律師、B2C 客群無企業利衝，具備競標駐點型標案的結構條件，值得盤點各部會同型標案（雷面談後判讀）', 'medium', false,
     'gov_tenders 表可篩「駐點／進駐／派駐」關鍵字盤點同型標案', NULL, 17)
) AS f(subject_scope, subject_firm, dimension_key, value_num, value_qual, value_text, confidence, secondhand, db_crosscheck, quote, sort);

COMMIT;
