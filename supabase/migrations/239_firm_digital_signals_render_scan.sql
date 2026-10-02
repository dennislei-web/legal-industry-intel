-- ============================================================
-- mig 239：廣告碼偵測補強（GTM 容器拆解＋無頭瀏覽器網路請求）
-- 原 mig 169 只掃首頁原始 HTML，經 GTM 載入的 Pixel / Ads 全數漏判
-- （喆律 zhelu.tw 即是：GTM-MT7SNNM 內含 AW- 轉換碼與 FB Pixel）。
-- has_* 維持「任一來源偵測到」語意；ads_evidence 記每類訊號的來源。
-- ============================================================
ALTER TABLE firm_digital_signals
  ADD COLUMN IF NOT EXISTS has_line_tag boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS has_yahoo_ads boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS gtm_ids text[],
  ADD COLUMN IF NOT EXISTS ads_evidence jsonb,
  ADD COLUMN IF NOT EXISTS render_pages int,
  ADD COLUMN IF NOT EXISTS render_status text,
  ADD COLUMN IF NOT EXISTS render_scanned_at timestamptz;

ALTER TABLE firm_analysis_facts
  ADD COLUMN IF NOT EXISTS line_tag INT,
  ADD COLUMN IF NOT EXISTS yahoo_ads INT,
  ADD COLUMN IF NOT EXISTS tiktok_pixel INT;
