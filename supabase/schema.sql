-- ============================================================
-- 台灣法律產業情報儀表板 - 資料庫 Schema
-- ============================================================

-- ============================================================
-- 1. 核心資料表
-- ============================================================

-- 事務所 (先建，因為 lawyers 會 reference 它)
CREATE TABLE law_firms (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  registration_number TEXT UNIQUE,
  tax_id TEXT,
  address TEXT,
  city TEXT,
  district TEXT,
  phone TEXT,
  founding_date DATE,
  closure_date DATE,
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'closed', 'suspended')),
  organization_type TEXT,
  lawyer_count INTEGER,
  revenue_estimate NUMERIC,
  practice_areas TEXT[],
  website TEXT,
  source TEXT DEFAULT 'moea',
  source_url TEXT,
  raw_data JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_firms_name ON law_firms(name);
CREATE INDEX idx_firms_city ON law_firms(city);
CREATE INDEX idx_firms_status ON law_firms(status);
CREATE INDEX idx_firms_tax ON law_firms(tax_id);

-- 律師
CREATE TABLE lawyers (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  license_number TEXT UNIQUE,
  license_date DATE,
  bar_association TEXT,
  practice_areas TEXT[],
  affiliated_firm_id UUID REFERENCES law_firms(id) ON DELETE SET NULL,
  affiliated_firm_name TEXT,
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended', 'retired')),
  gender TEXT,
  region TEXT,
  education TEXT,
  source TEXT DEFAULT 'moj',
  source_url TEXT,
  raw_data JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_lawyers_license ON lawyers(license_number);
CREATE INDEX idx_lawyers_firm ON lawyers(affiliated_firm_id);
CREATE INDEX idx_lawyers_status ON lawyers(status);
CREATE INDEX idx_lawyers_region ON lawyers(region);
CREATE INDEX idx_lawyers_bar ON lawyers(bar_association);
CREATE INDEX idx_lawyers_name ON lawyers(name);

-- 產業統計 (時間序列)
CREATE TABLE industry_stats (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  year INTEGER NOT NULL,
  month INTEGER,
  stat_type TEXT NOT NULL,
  value NUMERIC NOT NULL,
  unit TEXT,
  region TEXT,
  source TEXT,
  source_url TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(year, month, stat_type, region)
);

CREATE INDEX idx_stats_year ON industry_stats(year);
CREATE INDEX idx_stats_type ON industry_stats(stat_type);

-- 新聞
CREATE TABLE news_articles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  url TEXT UNIQUE NOT NULL,
  source_name TEXT,
  published_at TIMESTAMPTZ,
  scraped_at TIMESTAMPTZ DEFAULT now(),
  summary TEXT,
  content_snippet TEXT,
  tags TEXT[],
  sentiment TEXT CHECK (sentiment IN ('positive', 'negative', 'neutral')),
  relevance_score NUMERIC(3,2),
  is_read BOOLEAN DEFAULT false,
  is_starred BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_news_published ON news_articles(published_at DESC);
CREATE INDEX idx_news_source ON news_articles(source_name);
CREATE INDEX idx_news_starred ON news_articles(is_starred) WHERE is_starred = true;

-- AI 洞察
CREATE TABLE ai_insights (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  insight_type TEXT NOT NULL CHECK (insight_type IN ('weekly_summary', 'trend_analysis', 'firm_profile', 'market_forecast')),
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  data_range_start DATE,
  data_range_end DATE,
  related_entity_type TEXT,
  related_entity_id UUID,
  model_used TEXT DEFAULT 'claude-sonnet-4-20250514',
  is_pinned BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_insights_type ON ai_insights(insight_type);
CREATE INDEX idx_insights_created ON ai_insights(created_at DESC);

-- 使用者筆記
CREATE TABLE manual_notes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id),
  title TEXT NOT NULL,
  content TEXT,
  category TEXT CHECK (category IN ('firm_research', 'market_observation', 'competitor', 'general')),
  related_entity_type TEXT,
  related_entity_id UUID,
  tags TEXT[],
  is_pinned BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_notes_user ON manual_notes(user_id);
CREATE INDEX idx_notes_category ON manual_notes(category);

-- 爬蟲紀錄
CREATE TABLE scrape_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  scraper_name TEXT NOT NULL,
  started_at TIMESTAMPTZ DEFAULT now(),
  finished_at TIMESTAMPTZ,
  status TEXT DEFAULT 'running' CHECK (status IN ('running', 'success', 'error', 'partial')),
  records_found INTEGER DEFAULT 0,
  records_inserted INTEGER DEFAULT 0,
  records_updated INTEGER DEFAULT 0,
  error_message TEXT,
  details JSONB
);

CREATE INDEX idx_scrape_logs_name ON scrape_logs(scraper_name);
CREATE INDEX idx_scrape_logs_started ON scrape_logs(started_at DESC);

