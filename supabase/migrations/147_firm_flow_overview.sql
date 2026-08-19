-- 147: 事務所異動總表（異動追蹤頁四表整併）
-- 把 firm_flow_ranking（跨所進出）、firm_intake_ranking（新血）、
-- firm_open_close（熄燈/新設/改名，mig 117+146）與名冊現有人數
-- full join 到同一個 firm_key，一所一列，前端做單表篩選/排序。
-- 團隊出走矩陣（firm_flow_matrix，邊資料）不併入，維持獨立卡。
-- 舊 RPC 不拆除：總覽頁快照仍用 firm_flow_ranking。
--
-- 欄位口徑（全部累積、分所歸戶，同 083）：
--   in_firm  = 跨所轉入（firm→firm，同 key 分所調動不計）
--   other_in = 由非事務所轉入（企業/公職/未登錄 → 本所）
--   intake   = 新血（new_lawyer 首次掛號進本所）
--   out_firm = 跨所轉出
--   other_out= 轉往非事務所 ＋ 執業狀態轉非正常（停職/未執業/名冊查無）
--   net      = in_firm + other_in + intake - out_firm - other_out
--   status   = closed_shutdown/closed_unlisted/closed_merge/closed_rename
--            / opened_new/opened_rename/opened_merger / normal
--     （同時新設又歸零者取 closed_*，opened_at 仍帶出）
--   top_src / top_dst = 最大單一來源所 / 去向所（配對人數）
--   last_at  = 該所最近一筆異動日
-- SECURITY DEFINER 同 117/146（authenticated 逐列 RLS 會超時）。

CREATE OR REPLACE FUNCTION firm_flow_overview()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
WITH oc AS (SELECT firm_open_close() AS j),
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
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change'
    AND flow_is_firm(old_office) AND flow_is_firm(new_office)
    AND flow_firm_key(old_office) IS DISTINCT FROM flow_firm_key(new_office)
), fin AS (
  SELECT dst AS fk, count(*)::int AS n, max(changed_at) AS last_at FROM mv GROUP BY 1
), fout AS (
  SELECT src AS fk, count(*)::int AS n, max(changed_at) AS last_at FROM mv GROUP BY 1
), oth_in AS (
  SELECT flow_firm_key(new_office) AS fk, count(*)::int AS n, max(changed_at) AS last_at
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change' AND flow_is_firm(new_office) AND NOT flow_is_firm(old_office)
  GROUP BY 1
), oth_out AS (
  SELECT fk, count(*)::int AS n, max(la) AS last_at FROM (
    SELECT flow_firm_key(old_office) AS fk, changed_at AS la
    FROM moj_lawyer_changes
    WHERE change_type = 'firm_change' AND flow_is_firm(old_office) AND NOT flow_is_firm(new_office)
    UNION ALL
    SELECT flow_firm_key(l.office_normalized), c.changed_at
    FROM moj_lawyer_changes c
    JOIN moj_lawyers l USING (lic_no)
    WHERE c.change_type = 'state_change' AND c.new_state IS DISTINCT FROM '正常'
      AND flow_is_firm(l.office_normalized)
  ) t GROUP BY 1
), nk AS (
  SELECT flow_firm_key(new_office) AS fk, count(*)::int AS n, max(changed_at) AS last_at
  FROM moj_lawyer_changes
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
  UNION SELECT fk FROM closed UNION SELECT fk FROM opened
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

GRANT EXECUTE ON FUNCTION firm_flow_overview() TO authenticated;
