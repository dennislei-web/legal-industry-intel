-- ============================================================
-- 補 user_uploads 的 DELETE / UPDATE RLS 政策
-- ============================================================
-- 原本只有 SELECT / INSERT，導致前端無法刪除自己上傳的檔案。
-- 每個使用者只能刪除/更新自己的 upload (uploaded_by = auth.uid())
-- ============================================================

DO $$ BEGIN
  CREATE POLICY "users_delete_own" ON user_uploads
    FOR DELETE USING (auth.uid() = uploaded_by);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "users_update_own" ON user_uploads
    FOR UPDATE USING (auth.uid() = uploaded_by)
    WITH CHECK (auth.uid() = uploaded_by);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
