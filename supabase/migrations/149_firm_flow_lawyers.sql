-- 149: 單一事務所的律師級進出明細（異動總表下鑽用）
-- 給總表流入/流出/新血數字點擊展開：回該所（firm_key 歸戶）在窗內的
-- 逐人異動，五組與 firm_flow_overview 的計數欄一一對應，方便對帳。
-- other_out 的 kind 區分 move（轉往非事務所，other=原始去向字串）
-- 與 state（停業/註銷等，other=新狀態）。p_days 同 148（0=全部）。

CREATE OR REPLACE FUNCTION firm_flow_lawyers(p_firm text, p_days int DEFAULT 0)
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
WITH win AS (
  SELECT * FROM moj_lawyer_changes
  WHERE p_days <= 0 OR changed_at >= now() - make_interval(days => p_days)
), in_firm AS (
  SELECT name, flow_firm_key(old_office) AS other, changed_at::date AS at
  FROM win
  WHERE change_type = 'firm_change' AND flow_is_firm(new_office) AND flow_firm_key(new_office) = p_firm
    AND flow_is_firm(old_office) AND flow_firm_key(old_office) IS DISTINCT FROM p_firm
), other_in AS (
  SELECT name, old_office AS other, changed_at::date AS at
  FROM win
  WHERE change_type = 'firm_change' AND flow_is_firm(new_office) AND flow_firm_key(new_office) = p_firm
    AND NOT flow_is_firm(old_office)
), intake AS (
  SELECT name, changed_at::date AS at
  FROM win
  WHERE change_type = 'new_lawyer' AND flow_is_firm(new_office) AND flow_firm_key(new_office) = p_firm
), out_firm AS (
  SELECT name, flow_firm_key(new_office) AS other, changed_at::date AS at
  FROM win
  WHERE change_type = 'firm_change' AND flow_is_firm(old_office) AND flow_firm_key(old_office) = p_firm
    AND flow_is_firm(new_office) AND flow_firm_key(new_office) IS DISTINCT FROM p_firm
), other_out AS (
  SELECT name, new_office AS other, 'move' AS kind, changed_at::date AS at
  FROM win
  WHERE change_type = 'firm_change' AND flow_is_firm(old_office) AND flow_firm_key(old_office) = p_firm
    AND NOT flow_is_firm(new_office)
  UNION ALL
  SELECT c.name, c.new_state, 'state', c.changed_at::date
  FROM win c
  JOIN moj_lawyers l USING (lic_no)
  WHERE c.change_type = 'state_change' AND c.new_state IS DISTINCT FROM '正常'
    AND flow_is_firm(l.office_normalized) AND flow_firm_key(l.office_normalized) = p_firm
)
SELECT json_build_object(
  'in_firm',   (SELECT coalesce(json_agg(row_to_json(t) ORDER BY t.at DESC, t.name), '[]'::json) FROM in_firm t),
  'other_in',  (SELECT coalesce(json_agg(row_to_json(t) ORDER BY t.at DESC, t.name), '[]'::json) FROM other_in t),
  'intake',    (SELECT coalesce(json_agg(row_to_json(t) ORDER BY t.at DESC, t.name), '[]'::json) FROM intake t),
  'out_firm',  (SELECT coalesce(json_agg(row_to_json(t) ORDER BY t.at DESC, t.name), '[]'::json) FROM out_firm t),
  'other_out', (SELECT coalesce(json_agg(row_to_json(t) ORDER BY t.at DESC, t.name), '[]'::json) FROM other_out t)
);
$$;

GRANT EXECUTE ON FUNCTION firm_flow_lawyers(text, int) TO authenticated;
