-- ============================================================
-- 014: courts - 法院資料表
-- ============================================================

CREATE TABLE IF NOT EXISTS courts (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  short_name TEXT,
  court_type TEXT NOT NULL CHECK (court_type IN ('地方法院', '高等法院', '最高法院', '專業法院')),
  region TEXT,
  address TEXT,
  phone TEXT,
  website_url TEXT,
  annual_case_volume INTEGER,
  annual_clearance_rate NUMERIC(5,2),
  avg_processing_days NUMERIC(7,2),
  stats_year INTEGER,
  raw_data JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_courts_type ON courts(court_type);
CREATE INDEX IF NOT EXISTS idx_courts_region ON courts(region);
CREATE INDEX IF NOT EXISTS idx_courts_name ON courts(name);

ALTER TABLE courts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_courts" ON courts FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE TRIGGER courts_updated_at
  BEFORE UPDATE ON courts FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 種子資料：台灣各級法院
-- ============================================================
INSERT INTO courts (name, short_name, court_type, region) VALUES
  -- 最高法院
  ('最高法院', '最高院', '最高法院', '台北'),
  ('最高行政法院', '最高行政', '最高法院', '台北'),

  -- 高等法院
  ('臺灣高等法院', '高院', '高等法院', '台北'),
  ('臺灣高等法院臺中分院', '中高分院', '高等法院', '台中'),
  ('臺灣高等法院臺南分院', '南高分院', '高等法院', '台南'),
  ('臺灣高等法院高雄分院', '高高分院', '高等法院', '高雄'),
  ('臺灣高等法院花蓮分院', '花高分院', '高等法院', '花蓮'),
  ('臺北高等行政法院', '北高行', '高等法院', '台北'),
  ('臺中高等行政法院', '中高行', '高等法院', '台中'),
  ('高雄高等行政法院', '高高行', '高等法院', '高雄'),

  -- 專業法院
  ('智慧財產及商業法院', '智商法院', '專業法院', '台北'),
  ('懲戒法院', '懲戒院', '專業法院', '台北'),

  -- 地方法院
  ('臺灣臺北地方法院', '北院', '地方法院', '台北'),
  ('臺灣新北地方法院', '新北院', '地方法院', '新北'),
  ('臺灣士林地方法院', '士林院', '地方法院', '台北'),
  ('臺灣桃園地方法院', '桃院', '地方法院', '桃園'),
  ('臺灣新竹地方法院', '竹院', '地方法院', '新竹'),
  ('臺灣苗栗地方法院', '苗院', '地方法院', '苗栗'),
  ('臺灣臺中地方法院', '中院', '地方法院', '台中'),
  ('臺灣南投地方法院', '投院', '地方法院', '南投'),
  ('臺灣彰化地方法院', '彰院', '地方法院', '彰化'),
  ('臺灣雲林地方法院', '雲院', '地方法院', '雲林'),
  ('臺灣嘉義地方法院', '嘉院', '地方法院', '嘉義'),
  ('臺灣臺南地方法院', '南院', '地方法院', '台南'),
  ('臺灣高雄地方法院', '雄院', '地方法院', '高雄'),
  ('臺灣橋頭地方法院', '橋院', '地方法院', '高雄'),
  ('臺灣屏東地方法院', '屏院', '地方法院', '屏東'),
  ('臺灣臺東地方法院', '東院', '地方法院', '台東'),
  ('臺灣花蓮地方法院', '花院', '地方法院', '花蓮'),
  ('臺灣宜蘭地方法院', '宜院', '地方法院', '宜蘭'),
  ('臺灣基隆地方法院', '基院', '地方法院', '基隆'),
  ('臺灣澎湖地方法院', '澎院', '地方法院', '澎湖'),
  ('福建金門地方法院', '金院', '地方法院', '金門'),
  ('福建連江地方法院', '連院', '地方法院', '連江'),
  ('臺灣高雄少年及家事法院', '高少家', '專業法院', '高雄')
ON CONFLICT (name) DO NOTHING;
