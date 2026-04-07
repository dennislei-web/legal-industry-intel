-- ============================================================
-- 事務所研究檔案（per-firm research profiles）
-- ============================================================

CREATE TABLE IF NOT EXISTS firm_profiles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  firm_name TEXT UNIQUE NOT NULL,
  website_url TEXT,
  description TEXT,
  practice_focus TEXT[],
  notable_clients TEXT,
  founded_year INTEGER,
  news_links JSONB DEFAULT '[]'::jsonb,
  user_notes TEXT,
  ai_analysis TEXT,
  ai_analyzed_at TIMESTAMPTZ,
  raw_data JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_firm_profiles_name ON firm_profiles(firm_name);

ALTER TABLE firm_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_firm_profiles" ON firm_profiles FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_write_firm_profiles" ON firm_profiles FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY "auth_update_firm_profiles" ON firm_profiles FOR UPDATE USING (auth.uid() IS NOT NULL);

CREATE TRIGGER firm_profiles_updated_at BEFORE UPDATE ON firm_profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
