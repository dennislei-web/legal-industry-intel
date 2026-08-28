-- ============================================================
-- 事務所數位獲客足跡（mig 169）
-- firm_google_places：Google 商家評分/評論數（Outscraper Maps search）
-- firm_digital_signals：官網社群連結＋廣告追蹤碼偵測
-- ============================================================

CREATE TABLE IF NOT EXISTS firm_google_places (
  firm_name text PRIMARY KEY,
  query text,
  place_id text,
  gmaps_name text,
  rating numeric,
  reviews_count int,
  address text,
  matched boolean DEFAULT false,
  fetched_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS firm_digital_signals (
  firm_name text PRIMARY KEY,
  url text,
  http_status int,
  fb_url text,
  ig_url text,
  line_url text,
  yt_url text,
  has_fb_pixel boolean DEFAULT false,
  has_google_ads boolean DEFAULT false,
  has_ga boolean DEFAULT false,
  has_gtm boolean DEFAULT false,
  has_tiktok_pixel boolean DEFAULT false,
  fetched_at timestamptz DEFAULT now()
);

ALTER TABLE firm_google_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_digital_signals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth_read_firm_google_places" ON firm_google_places
  FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "auth_read_firm_digital_signals" ON firm_digital_signals
  FOR SELECT USING (auth.uid() IS NOT NULL);
