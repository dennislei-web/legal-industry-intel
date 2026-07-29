-- 114: 市場規模拆解（產業分析＞產值與市場＞市場規模拆解 tab）
-- 1) market_assumptions：可調行情假設（單價/委任率推估/量體），前端可編輯 low/high 並儲存
--    * 預設值存 def_low/def_high，前端「還原預設」用；來源註記存 note
--    * 委任率：民事/家事訴訟線用 market_line_stats() 實測值（mig 099 微資料），
--      此表的 rate 列僅作刑事線與量測缺口的 fallback（前端標「推估」）
-- 2) market_line_stats()：19 業務線最新完整年案件量（business_line_yearly，mig 095）
--    ＋ 民/家事實測委任率（closed_case_cause_rep_stats × biz_line()，mig 099/095）
--    * biz_line() 第三參數傳 cause_group 本身：特別法/其他民法的關鍵字細拆對種類字串
--      多半不命中而落入其他桶，屬已知近似（該兩桶委任率仍以整桶實測呈現）
-- 3) gov_tender_yearly_amount()：政府標案年決標金額（A 級，直接官方金額）

CREATE TABLE IF NOT EXISTS market_assumptions (
  key text PRIMARY KEY,
  segment text NOT NULL,          -- lit / ip / landagent / notary / labor / arb
  label text NOT NULL,
  kind text NOT NULL,             -- volume / price / rate / factor
  unit text,                      -- 件、萬元、%、億元…（顯示用）
  low numeric NOT NULL,
  high numeric NOT NULL,
  def_low numeric NOT NULL,
  def_high numeric NOT NULL,
  note text,
  sort int DEFAULT 0,
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE market_assumptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_ma" ON market_assumptions;
CREATE POLICY "auth_read_ma" ON market_assumptions FOR SELECT USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "auth_update_ma" ON market_assumptions;
CREATE POLICY "auth_update_ma" ON market_assumptions FOR UPDATE
  USING (auth.uid() IS NOT NULL) WITH CHECK (auth.uid() IS NOT NULL);
-- 登入者只能改 low/high/updated_at（def_* 與結構欄位鎖死）
REVOKE UPDATE ON market_assumptions FROM authenticated;
GRANT UPDATE (low, high, updated_at) ON market_assumptions TO authenticated;

-- ---- 種子資料（單位：price=萬元/件、rate=%、volume=件、factor=倍數）----
INSERT INTO market_assumptions (key, segment, label, kind, unit, low, high, def_low, def_high, note, sort) VALUES
-- 訴訟：一審委任費（萬元/件）
('lit_fee_車禍與侵權賠償','lit','車禍與侵權賠償','price','萬元',6,10,6,10,'一審委任行情',10),
('lit_fee_交通刑事','lit','交通刑事','price','萬元',5,8,5,8,'一審委任行情',11),
('lit_fee_借貸與金錢債務','lit','借貸與金錢債務','price','萬元',5,8,5,8,'一審委任行情',12),
('lit_fee_詐欺與洗錢','lit','詐欺與洗錢','price','萬元',8,15,8,15,'刑事辯護行情',13),
('lit_fee_竊盜侵占與財產犯罪','lit','竊盜侵占與財產犯罪','price','萬元',6,10,6,10,'刑事辯護行情',14),
('lit_fee_其他民事','lit','其他民事','price','萬元',6,10,6,10,'一審委任行情',15),
('lit_fee_暴力與人身犯罪','lit','暴力與人身犯罪','price','萬元',8,12,8,12,'刑事辯護行情',16),
('lit_fee_毒品','lit','毒品','price','萬元',8,15,8,15,'刑事辯護行情',17),
('lit_fee_不動產','lit','不動產','price','萬元',10,20,10,20,'一審委任行情',18),
('lit_fee_其他刑事','lit','其他刑事','price','萬元',6,10,6,10,'刑事辯護行情',19),
('lit_fee_白領與財經犯罪','lit','白領與財經犯罪','price','萬元',20,50,20,50,'刑事辯護行情（高複雜度）',20),
('lit_fee_契約與買賣','lit','契約與買賣','price','萬元',8,15,8,15,'一審委任行情',21),
('lit_fee_名譽個資與網路','lit','名譽個資與網路','price','萬元',6,10,6,10,'刑事辯護行情',22),
('lit_fee_性犯罪與跟騷','lit','性犯罪與跟騷','price','萬元',10,20,10,20,'刑事辯護行情',23),
('lit_fee_勞動僱傭','lit','勞動僱傭','price','萬元',8,12,8,12,'一審委任行情',24),
('lit_fee_繼承與遺產','lit','繼承與遺產','price','萬元',10,20,10,20,'一審委任行情',25),
('lit_fee_工程承攬','lit','工程承攬','price','萬元',15,40,15,40,'一審委任行情（高標的）',26),
('lit_fee_離婚與婚姻','lit','離婚與婚姻','price','萬元',8,15,8,15,'一審委任行情',27),
('lit_fee_智慧財產','lit','智慧財產','price','萬元',20,50,20,50,'智財訴訟行情',28),
('lit_fee_其他家事','lit','其他家事','price','萬元',8,12,8,12,'一審委任行情',29),
('lit_fee_親子與扶養','lit','親子與扶養','price','萬元',8,15,8,15,'一審委任行情',30),
('lit_fee_公司商事','lit','公司商事','price','萬元',20,60,20,60,'商事訴訟行情（高標的）',31),
-- 訴訟：委任率 fallback（%；民/家事線優先用實測值，刑事線一律用此表）
('lit_rate_車禍與侵權賠償','lit','車禍與侵權賠償','rate','%',25,40,25,40,'fallback（優先用實測）',40),
('lit_rate_交通刑事','lit','交通刑事','rate','%',10,20,10,20,'刑事無案由級實測，推估',41),
('lit_rate_借貸與金錢債務','lit','借貸與金錢債務','rate','%',20,35,20,35,'fallback（優先用實測）',42),
('lit_rate_詐欺與洗錢','lit','詐欺與洗錢','rate','%',30,50,30,50,'刑事無案由級實測，推估',43),
('lit_rate_竊盜侵占與財產犯罪','lit','竊盜侵占與財產犯罪','rate','%',15,25,15,25,'刑事無案由級實測，推估',44),
('lit_rate_其他民事','lit','其他民事','rate','%',25,35,25,35,'fallback（優先用實測）',45),
('lit_rate_暴力與人身犯罪','lit','暴力與人身犯罪','rate','%',20,35,20,35,'刑事無案由級實測，推估',46),
('lit_rate_毒品','lit','毒品','rate','%',15,25,15,25,'多法扶/指定辯護，推估',47),
('lit_rate_不動產','lit','不動產','rate','%',50,70,50,70,'fallback（優先用實測）',48),
('lit_rate_其他刑事','lit','其他刑事','rate','%',20,30,20,30,'刑事無案由級實測，推估',49),
('lit_rate_白領與財經犯罪','lit','白領與財經犯罪','rate','%',60,80,60,80,'刑事無案由級實測，推估',50),
('lit_rate_契約與買賣','lit','契約與買賣','rate','%',40,60,40,60,'fallback（優先用實測）',51),
('lit_rate_名譽個資與網路','lit','名譽個資與網路','rate','%',30,50,30,50,'刑事無案由級實測，推估',52),
('lit_rate_性犯罪與跟騷','lit','性犯罪與跟騷','rate','%',40,60,40,60,'刑事無案由級實測，推估',53),
('lit_rate_勞動僱傭','lit','勞動僱傭','rate','%',40,60,40,60,'fallback（優先用實測）',54),
('lit_rate_繼承與遺產','lit','繼承與遺產','rate','%',50,70,50,70,'fallback（優先用實測）',55),
('lit_rate_工程承攬','lit','工程承攬','rate','%',60,80,60,80,'fallback（優先用實測）',56),
('lit_rate_離婚與婚姻','lit','離婚與婚姻','rate','%',50,70,50,70,'fallback（優先用實測）',57),
('lit_rate_智慧財產','lit','智慧財產','rate','%',70,90,70,90,'fallback（優先用實測）',58),
('lit_rate_其他家事','lit','其他家事','rate','%',40,60,40,60,'fallback（優先用實測）',59),
('lit_rate_親子與扶養','lit','親子與扶養','rate','%',40,60,40,60,'fallback（優先用實測）',60),
('lit_rate_公司商事','lit','公司商事','rate','%',70,90,70,90,'fallback（優先用實測）',61),
-- 訴訟：上訴審係數
('lit_appeal_factor','lit','上訴審係數（一審市場 × 倍數）','factor','倍',1.15,1.25,1.15,1.25,'二三審委任另收費之增量',70),
-- 商標專利（量：TIPO 年度統計約值，年更手動調）
('ip_vol_tm','ip','商標申請量（案件計）','volume','案/年',94000,94000,94000,94000,'TIPO 114 年約值，年更',10),
('ip_vol_inv','ip','發明專利申請量','volume','件/年',50000,50000,50000,50000,'TIPO 114 年約值，年更',11),
('ip_vol_um','ip','新型專利申請量','volume','件/年',13500,13500,13500,13500,'TIPO 114 年約值，年更',12),
('ip_vol_ds','ip','設計專利申請量','volume','件/年',7500,7500,7500,7500,'TIPO 114 年約值，年更',13),
('ip_fee_tm','ip','商標每案服務費','price','萬元',2,2.5,2,2.5,'大所約 2 萬多/案，市場均價略低',20),
('ip_fee_inv','ip','發明每件生命週期','price','萬元',10,15,10,15,'撰稿/翻譯＋OA＋領證維護',21),
('ip_fee_um','ip','新型每件','price','萬元',5,8,5,8,'行情推估',22),
('ip_fee_ds','ip','設計每件','price','萬元',4,6,4,6,'行情推估',23),
-- 地政士（量：內政統計，年更手動調；價：行情推估）
('la_vol_sale','landagent','買賣移轉（棟）','volume','棟/年',300000,300000,300000,300000,'內政統計約值，年更',10),
('la_vol_inherit','landagent','繼承登記（棟）','volume','棟/年',75000,75000,75000,75000,'內政統計約值，年更',11),
('la_vol_gift','landagent','贈與（棟）','volume','棟/年',50000,50000,50000,50000,'內政統計約值，年更',12),
('la_vol_mortgage','landagent','抵押權設定（件）','volume','件/年',600000,600000,600000,600000,'土建合計約值，推估',13),
('la_fee_sale','landagent','買賣移轉每件','price','萬元',1.2,1.8,1.2,1.8,'行情推估',20),
('la_fee_inherit','landagent','繼承登記每件','price','萬元',2,4,2,4,'行情推估（含遺產清冊）',21),
('la_fee_gift','landagent','贈與每件','price','萬元',1.5,2.5,1.5,2.5,'行情推估',22),
('la_fee_mortgage','landagent','抵押權設定每件','price','萬元',0.3,0.5,0.3,0.5,'行情推估',23),
-- 公證（量：司法統計年報 114 年；價：法定費率之件均近似）
('no_vol_attest','notary','認證件數','volume','件/年',206000,206000,206000,206000,'114 年約值，年更',10),
('no_vol_notarize','notary','公證書件數','volume','件/年',203000,203000,203000,203000,'114 年約值，年更',11),
('no_fee_attest','notary','認證件均費用','price','萬元',0.075,0.15,0.075,0.15,'法定費率，件均近似',20),
('no_fee_notarize','notary','公證書件均費用','price','萬元',0.2,0.4,0.2,0.4,'法定費率按標的級距，件均近似',21),
-- 勞資爭議（量：勞動部年受理；價/率：行情推估）
('lb_vol_mediation','labor','調解受理件數','volume','件/年',29700,29700,29700,29700,'勞動部 114 年，年更',10),
('lb_vol_lawsuit','labor','進入訴訟件數','volume','件/年',2400,2400,2400,2400,'本站裁判書終結檔約值',11),
('lb_rate_mediation','labor','調解端代理率','rate','%',15,25,15,25,'推估',20),
('lb_rate_lawsuit','labor','訴訟端委任率','rate','%',60,80,60,80,'推估（優先用勞動僱傭線實測）',21),
('lb_fee_mediation','labor','調解代理每件','price','萬元',3,6,3,6,'行情推估',30),
('lb_fee_lawsuit','labor','訴訟委任每件','price','萬元',8,15,8,15,'行情推估',31),
-- 仲裁（量：114 年；標的額≠營收，機構費+代理費才是市場）
('ar_vol_cases','arb','年受理件數','volume','件/年',119,119,119,119,'2025 年，年更',10),
('ar_vol_amount','arb','標的總額（億元）','volume','億元',141.6,141.6,141.6,141.6,'2025 年，年更',11),
('ar_rate_inst','arb','機構仲裁費占標的','rate','%',0.7,1.1,0.7,1.1,'仲裁費率表累退之有效費率',20),
('ar_fee_counsel','arb','每造代理費','price','萬元',100,300,100,300,'行情推估（大案為主）',21)
ON CONFLICT (key) DO NOTHING;

-- ---- 19 業務線最新完整年量 ＋ 民/家事實測委任率 ----
CREATE OR REPLACE FUNCTION market_line_stats()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
WITH fy AS (
  SELECT max(y) AS y FROM (
    SELECT y FROM business_line_yearly GROUP BY y HAVING min(months) >= 12) t
), vol AS (
  SELECT b.line,
         COALESCE(sum(b.n) FILTER (WHERE b.file_type IN ('民事訴訟','家事訴訟')), 0)::bigint AS n_civ,
         COALESCE(sum(b.n) FILTER (WHERE b.file_type = '刑事訴訟'), 0)::bigint AS n_cri
  FROM business_line_yearly b, fy WHERE b.y = fy.y
  GROUP BY b.line
), repy AS (
  SELECT y FROM (
    SELECT left(yyyymm, 4) AS y, count(DISTINCT yyyymm) AS m
    FROM closed_case_cause_rep_stats GROUP BY 1) t
  WHERE m >= 12 ORDER BY y DESC LIMIT 1
), rep AS (
  SELECT biz_line(r.file_type, r.cause_group, r.cause_group) AS line,
         sum(r.n_total)::bigint AS rep_total,
         sum(r.n_total - r.n_none)::bigint AS rep_lawyer
  FROM closed_case_cause_rep_stats r, repy
  WHERE left(r.yyyymm, 4) = repy.y
    AND biz_line(r.file_type, r.cause_group, r.cause_group) IS NOT NULL
  GROUP BY 1
)
SELECT json_build_object(
  'year', (SELECT y FROM fy),
  'rep_year', (SELECT y FROM repy),
  'lines', COALESCE((SELECT json_agg(json_build_object(
      'line', v.line, 'n_civ', v.n_civ, 'n_cri', v.n_cri,
      'rep_total', r.rep_total, 'rep_lawyer', r.rep_lawyer)
      ORDER BY v.n_civ + v.n_cri DESC)
    FROM vol v LEFT JOIN rep r ON r.line = v.line), '[]'::json));
$$;
ALTER FUNCTION market_line_stats() SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION market_line_stats() TO anon, authenticated;

-- ---- 政府標案年決標金額（A 級口徑：官方決標金額直加）----
CREATE OR REPLACE FUNCTION gov_tender_yearly_amount()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.award_year), '[]'::json) FROM (
    SELECT award_year, count(*)::int AS n,
           sum(total_amount)::bigint AS amount,
           count(*) FILTER (WHERE total_amount IS NOT NULL)::int AS n_with_amount
    FROM gov_tenders
    WHERE award_year IS NOT NULL
    GROUP BY award_year) t;
$$;
ALTER FUNCTION gov_tender_yearly_amount() SET statement_timeout = '60s';
GRANT EXECUTE ON FUNCTION gov_tender_yearly_amount() TO anon, authenticated;
