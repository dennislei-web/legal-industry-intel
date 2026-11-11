-- ============================================================
-- 276: 官網人工／加驗審核結果
-- ============================================================
-- 275 的 roster_match='firm_only'（只有所名、官網找不到名冊律師姓名）是同名錯配的審核佇列。
-- 2026-11-11 首輪清理 264 間法律事務所：
--   76 間靠名冊的地址／電話／信箱網域加驗通過 → confirmed
--   其餘逐筆看網站標題：明顯是別的機構（會計師／專利商標／地政士事務所、
--   日本與中國同名律所、出版社、平台…）→ rejected 並 verified=false（網址保留備查）
-- 審核佇列＝ roster_match='firm_only' AND review_status IS NULL
-- recheck_firm_websites.py 不會動 review_* 欄，也不會把 rejected 的自動轉回 verified
-- （它只恢復 auto_unverified_at 有值的）。
-- ============================================================
ALTER TABLE firm_websites
  ADD COLUMN IF NOT EXISTS review_status TEXT,
  ADD COLUMN IF NOT EXISTS review_note TEXT,
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ;

COMMENT ON COLUMN firm_websites.review_status IS 'confirmed（確認是本所官網）/ rejected（錯配，已下架）/ pending（看過仍無法判定）；NULL＝未審';
