-- 072: 法律010 合作律師總覽 view（前端「010 合作律師」tab）
--
-- 資料源：fact_010_monthly_lawyer（lawyer-dashboard sync_010.py 每日凌晨重建，
--         口徑=010 平台轉介業績，涵蓋 2023-11 起）。
-- 本 view 把「林冠宇-桃園」等分所條目歸戶到基準姓名，聚合成每律師一列，
-- 逐月明細放 months jsonb（鍵=yyyymm，值=[轉介, 簽約, 業績]），前端自算活躍度/近12月。
-- 「喆律」「喆律-刑事案件」是轉回所內的列，非外部合作律師，排除。
--
-- 權限：view owner=postgres（繞過底表 RLS），只 grant authenticated；
--       010 業績屬內部營運資料，明確 revoke anon。

BEGIN;

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
),
monthly AS (  -- 同名多條目（分所）先併回 月×人
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
  '法律010 合作律師逐人聚合（fact_010_monthly_lawyer 歸戶）；months jsonb 鍵=yyyymm、值=[轉介,簽約,業績]；排除喆律所內列';

REVOKE ALL ON law010_lawyer_summary FROM anon;
REVOKE ALL ON law010_lawyer_summary FROM authenticated;
GRANT SELECT ON law010_lawyer_summary TO authenticated;

COMMIT;
