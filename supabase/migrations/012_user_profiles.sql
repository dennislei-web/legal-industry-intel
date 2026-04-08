-- ============================================================
-- 012: user_profiles - 使用者角色管理
-- ============================================================

-- 使用者 profile（連結 auth.users）
CREATE TABLE IF NOT EXISTS user_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  display_name TEXT,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_user_profiles_role ON user_profiles(role);
CREATE INDEX idx_user_profiles_email ON user_profiles(email);

ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- 登入使用者可讀取所有 profile（方便 admin 列表）
CREATE POLICY "auth_read_profiles" ON user_profiles
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 只有 admin 可以修改 profile
CREATE POLICY "admin_update_profiles" ON user_profiles
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- 只有 admin 可以新增 profile
CREATE POLICY "admin_insert_profiles" ON user_profiles
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE TRIGGER user_profiles_updated_at
  BEFORE UPDATE ON user_profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- admin_reset_password RPC（需要 security definer 才能呼叫 auth API）
-- ============================================================
DROP FUNCTION IF EXISTS admin_reset_password(uuid, text);
CREATE OR REPLACE FUNCTION admin_reset_password(target_user_id UUID, new_password TEXT)
RETURNS VOID AS $$
BEGIN
  -- 檢查呼叫者是否為 admin
  IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Permission denied: admin only';
  END IF;

  -- 透過 auth schema 更新密碼
  UPDATE auth.users SET encrypted_password = crypt(new_password, gen_salt('bf'))
  WHERE id = target_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
