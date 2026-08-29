-- 評鑑深層內容（mig 177）：Legal 500 firm×領域頁的客戶名單/代表案件/主辦律師
-- 產出：scripts/l500_highlights.py。用途：AI 分析非訟側——key_clients=常年客戶基本盤、
-- highlights=代表非訟案件（交易金額為標的金額非律師費，僅推單案量級，不得加總成年營收）
-- 口徑：submission 精選樣本（每領域約 3 件、挑大的寫），非全量

CREATE TABLE IF NOT EXISTS firm_award_highlights (
  id             bigserial PRIMARY KEY,
  source         text NOT NULL DEFAULT 'legal500',
  year           int  NOT NULL,
  practice_area  text NOT NULL,
  firm_name_en   text NOT NULL,
  firm_name      text,                       -- 歸戶後 MOJ 中文所名
  tier           text,
  key_clients    jsonb NOT NULL DEFAULT '[]'::jsonb,   -- ["Citibank Taiwan Limited", ...]
  highlights     jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{text, amounts:[{raw, musd}]}]
  practice_heads jsonb NOT NULL DEFAULT '[]'::jsonb,
  other_lawyers  jsonb NOT NULL DEFAULT '[]'::jsonb,
  url            text,
  scraped_at     timestamptz DEFAULT now(),
  UNIQUE(source, year, practice_area, firm_name_en)
);
CREATE INDEX IF NOT EXISTS idx_fah_firm ON firm_award_highlights (firm_name) WHERE firm_name IS NOT NULL;

ALTER TABLE firm_award_highlights ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_fah" ON firm_award_highlights;
CREATE POLICY "auth_read_fah" ON firm_award_highlights
  FOR SELECT USING (auth.uid() IS NOT NULL);
