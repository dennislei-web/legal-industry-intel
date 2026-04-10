-- ============================================================
-- 移除已淘汰功能：新聞/AI 洞察/手動輸入/對話/學術論文/上傳
-- ============================================================
-- 這些功能已從前端與爬蟲全數刪除，本 migration 清除對應的 DB 物件。
-- 注意：DROP TABLE CASCADE 會永久刪除資料，執行前請確認不需備份。
-- ============================================================

-- 先移除相依的 RPC
DROP FUNCTION IF EXISTS recent_news_queries(INT);
DROP FUNCTION IF EXISTS search_paper_chunks(TEXT, INT);

-- 依序 DROP TABLE (CASCADE 會順便清掉 policy / trigger / index)
DROP TABLE IF EXISTS paper_chunks CASCADE;
DROP TABLE IF EXISTS academic_papers CASCADE;
DROP TABLE IF EXISTS chat_messages CASCADE;
DROP TABLE IF EXISTS chat_sessions CASCADE;
DROP TABLE IF EXISTS user_uploads CASCADE;
DROP TABLE IF EXISTS manual_notes CASCADE;
DROP TABLE IF EXISTS ai_insights CASCADE;
DROP TABLE IF EXISTS news_articles CASCADE;

-- 清掉 data_sources 中僅用於這些功能的項目
DELETE FROM data_sources WHERE name IN ('法律新聞聚合', 'AI 市場分析');
