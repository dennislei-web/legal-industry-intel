-- ============================================================
-- AI 對話 + 資料源擴充 migration
-- ============================================================
-- 目的：
-- 1. 支援多 session 對話（chat_sessions / chat_messages）
-- 2. manual_notes 新增 source_type（標記快速記錄、URL 轉筆記等）
-- 3. news_articles 新增 AI 搜尋標記
-- ============================================================

-- ========= 對話 session =========
CREATE TABLE IF NOT EXISTS chat_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '新對話',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  last_message_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_user
  ON chat_sessions(user_id, last_message_at DESC);

ALTER TABLE chat_sessions ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "own_sessions" ON chat_sessions
    FOR ALL USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ========= 對話訊息 =========
CREATE TABLE IF NOT EXISTS chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES chat_sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content TEXT NOT NULL,
  sources JSONB,                    -- [{type, id, title}]
  tool_uses JSONB,                  -- Claude tool_use 記錄（web_search 等）
  tokens_used INTEGER,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_session
  ON chat_messages(session_id, created_at);

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "own_messages" ON chat_messages
    FOR ALL USING (
      session_id IN (SELECT id FROM chat_sessions WHERE user_id = auth.uid())
    )
    WITH CHECK (
      session_id IN (SELECT id FROM chat_sessions WHERE user_id = auth.uid())
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ========= manual_notes 擴充 =========
ALTER TABLE manual_notes
  ADD COLUMN IF NOT EXISTS source_type TEXT DEFAULT 'manual';

-- 移除舊 check 若存在，加新 check（包含新值）
DO $$ BEGIN
  ALTER TABLE manual_notes DROP CONSTRAINT IF EXISTS manual_notes_source_type_check;
  ALTER TABLE manual_notes ADD CONSTRAINT manual_notes_source_type_check
    CHECK (source_type IN ('manual', 'quick', 'url', 'ai_extracted'));
EXCEPTION WHEN others THEN NULL; END $$;

ALTER TABLE manual_notes
  ADD COLUMN IF NOT EXISTS source_url TEXT;


-- ========= news_articles 擴充 =========
ALTER TABLE news_articles
  ADD COLUMN IF NOT EXISTS search_query TEXT,
  ADD COLUMN IF NOT EXISTS ai_fetched BOOLEAN DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_news_search_query
  ON news_articles(search_query) WHERE search_query IS NOT NULL;


-- ========= Trigger: chat_sessions updated_at =========
DROP TRIGGER IF EXISTS chat_sessions_updated_at ON chat_sessions;
CREATE TRIGGER chat_sessions_updated_at BEFORE UPDATE ON chat_sessions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ========= RPC: 最近搜尋過的 query (for news tab) =========
CREATE OR REPLACE FUNCTION recent_news_queries(lim INT DEFAULT 10)
RETURNS TABLE (query TEXT, last_used TIMESTAMPTZ, article_count BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT search_query AS query,
         MAX(scraped_at) AS last_used,
         COUNT(*)::BIGINT AS article_count
  FROM news_articles
  WHERE search_query IS NOT NULL AND ai_fetched = true
  GROUP BY search_query
  ORDER BY MAX(scraped_at) DESC
  LIMIT lim;
$$;

GRANT EXECUTE ON FUNCTION recent_news_queries(INT) TO anon, authenticated;
