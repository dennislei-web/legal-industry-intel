-- ============================================================
-- 275: 官網定期複驗（健康檢查＋名冊律師姓名比對）
-- ============================================================
-- 背景（2026-11-11 盤點）：
--   1,493 筆已驗證官網中 1,473 筆超過 60 天沒重驗；隨機抽 120 筆，
--   約 11% 已連不上或失效、2% 內容是別的網站、35% 只有所名命中
--   （首頁沒有名冊律師姓名，擋不住同名所）。
--
-- 做法：scripts/recheck_firm_websites.py 每週跑，寫入下列欄位。
--   health_status   ok＝連得上且首頁有所名
--                   name_missing＝連得上但首頁找不到所名
--                   http_error＝404／410／5xx
--                   unreachable＝DNS／連線／逾時
--                   blocked＝403／429／503（疑似擋爬蟲，不計入連續失敗）
--   fail_streak     連續失敗次數；ok 歸零、blocked 不動
--                   達門檻（預設 3 次）→ verified=false，網址保留、之後恢復會自動轉回
--   roster_match    lawyer_name＝官網找得到名冊上該所律師姓名（高信心）
--                   firm_only＝只有所名（中信心，同名所風險）
--                   none＝連不上或兩者皆無
-- 不動 moj_firm_statistics()：它只認 verified IS TRUE，由腳本翻 verified 即可。
-- ============================================================

ALTER TABLE firm_websites
  ADD COLUMN IF NOT EXISTS health_status TEXT,
  ADD COLUMN IF NOT EXISTS health_http_status INTEGER,
  ADD COLUMN IF NOT EXISTS health_checked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS fail_streak INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS auto_unverified_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS roster_match TEXT,
  ADD COLUMN IF NOT EXISTS roster_hit_count INTEGER,
  ADD COLUMN IF NOT EXISTS roster_total INTEGER,
  ADD COLUMN IF NOT EXISTS roster_hit_url TEXT;

COMMENT ON COLUMN firm_websites.health_status IS 'ok / name_missing / http_error / unreachable / blocked（recheck_firm_websites.py 每週寫入）';
COMMENT ON COLUMN firm_websites.fail_streak IS '連續複驗失敗次數；達門檻自動 verified=false';
COMMENT ON COLUMN firm_websites.auto_unverified_at IS '被複驗自動下架的時間；有值＝非人工判定，恢復正常會自動轉回 verified';
COMMENT ON COLUMN firm_websites.roster_match IS 'lawyer_name（官網有名冊律師姓名）/ firm_only（只有所名）/ none';
