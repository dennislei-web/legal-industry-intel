-- 260: firm_analysis_facts v3 雙軸欄位（2026-11-03 雷皓明拍板，docs/firm-analysis-spec v3）
-- type 欄語意改為「主案源」（八類：線上行銷/制度派案/政府批量/民間批量/企業關係/前司法官招牌/同業協作/在地口碑）；
-- 新增次案源、業務屬性、規模帶。舊 v2 型態由 facts_extract.py 對照換成主案源，過渡期前端不漏所。
ALTER TABLE firm_analysis_facts ADD COLUMN IF NOT EXISTS acq2 text;          -- 次案源，「、」分隔
ALTER TABLE firm_analysis_facts ADD COLUMN IF NOT EXISTS practice_tag text;  -- 企業非訟/精品專業/綜合訴訟
ALTER TABLE firm_analysis_facts ADD COLUMN IF NOT EXISTS size_band text;     -- 一人/2–5 人/6–20 人/21 人以上
