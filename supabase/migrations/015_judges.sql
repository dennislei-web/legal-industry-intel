-- ============================================================
-- 015: judges - 法官資料表（兩個來源）
-- ============================================================

-- ========== 司法院法官名冊 (ground truth) ==========
CREATE TABLE IF NOT EXISTS jy_judges (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  court_name TEXT,
  court_id UUID REFERENCES courts(id) ON DELETE SET NULL,
  division TEXT,
  rank TEXT,
  appointment_date DATE,
  seniority_years INTEGER,
  status TEXT DEFAULT '現任',
  sex TEXT,
  raw_data JSONB,
  scraped_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(name, court_name)
);

CREATE INDEX IF NOT EXISTS idx_jy_judges_name ON jy_judges(name);
CREATE INDEX IF NOT EXISTS idx_jy_judges_court ON jy_judges(court_name);
CREATE INDEX IF NOT EXISTS idx_jy_judges_court_id ON jy_judges(court_id);
CREATE INDEX IF NOT EXISTS idx_jy_judges_division ON jy_judges(division);
CREATE INDEX IF NOT EXISTS idx_jy_judges_rank ON jy_judges(rank);

ALTER TABLE jy_judges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_jy_judges" ON jy_judges FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE TRIGGER jy_judges_updated_at
  BEFORE UPDATE ON jy_judges FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ========== Lawsnote 法官案件統計 ==========
CREATE TABLE IF NOT EXISTS lawsnote_judges (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  lawsnote_id TEXT UNIQUE,
  name TEXT NOT NULL,
  court_name TEXT,
  case_count_total INTEGER,
  case_count_by_year JSONB,
  case_type_distribution JSONB,
  avg_processing_days NUMERIC(7,2),
  verdict_stats JSONB,
  source_url TEXT,
  raw_data JSONB,
  scraped_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(name, court_name)
);

CREATE INDEX IF NOT EXISTS idx_ln_judges_name ON lawsnote_judges(name);
CREATE INDEX IF NOT EXISTS idx_ln_judges_court ON lawsnote_judges(court_name);
CREATE INDEX IF NOT EXISTS idx_ln_judges_lawsnote_id ON lawsnote_judges(lawsnote_id);
CREATE INDEX IF NOT EXISTS idx_ln_judges_case_count ON lawsnote_judges(case_count_total DESC);

ALTER TABLE lawsnote_judges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_ln_judges" ON lawsnote_judges FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE TRIGGER lawsnote_judges_updated_at
  BEFORE UPDATE ON lawsnote_judges FOR EACH ROW EXECUTE FUNCTION update_updated_at();
