-- 校友會頁前台 admin 手動新增校友
-- is_manual：手動加的列；日後若重跑比對用 DELETE+INSERT 重建，務必 WHERE is_manual = false 保留手動列
ALTER TABLE zhelu_alumni ADD COLUMN IF NOT EXISTS is_manual BOOLEAN NOT NULL DEFAULT false;

DROP POLICY IF EXISTS zhelu_alumni_admin_insert ON zhelu_alumni;
CREATE POLICY zhelu_alumni_admin_insert ON zhelu_alumni
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS zhelu_alumni_admin_update ON zhelu_alumni;
CREATE POLICY zhelu_alumni_admin_update ON zhelu_alumni
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS zhelu_alumni_admin_delete ON zhelu_alumni;
CREATE POLICY zhelu_alumni_admin_delete ON zhelu_alumni
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );
