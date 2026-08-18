-- 146: 事務所熄燈 / 新設 — 改名與整併判定（延伸 117 firm_open_close）
-- 問題：整所改名會同時進「熄燈」（舊名歸零）與「新設」（新名首見）兩表，
--   101 所熄燈中實測 30 所是改名、29 所是被併入既有所，真熄燈僅 42 所。
--
-- 判定：對每個歸零所取「流失律師的最大單一去向」（firm_change old→new 聚合），
--   若該去向人數 ÷ 流失人數 >= RENAME_MIN_SHARE(0.6) 且去向所目前仍有在職律師：
--     去向所本身是新設所 → kind='rename' （換招牌：舊名關、新名開）
--     去向所是既有所     → kind='merge'  （招牌消失但律師被既有所吸收）
--   其餘再看流失去向：>=60% 轉往「未登錄」（名冊空白／「律師未顯示」）
--     → kind='unlisted'（招牌未必消失，只是名冊不再揭示所名，不能當熄燈）
--   剩下才是 kind='shutdown'（真熄燈：名冊查無／停職／未執業／去向分散解散）
--   日期不另設門檻——同一批 firm_change 事件的時間天然相近，
--   加日期窗只會漏掉分批搬遷（如博欽 5 人分 18 天搬完）。
--
-- 新設側對稱標記：來源所（送進 >=60% 律師的歸零所）記入 from_firms，
--   kind='rename'（單一來源＝換招牌）/ 'merger'（多來源＝小所整併）/ 'new'（真新設）。

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
), opened AS (
  SELECT o.firm_key, o.opened_at, o.joined, o.active_n, o.names,
         CASE
           WHEN s.from_firms IS NULL THEN 'new'
           WHEN array_length(s.from_firms, 1) = 1 THEN 'rename'
           ELSE 'merger'
         END AS kind,
         coalesce(s.from_firms, '{}') AS from_firms
  FROM opened_base o
  LEFT JOIN src_of_opened s ON s.firm_key = o.firm_key
)
SELECT json_build_object(
  'closed', (SELECT coalesce(json_agg(row_to_json(c) ORDER BY c.closed_at DESC, c.departed DESC), '[]'::json) FROM closed c),
  'opened', (SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.opened_at DESC, o.joined DESC), '[]'::json) FROM opened o)
);
$$;

GRANT EXECUTE ON FUNCTION firm_open_close() TO authenticated;
