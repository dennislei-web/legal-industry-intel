-- 293: firm_open_close 加「拆夥重組」（熄燈側）與「重組新設」（新設側）（延伸 235／292，2026-11-23）
-- 前置：292（所名更正 name_fix）。這支以 292 的函式為底再加規則，套用順序必須是 292 → 293；
--   之後若重套 292，會把這支的規則蓋掉，要接著重套 293。
-- 問題：一家所拆夥、過半的人另組新所，但沒到 60% 整批轉移門檻時，兩邊都判錯：
--   熄燈側：最大去向 50%～60% → 落到 'shutdown'（收掉），看不出多數人其實在新所重組。
--   新設側：235 的分家判定要求來源所「仍有在職律師」，來源所後來歸零就失效，
--           新所退回用 from_firms（只收送來 >=60% 的歸零所）判定，主體來源反而不見，
--           被幾家 1 人歸零所搶走來源，標成 'merger'（合併新設）。
-- 判定：
--   熄燈側 kind='breakup'（拆夥重組）：歸零所不符合 rename／merge（最大去向未達 60%），
--     但最大單一去向 ① 是追蹤期內新設的所 ② 目前仍有在職律師 ③ 收了 >= 2 人 ④ 佔離開者 >= 50%。
--     dest_firm／dest_moved 比照 rename／merge 帶出去向。去向是既有所的 50%～60% 維持 'shutdown'。
--   新設側 kind='regroup'（重組新設）：新設所的最大單一來源 ① 搬來 >= 2 人 ② 佔新所 joined >= 50%
--     ③ 來源所已歸零 ④ 來源所不在 from_firms（沒到 60% 整批轉入；到了就照舊判 rename／merger）。
--     split_from／split_moved 帶出主體來源，split_src_left = 0 表示來源所已歸零。
--   'spinoff' 不變（來源所仍有在職律師）。
-- 下游：firm_flow_overview 的 status 會多出 closed_breakup／opened_regroup（前端 OV_STATUS 要有對應）；
--   industry_watch_metrics／details 的 by_kind 與明細自動帶新 kind；
--   firm_turnover_stats 只把 rename／merge 視同內部轉換，breakup 的離開者照算離職（不動）。

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
         CASE WHEN k.kind IN ('rename','merge','breakup') THEN d.dst END AS dest_firm,
         CASE WHEN k.kind IN ('rename','merge','breakup') THEN d.moved END AS dest_moved,
         (k.kind = 'rename' AND nf.same) AS name_fix
  FROM closed_base c
  LEFT JOIN main_dest d ON d.src = c.firm_key
  LEFT JOIN roster r ON r.fk = d.dst
  LEFT JOIN opened_base o ON o.firm_key = d.dst
  LEFT JOIN unlisted_moves u ON u.src = c.firm_key
  -- 所名更正（292）：新舊所名幾乎相同；個人所加入別人的所（舊所以本人命名、去向另有他人）不算
  CROSS JOIN LATERAL (SELECT coalesce(
      d.dst IS NOT NULL AND flow_same_name(c.firm_key, d.dst)
      AND NOT (flow_name_stem(c.firm_key) = ANY (c.names) AND coalesce(r.active_n, 0) >= 2), false) AS same) nf
  CROSS JOIN LATERAL (SELECT CASE
    WHEN d.dst IS NOT NULL AND d.moved::numeric / c.departed >= 0.6 AND coalesce(r.active_n, 0) > 0
      THEN CASE WHEN o.firm_key IS NOT NULL OR nf.same THEN 'rename' ELSE 'merge' END
    -- 拆夥重組：沒到整批轉移門檻，但過半的人（且至少 2 人）在同一家新設所重組
    WHEN d.dst IS NOT NULL AND o.firm_key IS NOT NULL AND coalesce(r.active_n, 0) > 0
         AND d.moved >= 2 AND d.moved::numeric / c.departed >= 0.5
      THEN 'breakup'
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
  -- 主體來源：最大單一來源搬來 >= 2 人且佔新所 >= 50%；src_left = 來源所目前在職人數（0＝已歸零）
  SELECT t.firm_key, t.src AS split_from, t.moved AS split_moved, coalesce(r.active_n, 0) AS split_src_left
  FROM top_src_all t
  JOIN opened_base o ON o.firm_key = t.firm_key
  LEFT JOIN roster r ON r.fk = t.src
  WHERE t.moved >= 2 AND t.moved::numeric / o.joined >= 0.5
), opened AS (
  SELECT o.firm_key, o.opened_at, o.joined, o.active_n, o.names, k.kind,
         coalesce(s.from_firms, '{}') AS from_firms,
         CASE WHEN k.kind IN ('spinoff','regroup') THEN sp.split_from END AS split_from,
         CASE WHEN k.kind IN ('spinoff','regroup') THEN sp.split_moved END AS split_moved,
         CASE WHEN k.kind IN ('spinoff','regroup') THEN sp.split_src_left END AS split_src_left
  FROM opened_base o
  LEFT JOIN src_of_opened s ON s.firm_key = o.firm_key
  LEFT JOIN spin sp ON sp.firm_key = o.firm_key
  CROSS JOIN LATERAL (SELECT CASE
    -- 這個所名本身是後來被更正掉的錯字所名，不是新開的所（292）
    WHEN EXISTS (SELECT 1 FROM closed cx WHERE cx.firm_key = o.firm_key AND cx.name_fix) THEN 'rename'
    WHEN sp.firm_key IS NOT NULL AND sp.split_src_left > 0 THEN 'spinoff'
    -- 重組新設：主體來源已歸零，且不是整批轉入（整批轉入照舊走 rename／merger）
    WHEN sp.firm_key IS NOT NULL AND NOT (sp.split_from = ANY (coalesce(s.from_firms, '{}'))) THEN 'regroup'
    WHEN s.from_firms IS NULL THEN 'new'
    WHEN array_length(s.from_firms, 1) = 1 THEN 'rename'
    ELSE 'merger' END AS kind) k
)
SELECT json_build_object(
  'closed', (SELECT coalesce(json_agg(row_to_json(c) ORDER BY c.closed_at DESC, c.departed DESC), '[]'::json) FROM closed c),
  'opened', (SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.opened_at DESC, o.joined DESC), '[]'::json) FROM opened o)
);
$$;

GRANT EXECUTE ON FUNCTION firm_open_close() TO authenticated;
