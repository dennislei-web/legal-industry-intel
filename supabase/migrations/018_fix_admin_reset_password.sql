-- ============================================================
-- 018: 修正 admin_reset_password 同時支援兩個系統
-- ============================================================
-- 問題：lawyer-dashboard 用 lawyers.role='admin'
--       legal-industry-intel 用 user_profiles.role='admin'
--       之前只檢查 user_profiles，導致 lawyer-dashboard 管理員無法重設密碼
-- 修正：同時檢查兩個表

DROP FUNCTION IF EXISTS admin_reset_password(uuid, text);

CREATE OR REPLACE FUNCTION admin_reset_password(target_user_id UUID, new_password TEXT)
RETURNS VOID AS $$
BEGIN
  -- 檢查呼叫者是否為 admin（user_profiles 或 lawyers 任一）
  IF NOT EXISTS (
    SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin'
  ) AND NOT EXISTS (
    SELECT 1 FROM lawyers WHERE auth_user_id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Permission denied: admin only';
  END IF;

  -- 透過 auth schema 更新密碼
  UPDATE auth.users SET encrypted_password = crypt(new_password, gen_salt('bf'))
  WHERE id = target_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
