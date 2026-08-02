-- 法官上訴維持率統計：裁判書全文反算（外部無公開來源；司法統計僅法院層級撤銷率）
-- 來源腳本：scripts/appeal_stats.py（月包全文重解析；join 需跨月原審索引）
-- 口徑：
--   side='trial'     受評視角——該法官的判決被上級審維持(upheld)/全部廢棄(rev_full)/
--                    部分廢棄(rev_part)；分母 appealed=其判決被上訴且上級審已判決、
--                    且原審可在索引窗內對回者（下限估計，索引窗外原審對不回）
--   side='appellate' 上級審視角——該法官審上訴案時駁回/廢棄的傾向
--   僅計「判決」；程序裁定（上訴不合法駁回、抗告）不計。other=發回/和解等非典型主文。
--   合議庭每位署名法官各計 1 件（與 judge_month_stats 同慣例）；同名以 (name, court) 區辨。

CREATE TABLE IF NOT EXISTS judge_appeal_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  court_name text NOT NULL,         -- trial=原審法院 / appellate=上級審法院
  side text NOT NULL,               -- trial / appellate
  cat text NOT NULL,                -- 民事/刑事/行政/家事/少年/其他（上級審裁判之案類）
  appealed int NOT NULL DEFAULT 0,
  upheld int NOT NULL DEFAULT 0,
  rev_full int NOT NULL DEFAULT 0,
  rev_part int NOT NULL DEFAULT 0,
  other int NOT NULL DEFAULT 0,
  UNIQUE (name, court_name, side, cat)
);

CREATE INDEX IF NOT EXISTS idx_jappeal_name ON judge_appeal_stats (name);

ALTER TABLE judge_appeal_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_jappeal" ON judge_appeal_stats;
CREATE POLICY "auth_read_jappeal" ON judge_appeal_stats
  FOR SELECT USING (auth.uid() IS NOT NULL);
