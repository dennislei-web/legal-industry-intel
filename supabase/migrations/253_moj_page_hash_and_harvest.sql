-- ============================================================
-- 253: MOJ 新站（2026-10-29 改版）名冊刷新管線——詳細頁雜湊欄位＋人工查詢收成表
-- ============================================================
-- 背景：lawyerbc.moj.gov.tw 改版後 /api/cert/* 全部下架，查詢一律要人工過驗證碼
--   （每次 ≤100 筆），但律師詳細頁 /lawyer/{資料雜湊值} 是公開資源（免驗證碼、免 cookie）。
--   新架構（docs/moj-site-redesign-2026-10.md）：
--   ① 同仁在官網自己打驗證碼查詢 → 書籤助手（public/tools/moj-harvest.js）把頁面上
--      已顯示的查詢結果（含 id_no＝資料雜湊值）送進 moj_search_harvest
--   ② scripts/moj_harvest_ingest.py 以證號對上 moj_lawyers 寫 page_hash；對不上的當新律師插入
--   ③ scripts/moj_detail_sweep.py 每週五逐頁 GET 詳細頁、比對事務所／公會／執業狀態／懲戒，
--      只 PATCH 有變動者（trigger moj_lawyers_log_change 照常寫 moj_lawyer_changes）；
--      404 → page_hash_missing_at（進人工複查佇列，**不等於除名**）
--   驗證碼永遠由人在官網打；本 migration 與相關腳本不做任何驗證碼自動化。

-- (A) moj_lawyers：詳細頁雜湊與巡檢時間 ---------------------------------
ALTER TABLE moj_lawyers
  ADD COLUMN IF NOT EXISTS page_hash            TEXT,
  ADD COLUMN IF NOT EXISTS page_checked_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS page_hash_missing_at TIMESTAMPTZ;

COMMENT ON COLUMN moj_lawyers.page_hash IS
  '新站詳細頁 /lawyer/{hash} 的資料雜湊值（0x＋64 hex）。只能從人工查詢結果的 id_no 取得，不可推算';
COMMENT ON COLUMN moj_lawyers.page_checked_at IS
  '最近一次詳細頁 GET 200 並完成比對的時間（moj_detail_sweep.py）';
COMMENT ON COLUMN moj_lawyers.page_hash_missing_at IS
  '詳細頁回 404 的時間：雜湊失效或名冊已移除，進人工複查佇列（moj_query_plan.py --incremental 會列出）。不是除名標記';

-- 同一個雜湊不該掛在兩位律師身上（ingest 對錯人會在這裡被擋下）
CREATE UNIQUE INDEX IF NOT EXISTS idx_moj_lawyers_page_hash
  ON moj_lawyers(page_hash) WHERE page_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_moj_lawyers_page_missing
  ON moj_lawyers(page_hash_missing_at) WHERE page_hash_missing_at IS NOT NULL;

-- (B) 人工查詢收成表 ---------------------------------------------------------
-- 一列＝官網查詢結果表的一列（欄位名照官網 bootstrapTable：name / now_lic_no→lic_no / office /
-- guild_name / id_no）＋當時的查詢字串。寫入走 moj_harvest_submit()（anon 可呼叫，見 D 段），
-- 讀取限 admin；對外只開 moj_harvest_progress 聚合 view（不含姓名）給進度頁。
CREATE TABLE IF NOT EXISTS moj_search_harvest (
  id           BIGSERIAL PRIMARY KEY,
  name         TEXT,
  lic_no       TEXT,
  office       TEXT,
  guild_name   TEXT,
  id_no        TEXT NOT NULL,
  query        TEXT,
  harvested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ingested_at  TIMESTAMPTZ,
  -- anon 可寫，用形狀限制擋垃圾：雜湊固定 0x＋64 hex、各欄長度上限
  CONSTRAINT moj_search_harvest_id_no_fmt CHECK (id_no ~ '^0x[0-9a-fA-F]{64}$'),
  CONSTRAINT moj_search_harvest_len CHECK (
    coalesce(length(name), 0)       <= 100 AND
    coalesce(length(lic_no), 0)     <= 60  AND
    coalesce(length(office), 0)     <= 200 AND
    coalesce(length(guild_name), 0) <= 200 AND
    coalesce(length(query), 0)      <= 60),
  -- 同一筆結果重送不重複（moj_harvest_submit() 內 ON CONFLICT DO NOTHING）
  CONSTRAINT moj_search_harvest_uq UNIQUE NULLS NOT DISTINCT (id_no, lic_no)
);

CREATE INDEX IF NOT EXISTS idx_moj_search_harvest_pending
  ON moj_search_harvest(harvested_at) WHERE ingested_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_moj_search_harvest_query ON moj_search_harvest(query);

ALTER TABLE moj_search_harvest ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "harvest_insert_any" ON moj_search_harvest;
CREATE POLICY "harvest_insert_any" ON moj_search_harvest
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "harvest_admin_read" ON moj_search_harvest;
CREATE POLICY "harvest_admin_read" ON moj_search_harvest
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM user_profiles up WHERE up.id = auth.uid() AND up.role = 'admin'));

GRANT INSERT ON moj_search_harvest TO anon, authenticated;
GRANT SELECT ON moj_search_harvest TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE moj_search_harvest_id_seq TO anon, authenticated;

-- (C) 查詢紀錄＋進度 view ------------------------------------------------------
-- 每次送出（含 0 筆：官網「找不到或超過 100 筆」）都記一列，進度頁才分得出「查過了」與「還沒查」。
-- 只經 moj_harvest_submit() 寫入（RLS 開啟、無 policy＝anon/authenticated 直接存取一律拒絕）。
CREATE TABLE IF NOT EXISTS moj_harvest_queries (
  id           BIGSERIAL PRIMARY KEY,
  query        TEXT NOT NULL CHECK (length(query) BETWEEN 1 AND 60),
  received     INT  NOT NULL,
  inserted     INT  NOT NULL,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_moj_harvest_queries_query ON moj_harvest_queries(query);
ALTER TABLE moj_harvest_queries ENABLE ROW LEVEL SECURITY;

-- 不含姓名／證號，給 public/tools/moj-harvest.html 對照查詢清單顯示完成度（anon 可讀）
DROP VIEW IF EXISTS moj_harvest_progress;
CREATE VIEW moj_harvest_progress AS
SELECT q.query,
       count(*)                                                AS submits,
       max(q.submitted_at)                                     AS last_at,
       (array_agg(q.received ORDER BY q.submitted_at DESC))[1] AS last_received,
       max(q.received)                                         AS max_received,
       coalesce(h.hashes_n, 0)                                 AS hashes_n,
       coalesce(h.ingested_n, 0)                               AS ingested_n
FROM moj_harvest_queries q
LEFT JOIN (
  SELECT query,
         count(DISTINCT id_no)                           AS hashes_n,
         count(*) FILTER (WHERE ingested_at IS NOT NULL) AS ingested_n
  FROM moj_search_harvest
  WHERE query IS NOT NULL
  GROUP BY query
) h USING (query)
GROUP BY q.query, h.hashes_n, h.ingested_n;

GRANT SELECT ON moj_harvest_progress TO anon, authenticated;

-- (D) 書籤助手寫入入口 ----------------------------------------------------------
-- anon 直接 INSERT … ON CONFLICT DO NOTHING 會被 RLS 擋（ON CONFLICT 需要通過 SELECT policy，
-- 而原表刻意不給 anon 讀）→ 改走 SECURITY DEFINER 函數：只做「去重插入」，回傳筆數，不回任何資料。
-- 單次上限 200 列（官網一次最多 100 筆）；形狀檢查沿用表上的 CHECK，不合格的列略過不中斷。
CREATE OR REPLACE FUNCTION moj_harvest_submit(p_query text, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recv int;
  v_ins  int;
BEGIN
  IF coalesce(btrim(p_query), '') = '' OR length(btrim(p_query)) > 60 THEN
    RAISE EXCEPTION 'p_query 必須是 1～60 字的查詢字串';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows 必須是陣列';
  END IF;
  v_recv := jsonb_array_length(p_rows);
  IF v_recv > 200 THEN
    RAISE EXCEPTION '單次最多 200 列（收到 %）', v_recv;
  END IF;

  WITH src AS (
    SELECT nullif(btrim(r->>'name'), '')       AS name,
           nullif(btrim(r->>'lic_no'), '')     AS lic_no,
           nullif(btrim(r->>'office'), '')     AS office,
           nullif(btrim(r->>'guild_name'), '') AS guild_name,
           btrim(r->>'id_no')                  AS id_no
    FROM jsonb_array_elements(p_rows) r
  ), ok AS (
    SELECT * FROM src
    WHERE id_no ~ '^0x[0-9a-fA-F]{64}$'
      AND coalesce(length(name), 0) <= 100 AND coalesce(length(lic_no), 0) <= 60
      AND coalesce(length(office), 0) <= 200 AND coalesce(length(guild_name), 0) <= 200
  ), ins AS (
    INSERT INTO moj_search_harvest (name, lic_no, office, guild_name, id_no, query)
    SELECT DISTINCT ON (id_no, lic_no) name, lic_no, office, guild_name, id_no, left(btrim(p_query), 60)
    FROM ok
    ON CONFLICT ON CONSTRAINT moj_search_harvest_uq DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_ins FROM ins;

  INSERT INTO moj_harvest_queries (query, received, inserted)
  VALUES (btrim(p_query), v_recv, v_ins);

  RETURN jsonb_build_object('received', v_recv, 'inserted', v_ins);
END;
$$;

REVOKE ALL ON FUNCTION moj_harvest_submit(text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION moj_harvest_submit(text, jsonb) TO anon, authenticated;
