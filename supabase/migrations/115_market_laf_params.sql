-- 115: 訴訟市場法扶計價修正（mig 114 補充）
-- 委任率實測口徑「任一造有律師代理」含法扶，但法扶件的酬金遠低於市場行情——
-- 修正：每線市場 = 委任案量 × [(1−法扶佔比)×行情費 ＋ 法扶佔比×法扶酬金]，
-- 民事/刑事線佔比分開（刑事含指定辯護，佔比高），混合線前端按量加權。

INSERT INTO market_assumptions (key, segment, label, kind, unit, low, high, def_low, def_high, note, sort) VALUES
('lit_laf_share_civ','lit','民事/家事線法扶佔委任案比','rate','%',5,10,5,10,'法扶年報結構推估',71),
('lit_laf_share_cri','lit','刑事線法扶＋指定辯護佔委任案比','rate','%',25,40,25,40,'刑事強制辯護為法扶大宗，推估',72),
('lit_laf_fee','lit','法扶酬金每件','price','萬元',1.5,3,1.5,3,'法扶酬金計付辦法：每審級 15–50 基數×1,000 元（法定 1.5–5 萬），常見核定 2–3 萬',73)
ON CONFLICT (key) DO NOTHING;
