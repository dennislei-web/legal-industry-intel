-- 075: 喆律校友會 + 010 合作律師 兩頁資料改 admin 限定（雷皓明帳號要求）
--
-- 1. zhelu_alumni：058 的 auth_read（所有登入者可讀）換成 admin-only read，
--    寫入端 062 的三條 admin policy 不動。
-- 2. law010_lawyer_summary view：view owner=postgres 繞過底表 RLS，
--    grant 無法區分 admin，改在 view 內加 admin 條件（auth.uid() 來自 request JWT，
--    非 admin / service key 查詢一律回空集合）。
-- 前端另配合把兩個 tab 藏起來（非 admin 看不到入口），但真正的鎖在這裡。

BEGIN;

-- 1. zhelu_alumni 讀取改 admin-only
DROP POLICY IF EXISTS zhelu_alumni_auth_read ON zhelu_alumni;
DROP POLICY IF EXISTS zhelu_alumni_admin_read ON zhelu_alumni;
CREATE POLICY zhelu_alumni_admin_read ON zhelu_alumni
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- 2. law010_lawyer_summary 加 admin gate（其餘定義同 073）
CREATE OR REPLACE VIEW law010_lawyer_summary AS
WITH base AS (
  SELECT
    trim(split_part(lawyer, '-', 1))       AS name,
    lawyer                                 AS entry,
    region,
    (year * 100 + month)                   AS yyyymm,
    COALESCE(referrals, 0)                 AS refs,
    COALESCE(attended, 0)                  AS att,
    COALESCE(signed, 0)                    AS sg,
    COALESCE(total_revenue, 0)             AS rev
  FROM fact_010_monthly_lawyer
  WHERE lawyer NOT LIKE '喆律%'
    AND EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
),
monthly AS (
  SELECT name, yyyymm,
         sum(refs) AS refs, sum(att) AS att, sum(sg) AS sg, sum(rev) AS rev
  FROM base
  GROUP BY name, yyyymm
),
meta AS (
  SELECT name,
         array_agg(DISTINCT entry)  AS entries,
         array_agg(DISTINCT region) FILTER (WHERE region IS NOT NULL AND region <> '') AS regions_010
  FROM base
  GROUP BY name
)
SELECT
  m.name,
  meta.entries,
  meta.regions_010,
  min(m.yyyymm) FILTER (WHERE m.refs > 0 OR m.rev > 0) AS first_month,
  max(m.yyyymm) FILTER (WHERE m.refs > 0 OR m.rev > 0) AS last_month,
  sum(m.refs)::int    AS referrals_total,
  sum(m.att)::int     AS attended_total,
  sum(m.sg)::int      AS signed_total,
  sum(m.rev)::bigint  AS revenue_total,
  jsonb_object_agg(m.yyyymm::text, jsonb_build_array(m.refs, m.sg, m.rev)) AS months
FROM monthly m
JOIN meta USING (name)
GROUP BY m.name, meta.entries, meta.regions_010;

COMMENT ON VIEW law010_lawyer_summary IS
  '法律010 合作律師逐人聚合（fact_010_monthly_lawyer 歸戶）；admin 限定（view 內 gate），非 admin 回空';

COMMIT;
