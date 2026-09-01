-- 187: 市場規模拆解——訴訟全口徑參數（付費造數係數＋署名件法三角驗證）
-- 背景：委任率微資料為「任一造有律師」口徑（雙方委任只算一份費用）；
--       2026-09-01 長尾對賬發現全市場 2025 署名 315,999 件、72% 在頭部 398 家以外，
--       署名件法獨立推估與委任率法全口徑收斂於 ~150-270 億。
delete from market_assumptions where key in ('lit_paying_factor','lit_sign_volume','lit_sign_fee');
insert into market_assumptions (key, segment, label, kind, unit, low, high, def_low, def_high, note, sort) values
  ('lit_paying_factor','lit','付費造數係數（任一造合計 × 倍數）','factor','倍',1.25,1.5,1.25,1.5,'委任率微資料為「任一造有律師」口徑，兩造分別委任時市場收入為兩份；民事雙委率較高、刑辯近乎單造（被告側），依民刑量加權推估',74),
  ('lit_sign_volume','lit','全市場判決署名量（年）','volume','萬件',31.6,31.6,31.6,31.6,'lawyer_month_stats 2025 全市場律師署名 315,999 件（含各審級、兩造、裁定；2021 年 211,118 件、4 年 +50%；年更手動）',75),
  ('lit_sign_fee','lit','署名件有效單價','price','萬元',4.5,8.5,4.5,8.5,'行情 6-10 萬折法扶佔比（酬金計價 2-3 萬、刑事佔比高）、裁定衍生程序與少量共列後之有效值',76);
