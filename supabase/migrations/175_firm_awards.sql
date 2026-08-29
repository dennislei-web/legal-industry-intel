-- 國際法律評鑑機構資料線 pilot（mig 175）：Chambers Greater China Region「Taiwan Jurisdiction」
-- 產出：scripts/chambers_awards.py（歸戶對照 scripts/chambers_firm_map.py）
-- 每列 = source × year × practice_area × firm；ranked_lawyers jsonb 存該所該領域上榜律師
--   [{name_en, band, rank_order, is_dept_head, ranked_years}]（英文原名；中文歸戶待官網中英對照）
-- band：'Band 1'..'Band 6' | 'Lawyers only'（所未進 band 但有律師個人上榜）
-- 口徑註記：質性聲譽排名（submission＋客戶訪談），一年一更、無金額、
--   有 submission 偏差（缺席≠不強）、台灣覆蓋僅涉外大所 ~40 家；
--   firm_name 為 MOJ 名冊歸戶後中文所名（NULL=歸不了戶，如外資所/專利師所）

CREATE TABLE IF NOT EXISTS firm_awards (
  id                 bigserial PRIMARY KEY,
  source             text NOT NULL,              -- 'chambers'（未來：legal500/iflr1000/asialaw）
  publication        text,                       -- 'Greater China Region'
  year               int  NOT NULL,              -- 評鑑年度（如 2026）
  practice_area      text NOT NULL,              -- 'Corporate/M&A' 等
  practice_area_id   int,                        -- 來源站內部 id
  firm_name_en       text NOT NULL,
  firm_name          text,                       -- 歸戶後 MOJ 中文所名（NULL=未歸戶）
  band               text NOT NULL,
  band_rank          int,                        -- 排序用（Band N=N；Lawyers only=98）
  ranked_years_count int,                        -- 連續上榜年數（來源提供）
  ranked_lawyers     jsonb NOT NULL DEFAULT '[]'::jsonb,
  org_id             int,                        -- 來源站 organisationId
  url                text,
  scraped_at         timestamptz DEFAULT now(),
  UNIQUE(source, year, practice_area, firm_name_en)
);
CREATE INDEX IF NOT EXISTS idx_fa_firm ON firm_awards (firm_name) WHERE firm_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fa_src_year ON firm_awards (source, year);

ALTER TABLE firm_awards ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_fa" ON firm_awards;
CREATE POLICY "auth_read_fa" ON firm_awards
  FOR SELECT USING (auth.uid() IS NOT NULL);
