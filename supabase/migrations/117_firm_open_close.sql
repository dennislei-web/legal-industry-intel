-- 117: 事務所關閉 / 新設偵測（異動追蹤頁）
-- 資料源：moj_lawyer_changes（2026-07-03 起追蹤）＋ moj_lawyers 現況名冊
-- 口徑：firm_key = flow_firm_key()（截到第一個 法律/律師事務所，分所歸戶，同 083）
--
-- 關閉（closed）＝ 追蹤期間曾有在籍律師流失（轉所 / 停業 / 除名），
--   且該所目前「正常且未除名」律師數 = 0；歸零日 = 最後一筆流失異動。
--   注意：追蹤前就空掉的所不會出現（無異動紀錄可回溯）。
-- 新設（opened）＝ 追蹤起始後才首次出現的所：
--   (1) 出現在轉入紀錄（firm_change / new_lawyer 的 new_office），且
--   (2) 沒有任何律師是「追蹤前就在籍」——現職成員全都有轉入紀錄、
--       曾離開者離開前也都有轉入紀錄。
--   新設所之後又歸零者 active_n = 0（前端標「已再歸零」），同時也會進 closed。
--
-- 2026-08-18 修訂：改 SECURITY DEFINER（比照 moj_firm_statistics 048/065）。
--   原版以呼叫者身分跑，authenticated 角色下 moj_lawyers 全表掃描逐列過 RLS
--   （auth.uid() 檢查）→ 超過 statement timeout；EXECUTE 僅授 authenticated，
--   回傳內容本就是登入可讀的名冊聚合，無新資料暴露。

CREATE OR REPLACE FUNCTION firm_open_close()
RETURNS json
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
  -- 轉所離開
  SELECT fk, lic_no, name, changed_at FROM outgoing
  UNION ALL
  -- 停業 / 除名（office 不變，歸到其名冊上的所）
  SELECT flow_firm_key(l.office_normalized), c.lic_no, c.name, c.changed_at
  FROM moj_lawyer_changes c
  JOIN moj_lawyers l USING (lic_no)
  WHERE c.change_type = 'state_change'
    AND c.new_state IS DISTINCT FROM '正常'
    AND flow_is_firm(l.office_normalized)
), closed AS (
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
  -- 現職成員中有人無轉入紀錄 = 追蹤前就在籍
  SELECT DISTINCT flow_firm_key(l.office_normalized) AS fk
  FROM moj_lawyers l
  JOIN cand ON cand.fk = flow_firm_key(l.office_normalized)
  WHERE flow_is_firm(l.office_normalized)
    AND NOT EXISTS (SELECT 1 FROM incoming i
                    WHERE i.lic_no = l.lic_no AND i.fk = flow_firm_key(l.office_normalized))
  UNION
  -- 曾離開者離開前無轉入紀錄 = 追蹤前就在籍
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
), opened AS (
  SELECT c.fk AS firm_key, c.opened_at, c.joined,
         coalesce(r.active_n, 0) AS active_n,
         coalesce(m.names, '{}') AS names
  FROM cand c
  LEFT JOIN roster r ON r.fk = c.fk
  LEFT JOIN mem m ON m.fk = c.fk
  WHERE NOT EXISTS (SELECT 1 FROM pre_exist p WHERE p.fk = c.fk)
)
SELECT json_build_object(
  'closed', (SELECT coalesce(json_agg(row_to_json(c) ORDER BY c.closed_at DESC, c.departed DESC), '[]'::json) FROM closed c),
  'opened', (SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.opened_at DESC, o.joined DESC), '[]'::json) FROM opened o)
);
$$;

GRANT EXECUTE ON FUNCTION firm_open_close() TO authenticated;
