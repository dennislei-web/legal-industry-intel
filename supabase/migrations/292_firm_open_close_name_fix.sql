-- 292: firm_open_close 加「所名更正」判定（延伸 146／235，2026-11-23）
-- 問題：名冊把所名打錯再更正（形近字、法律／律師互換、補上「國際」等），舊所名歸零、律師「轉往」正確所名，
--   去向是既有所 → 被判成 kind='merge'（併入他所），算進熄燈家數；實際上是同一家所，沒有任何事務所關門。
--   實測 6 件（其中 4 件落在產業觀察報告期間內，影響 6 份報告的熄燈數）。
-- 判定：歸零所的最大單一去向（>=60%、去向仍有在職律師，同 146）若「所名幾乎相同」→ kind='rename'、name_fix=true。
--   幾乎相同＝去掉通用字（法律／律師／聯合／國際／商務／事務所，含常見錯字）後的字號
--     ① 完全相同，或 ② 等長（>=2 字）且只差一個字。
--   只比對「同一批律師真的從 A 轉到 B」的配對，不做全名冊的所名相似比對——人名所彼此只差一字的組合有上百組，
--   全面比對一定誤判。
--   排除：舊所是以離開律師本人命名的個人所、去向所另有他人（>=2 人）＝個人所加入別人的所，不算更正。
-- 新設側：這種錯字所名若是追蹤期間才出現（新進律師一登錄就打錯），原本會算一家「新設」→ 同樣標 rename 不計。
-- 下游：kind 沿用既有的 rename，industry_watch_metrics／industry_watch_details／firm_flow_overview／firm_turnover_stats
--   都不用改（熄燈家數本來就排除 rename）。closed 多一個欄位 name_fix 供辨識。
-- 注意：repo 公開，這支只定義規則，不含任何人名／所名。

-- 所名字號：去掉通用字後剩下的部分（只用於「幾乎同名」比對，不是歸戶鍵）
CREATE OR REPLACE FUNCTION flow_name_stem(fk text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(coalesce(fk, ''), '(法律|律師|法侓|法津|聯合|國際|商務|事務所|[[:space:]])', '', 'g');
$$;

-- 兩個所名是否幾乎相同（字號相同，或等長且只差一字）
CREATE OR REPLACE FUNCTION flow_same_name(a text, b text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN s.sa = '' OR s.sb = '' THEN false
    WHEN s.sa = s.sb THEN true
    WHEN char_length(s.sa) = char_length(s.sb) AND char_length(s.sa) >= 2 THEN
      (SELECT count(*) FROM generate_series(1, char_length(s.sa)) i
        WHERE substr(s.sa, i, 1) <> substr(s.sb, i, 1)) = 1
    ELSE false END
  FROM (SELECT flow_name_stem(a) AS sa, flow_name_stem(b) AS sb) s;
$$;

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
         CASE WHEN k.kind IN ('rename','merge') THEN d.moved END AS dest_moved,
         (k.kind = 'rename' AND nf.same) AS name_fix
  FROM closed_base c
  LEFT JOIN main_dest d ON d.src = c.firm_key
  LEFT JOIN roster r ON r.fk = d.dst
  LEFT JOIN opened_base o ON o.firm_key = d.dst
  LEFT JOIN unlisted_moves u ON u.src = c.firm_key
  -- 所名更正：新舊所名幾乎相同；個人所加入別人的所（舊所以本人命名、去向另有他人）不算
  CROSS JOIN LATERAL (SELECT coalesce(
      d.dst IS NOT NULL AND flow_same_name(c.firm_key, d.dst)
      AND NOT (flow_name_stem(c.firm_key) = ANY (c.names) AND coalesce(r.active_n, 0) >= 2), false) AS same) nf
  CROSS JOIN LATERAL (SELECT CASE
    WHEN d.dst IS NOT NULL AND d.moved::numeric / c.departed >= 0.6 AND coalesce(r.active_n, 0) > 0
      THEN CASE WHEN o.firm_key IS NOT NULL OR nf.same THEN 'rename' ELSE 'merge' END
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
           -- 這個所名本身是後來被更正掉的錯字所名，不是新開的所
           WHEN EXISTS (SELECT 1 FROM closed cx WHERE cx.firm_key = o.firm_key AND cx.name_fix) THEN 'rename'
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
