-- ============================================================
-- 學術論文知識庫 (NDLTD + Scholar)
-- ============================================================
-- 目的: 讓使用者累積學術論文供 AI 對話引用
--   academic_papers: 論文 metadata (title/authors/abstract/...)
--   paper_chunks: 全文切片 (按章節或每 ~1500 字)
--   search_paper_chunks RPC: full-text search (之後可換 pgvector)
-- ============================================================

CREATE TABLE IF NOT EXISTS academic_papers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  authors TEXT[],
  year INTEGER,
  venue TEXT,
  degree_type TEXT,
  abstract TEXT,
  keywords TEXT[],
  source TEXT,
  source_url TEXT NOT NULL,
  pdf_url TEXT,
  citation_count INTEGER,
  full_text_length INTEGER,
  chunk_count INTEGER DEFAULT 0,
  import_status TEXT DEFAULT 'metadata_only',
  notes TEXT,
  imported_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Checks (用 DO block 容許 idempotent)
DO $$ BEGIN
  ALTER TABLE academic_papers ADD CONSTRAINT academic_papers_degree_type_check
    CHECK (degree_type IS NULL OR degree_type IN ('thesis_master', 'thesis_phd', 'journal', 'conference', 'book', 'other'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE academic_papers ADD CONSTRAINT academic_papers_import_status_check
    CHECK (import_status IN ('metadata_only', 'fulltext_ready', 'failed'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS paper_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  paper_id UUID REFERENCES academic_papers(id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL,
  section TEXT,
  content TEXT NOT NULL,
  char_count INTEGER,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_papers_year ON academic_papers(year DESC);
CREATE INDEX IF NOT EXISTS idx_papers_source ON academic_papers(source);
CREATE INDEX IF NOT EXISTS idx_papers_user ON academic_papers(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_papers_url_user ON academic_papers(user_id, source_url);
CREATE INDEX IF NOT EXISTS idx_chunks_paper ON paper_chunks(paper_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_chunks_fts ON paper_chunks USING gin(to_tsvector('simple', content));

ALTER TABLE academic_papers ENABLE ROW LEVEL SECURITY;
ALTER TABLE paper_chunks ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "own_papers" ON academic_papers FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "own_chunks" ON paper_chunks FOR ALL
    USING (paper_id IN (SELECT id FROM academic_papers WHERE user_id = auth.uid()))
    WITH CHECK (paper_id IN (SELECT id FROM academic_papers WHERE user_id = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DROP TRIGGER IF EXISTS academic_papers_updated_at ON academic_papers;
CREATE TRIGGER academic_papers_updated_at BEFORE UPDATE ON academic_papers
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- RPC: 對 chunks 做 full-text search
-- ============================================================
CREATE OR REPLACE FUNCTION search_paper_chunks(
  query_text TEXT,
  max_results INT DEFAULT 5
)
RETURNS TABLE (
  paper_id UUID,
  paper_title TEXT,
  paper_year INT,
  chunk_index INT,
  section TEXT,
  content TEXT,
  rank REAL
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    c.paper_id,
    p.title AS paper_title,
    p.year AS paper_year,
    c.chunk_index,
    c.section,
    c.content,
    ts_rank(to_tsvector('simple', c.content), plainto_tsquery('simple', query_text)) AS rank
  FROM paper_chunks c
  JOIN academic_papers p ON p.id = c.paper_id
  WHERE to_tsvector('simple', c.content) @@ plainto_tsquery('simple', query_text)
    AND p.user_id = auth.uid()
  ORDER BY rank DESC
  LIMIT max_results;
$$;

GRANT EXECUTE ON FUNCTION search_paper_chunks(TEXT, INT) TO authenticated;
