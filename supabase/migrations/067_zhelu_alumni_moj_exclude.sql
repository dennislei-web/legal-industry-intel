-- 校友「MOJ 同名非本人」排除旗標
-- 情境：校友姓名在 MOJ 名冊撞到同名的別人（例：林書煒 ≠ 林書緯律師事務所的林書煒），
-- 比對出來的現職/去向是錯的。標 moj_exclude=true 後：
--   1. moj_alumni_refresh.py 跳過這位（不再每週回寫錯的 current_firm）
--   2. 前端去向顯示「同名非本人」、姓名不連結律師 modal、不出 🔄 重爬鈕
-- admin 前台每列可切換（RLS 寫入權限沿用 mig 062 的 admin update policy）
ALTER TABLE zhelu_alumni ADD COLUMN IF NOT EXISTS moj_exclude BOOLEAN NOT NULL DEFAULT false;
