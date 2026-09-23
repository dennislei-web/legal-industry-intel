-- 235: firm_open_close 新設側加「分家」判定（延伸 146）
-- 問題：146 的 from_firms 只收「歸零所」，原所仍留人的出走（分家）看不到。
--   例：宸信 6 人中 4 人來自維欣聯合（原 5 人、留 1 人），卻被判「整併而來」
--   （高永穎、齊盈各 1 人歸零）；安律國際 5 人全來自安侯（仍有 7 人）被判「新設」。
-- 判定：新設所的最大單一來源（所對所，含歸零所一起比）若
--   ① 該來源目前仍有在職律師（未歸零）② 搬來 >= 2 人 ③ 佔新所 joined >= 50%
--   → kind='spinoff'（分家而來），優先於 rename/merger/new。
--   新增欄位 split_from / split_moved / split_src_left；from_firms 維持原義（歸零來源）。

CREATE OR REPLACE FUNCTION firm_open_close()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
WITH incoming AS (
  SELECT lic_no, flow_firm_key(new_office) AS fk, changed_at
  FROM moj_lawyer_changes
  WHERE change_type IN ('firm_change','new_lawyer') AND flow_is_firm(new_office)
), outgoing AS (
  SELECT lic_no, name, flow_firm_key(old_office) AS fk, changed_at
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change' AND flow_is_firm(old_office)
), roster AS (
  SELECT flow_firm_key(office_normalized) AS fk,
         count(*) FILTER (WHERE state_desc = '正常' AND deregistered_at IS NULL)::int AS active_n
  FROM moj_lawyers
  WHERE flow_is_firm(office_normalized)
  GROUP BY 1
), losses AS (
  SELECT fk, lic_no, name, changed_at FROM outgoing
  UNION ALL
  SELECT flow_firm_key(l.office_normalized), c.lic_no, c.name, c.changed_at
  FROM moj_lawyer_changes c
  JOIN moj_lawyers l USING (lic_no)
  WHERE c.change_type = 'state_change'
    AND c.new_state IS DISTINCT FROM '正常'
    AND flow_is_firm(l.office_normalized)
), closed_base AS (
  SELECT lo.fk AS firm_key,
         max(lo.changed_at)::date AS closed_at,
         count(DISTINCT lo.lic_no)::int AS departed,
         (array_agg(DISTINCT lo.name))[1:6] AS names
  FROM losses lo
  LEFT JOIN roster r ON r.fk = lo.fk
  WHERE coalesce(r.active_n, 0) = 0
  GROUP BY lo.fk
), cand AS (
  SELECT fk, min(changed_at)::date AS opened_at, count(DISTINCT lic_no)::int AS joined
  FROM incoming GROUP BY fk
), pre_exist AS (
  SELECT DISTINCT flow_firm_key(l.office_normalized) AS fk
  FROM moj_lawyers l
  JOIN cand ON cand.fk = flow_firm_key(l.office_normalized)
  WHERE flow_is_firm(l.office_normalized)
    AND NOT EXISTS (SELECT 1 FROM incoming i
                    WHERE i.lic_no = l.lic_no AND i.fk = flow_firm_key(l.office_normalized))
  UNION
  SELECT DISTINCT o.fk
  FROM outgoing o
  JOIN cand ON cand.fk = o.fk
  WHERE NOT EXISTS (SELECT 1 FROM incoming i
                    WHERE i.lic_no = o.lic_no AND i.fk = o.fk AND i.changed_at < o.changed_at)
), mem AS (
  SELECT flow_firm_key(office_normalized) AS fk,
         (array_agg(name ORDER BY name))[1:6] AS names
  FROM moj_lawyers
  WHERE flow_is_firm(office_normalized) AND state_desc = '正常' AND deregistered_at IS NULL
  GROUP BY 1
), opened_base AS (
  SELECT c.fk AS firm_key, c.opened_at, c.joined,
         coalesce(r.active_n, 0) AS active_n,
         coalesce(m.names, '{}') AS names
  FROM cand c
  LEFT JOIN roster r ON r.fk = c.fk
  LEFT JOIN mem m ON m.fk = c.fk
  WHERE NOT EXISTS (SELECT 1 FROM pre_exist p WHERE p.fk = c.fk)
), moves AS (
  -- 所對所的整批搬遷量（僅事務所→事務所，未登錄去向不計入分子）
  SELECT flow_firm_key(old_office) AS src, flow_firm_key(new_office) AS dst,
         count(DISTINCT lic_no)::int AS moved
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change' AND flow_is_firm(old_office) AND flow_is_firm(new_office)
  GROUP BY 1, 2
), unlisted_moves AS (
  -- 流向「未登錄」（office 空白或「律師未顯示」等非事務所字串）的人數
  SELECT flow_firm_key(old_office) AS src, count(DISTINCT lic_no)::int AS gone_unlisted
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change' AND flow_is_firm(old_office) AND NOT flow_is_firm(new_office)
  GROUP BY 1
), main_dest AS (
  -- 每個歸零所的最大單一去向；平手時取名稱序（determinism）
  SELECT DISTINCT ON (m.src) m.src, m.dst, m.moved
  FROM moves m JOIN closed_base c ON c.firm_key = m.src
  ORDER BY m.src, m.moved DESC, m.dst
), closed AS (
  SELECT c.firm_key, c.closed_at, c.departed, c.names, k.kind,
         CASE WHEN k.kind IN ('rename','merge') THEN d.dst END AS dest_firm,
         CASE WHEN k.kind IN ('rename','merge') THEN d.moved END AS dest_moved
  FROM closed_base c
  LEFT JOIN main_dest d ON d.src = c.firm_key
  LEFT JOIN roster r ON r.fk = d.dst
  LEFT JOIN opened_base o ON o.firm_key = d.dst
  LEFT JOIN unlisted_moves u ON u.src = c.firm_key
  CROSS JOIN LATERAL (SELECT CASE
    WHEN d.dst IS NOT NULL AND d.moved::numeric / c.departed >= 0.6 AND coalesce(r.active_n, 0) > 0
      THEN CASE WHEN o.firm_key IS NOT NULL THEN 'rename' ELSE 'merge' END
    WHEN coalesce(u.gone_unlisted, 0)::numeric / c.departed >= 0.6 THEN 'unlisted'
    ELSE 'shutdown' END AS kind) k
), src_of_opened AS (
  -- 新設所的來源：把 >=60% 律師送進來的歸零所
  SELECT d.dst AS firm_key, array_agg(d.src ORDER BY d.moved DESC, d.src) AS from_firms
  FROM main_dest d
  JOIN closed_base c ON c.firm_key = d.src
  WHERE d.moved::numeric / c.departed >= 0.6
  GROUP BY d.dst
), top_src_all AS (
  -- 每個新設所的最大單一來源（跨所搬遷，不限歸零所）
  SELECT DISTINCT ON (m.dst) m.dst AS firm_key, m.src, m.moved
  FROM moves m JOIN opened_base o ON o.firm_key = m.dst
  WHERE m.src IS DISTINCT FROM m.dst
  ORDER BY m.dst, m.moved DESC, m.src
), spin AS (
  SELECT t.firm_key, t.src AS split_from, t.moved AS split_moved, r.active_n AS split_src_left
  FROM top_src_all t
  JOIN opened_base o ON o.firm_key = t.firm_key
  JOIN roster r ON r.fk = t.src
  WHERE r.active_n > 0 AND t.moved >= 2 AND t.moved::numeric / o.joined >= 0.5
), opened AS (
  SELECT o.firm_key, o.opened_at, o.joined, o.active_n, o.names,
         CASE
           WHEN sp.firm_key IS NOT NULL THEN 'spinoff'
           WHEN s.from_firms IS NULL THEN 'new'
           WHEN array_length(s.from_firms, 1) = 1 THEN 'rename'
           ELSE 'merger'
         END AS kind,
         coalesce(s.from_firms, '{}') AS from_firms,
         sp.split_from, sp.split_moved, sp.split_src_left
  FROM opened_base o
  LEFT JOIN src_of_opened s ON s.firm_key = o.firm_key
  LEFT JOIN spin sp ON sp.firm_key = o.firm_key
)
SELECT json_build_object(
  'closed', (SELECT coalesce(json_agg(row_to_json(c) ORDER BY c.closed_at DESC, c.departed DESC), '[]'::json) FROM closed c),
  'opened', (SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.opened_at DESC, o.joined DESC), '[]'::json) FROM opened o)
);
$$;

GRANT EXECUTE ON FUNCTION firm_open_close() TO authenticated;