-- 資料來源註冊
CREATE TABLE data_sources (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  url TEXT,
  description TEXT,
  data_type TEXT,
  scraper_name TEXT,
  update_frequency TEXT,
  last_scraped_at TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 2. Views
-- ============================================================

CREATE OR REPLACE VIEW lawyer_region_distribution AS
SELECT
  COALESCE(region, '未知') as region,
  COUNT(*) as count,
  ROUND(COUNT(*)::NUMERIC / NULLIF((SELECT COUNT(*) FROM lawyers WHERE status = 'active'), 0) * 100, 1) as percentage
FROM lawyers
WHERE status = 'active'
GROUP BY region
ORDER BY count DESC;

CREATE OR REPLACE VIEW firm_size_distribution AS
SELECT
  CASE
    WHEN lawyer_count IS NULL THEN '未知'
    WHEN lawyer_count = 1 THEN '獨資 (1人)'
    WHEN lawyer_count <= 5 THEN '小型 (2-5人)'
    WHEN lawyer_count <= 20 THEN '中型 (6-20人)'
    WHEN lawyer_count <= 50 THEN '大型 (21-50人)'
    ELSE '超大型 (50人以上)'
  END as size_category,
  COUNT(*) as firm_count
FROM law_firms
WHERE status = 'active'
GROUP BY size_category;

CREATE OR REPLACE VIEW yearly_new_lawyers AS
SELECT
  EXTRACT(YEAR FROM license_date)::INTEGER as year,
  COUNT(*) as new_lawyers
FROM lawyers
WHERE license_date IS NOT NULL
GROUP BY year
ORDER BY year;

-- ============================================================
-- 3. Triggers
-- ============================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER lawyers_updated_at BEFORE UPDATE ON lawyers FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER law_firms_updated_at BEFORE UPDATE ON law_firms FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER manual_notes_updated_at BEFORE UPDATE ON manual_notes FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 4. RLS
-- ============================================================

ALTER TABLE lawyers ENABLE ROW LEVEL SECURITY;
ALTER TABLE law_firms ENABLE ROW LEVEL SECURITY;
ALTER TABLE industry_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE news_articles ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_insights ENABLE ROW LEVEL SECURITY;
ALTER TABLE manual_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE scrape_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE data_sources ENABLE ROW LEVEL SECURITY;

-- 登入即可讀取所有公開資料
CREATE POLICY "auth_read" ON lawyers FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read" ON law_firms FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read" ON industry_stats FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read" ON news_articles FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read" ON ai_insights FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read" ON scrape_logs FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read" ON data_sources FOR SELECT USING (auth.uid() IS NOT NULL);

-- 新聞可更新已讀/標星
CREATE POLICY "auth_update_news" ON news_articles FOR UPDATE USING (auth.uid() IS NOT NULL);

-- 筆記只能操作自己的
CREATE POLICY "notes_select" ON manual_notes FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "notes_insert" ON manual_notes FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "notes_update" ON manual_notes FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "notes_delete" ON manual_notes FOR DELETE USING (user_id = auth.uid());

-- ============================================================
-- 4b. Lawsnote 律師專長資料
-- ============================================================

CREATE TABLE lawsnote_lawyers (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  lawsnote_id TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  case_count_5yr INTEGER,
  expertise_areas TEXT[],
  regions TEXT[],
  cert_number TEXT,
  service_regions TEXT[],
  is_active BOOLEAN DEFAULT true,
  source_url TEXT,
  raw_data JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_lawsnote_name ON lawsnote_lawyers(name);
CREATE INDEX idx_lawsnote_case_count ON lawsnote_lawyers(case_count_5yr DESC);
CREATE INDEX idx_lawsnote_expertise ON lawsnote_lawyers USING GIN(expertise_areas);
CREATE INDEX idx_lawsnote_regions ON lawsnote_lawyers USING GIN(regions);

ALTER TABLE lawsnote_lawyers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read" ON lawsnote_lawyers FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE TRIGGER lawsnote_lawyers_updated_at BEFORE UPDATE ON lawsnote_lawyers FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 5. 種子資料 - 資料來源
-- ============================================================

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency) VALUES
  ('法務部律師查詢', 'https://lawyer.moj.gov.tw/', '法務部律師資格查詢系統', 'lawyers', 'moj_lawyers', 'weekly'),
  ('經濟部商工登記', 'https://findbiz.nat.gov.tw/', '經濟部商業司商工登記公示資料', 'firms', 'moea_firms', 'weekly'),
  ('司法院統計', 'https://www.judicial.gov.tw/', '司法院司法統計年報', 'stats', 'judicial_stats', 'monthly'),
  ('法律新聞聚合', NULL, 'Google News + 法律媒體新聞', 'news', 'news', 'daily'),
  ('AI 市場分析', NULL, 'Claude API 產出的市場洞察報告', 'insights', 'ai_insights', 'weekly'),
  ('Lawsnote 律師專長', 'https://page.lawsnote.com/', 'Lawsnote 律師頁面 - 案件數與專長分布', 'lawyers', 'lawsnote_lawyers', 'weekly')
ON CONFLICT (name) DO NOTHING;
