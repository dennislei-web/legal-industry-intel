-- 前台 admin 標註所長：事務所 modal 律師清單可直接標註/移除
-- 優先序：本表 > index.html 硬編碼 FIRM_LEADERS > 一人所自動推定（mig 060）
CREATE TABLE IF NOT EXISTS firm_leader_overrides (
  id BIGSERIAL PRIMARY KEY,
  lawyer_name TEXT NOT NULL,
  firm_name TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '所長',
  created_by UUID DEFAULT auth.uid(),
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (lawyer_name, firm_name)
);

ALTER TABLE firm_leader_overrides ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth_read_flo" ON firm_leader_overrides
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "admin_insert_flo" ON firm_leader_overrides
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "admin_update_flo" ON firm_leader_overrides
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "admin_delete_flo" ON firm_leader_overrides
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );
