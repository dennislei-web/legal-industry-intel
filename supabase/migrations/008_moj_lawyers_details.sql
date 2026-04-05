-- ============================================================
-- moj_lawyers 擴充詳細欄位 (從 /api/cert/lyinfosd/{lic_no} 抓)
-- ============================================================
-- 原本只有 search API 的 6 欄 (name, lic_no, sex, office, guild_names, court)
-- 現在加 detail API 的額外欄位：
--   出生年份、執業狀態、email、電話、地址、懲戒記錄、執業起始日、照片 hash
-- ============================================================

ALTER TABLE moj_lawyers
  ADD COLUMN IF NOT EXISTS birth_year INTEGER,           -- 民國年 (e.g. 49 → 1960)
  ADD COLUMN IF NOT EXISTS state TEXT,                   -- "0" / "1" / ...
  ADD COLUMN IF NOT EXISTS state_desc TEXT,              -- "正常" / "停業" / ...
  ADD COLUMN IF NOT EXISTS english_name TEXT,
  ADD COLUMN IF NOT EXISTS old_name TEXT,
  ADD COLUMN IF NOT EXISTS foreigner TEXT,
  ADD COLUMN IF NOT EXISTS qualification_govt TEXT,
  ADD COLUMN IF NOT EXISTS email TEXT,
  ADD COLUMN IF NOT EXISTS tel TEXT,
  ADD COLUMN IF NOT EXISTS address TEXT,
  ADD COLUMN IF NOT EXISTS discipline TEXT,              -- 懲戒記錄（null = 無）
  ADD COLUMN IF NOT EXISTS professional_license TEXT,    -- prolic 專業領域進修
  ADD COLUMN IF NOT EXISTS practice_start_date TEXT,     -- 民國格式 '081/03/05'
  ADD COLUMN IF NOT EXISTS practice_end_date TEXT,
  ADD COLUMN IF NOT EXISTS remark TEXT,
  ADD COLUMN IF NOT EXISTS moj_mk_date DATE,             -- MOJ 發布日期 (西元)
  ADD COLUMN IF NOT EXISTS moj_ut_date DATE,             -- MOJ 更新日期 (西元)
  ADD COLUMN IF NOT EXISTS detail_fetched_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_moj_lawyers_birth_year ON moj_lawyers(birth_year) WHERE birth_year IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_moj_lawyers_discipline ON moj_lawyers(discipline) WHERE discipline IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_moj_lawyers_detail_fetched ON moj_lawyers(detail_fetched_at) WHERE detail_fetched_at IS NOT NULL;
