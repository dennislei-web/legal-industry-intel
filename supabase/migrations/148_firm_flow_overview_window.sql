-- 148: firm_flow_overview 加時間窗參數（異動追蹤頁整併第二階段）
-- p_days = 0（預設）→ 全部累積；> 0 → 只計最近 N 天的異動事件。
-- 窗只套在「事件」（進出/新血/配對/最近異動）；「狀態」（熄燈/新設/改名，
-- 內部呼叫 firm_open_close）與「現有人數」描述的是當前狀態，不隨窗變。
-- keys 只取窗內有事件的所：短窗＝「這段期間有動靜的所」，窗外熄燈所不混入。
-- 改參數列需 DROP 舊簽名（CREATE OR REPLACE 不能改參數，會變 overload）。

DROP FUNCTION IF EXISTS firm_flow_overview();

CREATE OR REPLACE FUNCTION firm_flow_overview(p_days int DEFAULT 0)
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
WITH win AS (
  SELECT * FROM moj_lawyer_changes
  WHERE p_days <= 0 OR changed_at >= now() - make_interval(days => p_days)
), oc AS (SELECT firm_open_close() AS j),
closed AS (
  SELECT x->>'firm_key' AS fk, x->>'kind' AS kind, x->>'closed_at' AS closed_at,
         x->>'dest_firm' AS dest_firm, (x->>'dest_moved')::int AS dest_moved
  FROM oc, json_array_elements(oc.j->'closed') x
), opened AS (
  SELECT x->>'firm_key' AS fk, x->>'kind' AS kind, x->>'opened_at' AS opened_at,
         ARRAY(SELECT json_array_elements_text(x->'from_firms')) AS from_firms
  FROM oc, json_array_elements(oc.j->'opened') x
), roster AS (
  SELECT flow_firm_key(office_normalized) AS fk,
         count(*) FILTER (WHERE state_desc = '正常' AND deregistered_at IS NULL)::int AS active_n
  FROM moj_lawyers
  WHERE flow_is_firm(office_normalized)
  GROUP BY 1
), mv AS (
  SELECT flow_firm_key(old_office) AS src, flow_firm_key(new_office) AS dst, changed_at
  FROM win
  WHERE change_type = 'firm_change'
    AND flow_is_firm(old_office) AND flow_is_firm(new_office)
    AND flow_firm_key(old_office) IS DISTINCT FROM flow_firm_key(new_office)
), fin AS (
  SELECT dst AS fk, count(*)::int AS n, max(changed_at) AS last_at FROM mv GROUP BY 1
), fout AS (
  SELECT src AS fk, count(*)::int AS n, max(changed_at) AS last_at FROM mv GROUP BY 1
), oth_in AS (
  SELECT flow_firm_key(new_office) AS fk, count(*)::int AS n, max(changed_at) AS last_at
  FROM win
  WHERE change_type = 'firm_change' AND flow_is_firm(new_office) AND NOT flow_is_firm(old_office)
  GROUP BY 1
), oth_out AS (
  SELECT fk, count(*)::int AS n, max(la) AS last_at FROM (
    SELECT flow_firm_key(old_office) AS fk, changed_at AS la
    FROM win
    WHERE change_type = 'firm_change' AND flow_is_firm(old_office) AND NOT flow_is_firm(new_office)
    UNION ALL
    SELECT flow_firm_key(l.office_normalized), c.changed_at
    FROM win c
    JOIN moj_lawyers l USING (lic_no)
    WHERE c.change_type = 'state_change' AND c.new_state IS DISTINCT FROM '正常'
      AND flow_is_firm(l.office_normalized)
  ) t GROUP BY 1
), nk AS (
  SELECT flow_firm_key(new_office) AS fk, count(*)::int AS n, max(changed_at) AS last_at
  FROM win
  WHERE change_type = 'new_lawyer' AND flow_is_firm(new_office)
  GROUP BY 1
), pair AS (
  SELECT src, dst, count(*)::int AS n FROM mv GROUP BY 1, 2
), top_src AS (
  SELECT DISTINCT ON (dst) dst AS fk, src AS other, n FROM pair ORDER BY dst, n DESC, src
), top_dst AS (
  SELECT DISTINCT ON (src) src AS fk, dst AS other, n FROM pair ORDER BY src, n DESC, dst
), keys AS (
  SELECT fk FROM fin UNION SELECT fk FROM fout UNION SELECT fk FROM oth_in
  UNION SELECT fk FROM oth_out UNION SELECT fk FROM nk
)
SELECT coalesce(json_agg(row_to_json(r) ORDER BY r.net DESC, r.firm_key), '[]'::json) FROM (
  SELECT k.fk AS firm_key,
         coalesce(ro.active_n, 0) AS active_n,
         coalesce(fi.n, 0) AS in_firm,
         coalesce(oi.n, 0) AS other_in,
         coalesce(nn.n, 0) AS intake,
         coalesce(fo.n, 0) AS out_firm,
         coalesce(oo.n, 0) AS other_out,
         coalesce(fi.n,0) + coalesce(oi.n,0) + coalesce(nn.n,0)
           - coalesce(fo.n,0) - coalesce(oo.n,0) AS net,
         CASE WHEN cl.fk IS NOT NULL THEN 'closed_' || cl.kind
              WHEN op.fk IS NOT NULL THEN 'opened_' || op.kind
              ELSE 'normal' END AS status,
         cl.dest_firm, cl.dest_moved, cl.closed_at,
         op.opened_at, op.from_firms,
         ts.other AS top_src, ts.n AS top_src_n,
         td.other AS top_dst, td.n AS top_dst_n,
         greatest(fi.last_at, fo.last_at, oi.last_at, oo.last_at, nn.last_at)::date AS last_at
  FROM keys k
  LEFT JOIN roster ro ON ro.fk = k.fk
  LEFT JOIN fin fi ON fi.fk = k.fk
  LEFT JOIN fout fo ON fo.fk = k.fk
  LEFT JOIN oth_in oi ON oi.fk = k.fk
  LEFT JOIN oth_out oo ON oo.fk = k.fk
  LEFT JOIN nk nn ON nn.fk = k.fk
  LEFT JOIN closed cl ON cl.fk = k.fk
  LEFT JOIN opened op ON op.fk = k.fk
  LEFT JOIN top_src ts ON ts.fk = k.fk
  LEFT JOIN top_dst td ON td.fk = k.fk
) r;
$$;

GRANT EXECUTE ON FUNCTION firm_flow_overview(int) TO authenticated;
