-- 291：產業觀察報告加「指標明細」（2026-11-22）
-- 需求：比較頁只有數字（熄燈 6 家、名冊轉非正常 12 人…），點指標要能看到是哪幾家事務所、哪些律師。
-- 做法：產報告當下把每個指標的明細名單一起存進 industry_watch_reports.details（{指標 key: [物件…]}），
--   之後名冊再變動，明細仍和當期數字對得上（firm_open_close() 是即時函式，事後回查家數會飄）。
--   前端點指標時才單獨讀這一欄（不跟列表一起載）。表本身 RLS＝is_intel_admin()，明細同樣只有 admin 讀得到。
-- industry_watch_details(p_start, p_end)：口徑逐項對齊 mig 273 industry_watch_metrics（同一個期間、同樣的篩選），
--   只給 service_role，由 scripts/industry_watch_report.py 呼叫。
-- 注意：repo 公開，這支只定義怎麼取，不含任何人名／所名。

ALTER TABLE industry_watch_reports ADD COLUMN IF NOT EXISTS details jsonb;
COMMENT ON COLUMN industry_watch_reports.details IS '指標明細名單 {metric_key: [..]}，產報告當下由 industry_watch_details() 取得並凍結（mig 291）';

CREATE OR REPLACE FUNCTION industry_watch_details(p_start date, p_end date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $$
DECLARE
  v_cs   date := greatest(p_start, date '2026-07-27');   -- 異動乾淨起點（同 mig 273）
  v_res  jsonb;
  v_snap_end text;
  v_snap_beg text;
BEGIN
  SELECT max(snapshot_month) INTO v_snap_end FROM firm_headcount_snapshots WHERE snapshot_month <= to_char(p_end,'YYYY-MM');
  SELECT max(snapshot_month) INTO v_snap_beg FROM firm_headcount_snapshots WHERE snapshot_month <  to_char(p_start,'YYYY-MM');

  WITH ch AS (
    SELECT c.*, (c.changed_at AT TIME ZONE 'Asia/Taipei')::date AS d
      FROM moj_lawyer_changes c
     WHERE c.changed_at >= (v_cs::timestamp AT TIME ZONE 'Asia/Taipei')
       AND c.changed_at <  ((p_end + 1)::timestamp AT TIME ZONE 'Asia/Taipei')
  ), mv AS (
    SELECT d, name, flow_firm_key(old_office) AS from_k, flow_firm_key(new_office) AS to_k
      FROM ch
     WHERE change_type='firm_change' AND flow_is_firm(old_office) AND flow_is_firm(new_office)
       AND flow_firm_key(old_office) IS DISTINCT FROM flow_firm_key(new_office)
  ), oc AS (
    SELECT to_jsonb(t) AS j FROM firm_open_close() t
  ), opened AS (
    SELECT e FROM oc, jsonb_array_elements(oc.j->'opened') e
     WHERE (e->>'opened_at')::date BETWEEN v_cs AND p_end AND e->>'kind' <> 'rename'
  ), closed AS (
    SELECT e FROM oc, jsonb_array_elements(oc.j->'closed') e
     WHERE (e->>'closed_at')::date BETWEEN v_cs AND p_end AND e->>'kind' <> 'rename'
  )
  SELECT jsonb_build_object(
    '_meta', jsonb_build_object('start', p_start, 'end', p_end, 'changes_from', v_cs,
                                'snap_end', v_snap_end, 'snap_begin', v_snap_beg, 'built_at', now()),
    -- 事務所
    'closed', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'firm', e->>'firm_key', 'kind', e->>'kind', 'd', e->>'closed_at', 'n', (e->>'departed')::int,
                  'dest', e->>'dest_firm', 'names', e->'names')
                ORDER BY (e->>'departed')::int DESC, e->>'firm_key'), '[]'::jsonb) FROM closed),
    'opened', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'firm', e->>'firm_key', 'kind', e->>'kind', 'd', e->>'opened_at', 'n', (e->>'active_n')::int,
                  'split_from', e->>'split_from', 'from_firms', e->'from_firms', 'names', e->'names')
                ORDER BY (e->>'active_n')::int DESC, e->>'firm_key'), '[]'::jsonb) FROM opened),
    -- 人才流動
    'firm_to_firm', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'name', name, 'from', from_k, 'to', to_k)
                ORDER BY d, from_k, name), '[]'::jsonb) FROM mv),
    'entering', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'name', name, 'from', old_office, 'to', flow_firm_key(new_office))
                ORDER BY d, name), '[]'::jsonb)
                FROM ch WHERE change_type='firm_change' AND NOT flow_is_firm(old_office) AND flow_is_firm(new_office) AND coalesce(old_office,'') <> ''),
    'leaving', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'name', name, 'from', flow_firm_key(old_office), 'to', nullif(btrim(new_office), ''))
                ORDER BY d, name), '[]'::jsonb)
                FROM ch WHERE change_type='firm_change' AND flow_is_firm(old_office) AND NOT flow_is_firm(new_office)),
    'team_moves', (SELECT coalesce(jsonb_agg(jsonb_build_object('from', from_k, 'to', to_k, 'n', n, 'names', names) ORDER BY n DESC, from_k), '[]'::jsonb) FROM (
                SELECT from_k, to_k, count(*)::int AS n, jsonb_agg(name ORDER BY name) AS names FROM mv GROUP BY 1,2 HAVING count(*) >= 3) t),
    -- 喆律（與腳本 build_metrics 的判定一致：新單位含喆律且原單位不含＝轉入／新進；反之＝轉出）
    'zhelu_in', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'name', name, 'type', change_type, 'from', old_office, 'to', new_office) ORDER BY d, name), '[]'::jsonb)
                FROM ch WHERE change_type IN ('firm_change','new_lawyer')
                 AND coalesce(new_office,'') LIKE '%喆律%' AND coalesce(old_office,'') NOT LIKE '%喆律%'),
    'zhelu_out', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'name', name, 'type', change_type, 'from', old_office, 'to', new_office) ORDER BY d, name), '[]'::jsonb)
                FROM ch WHERE change_type IN ('firm_change','new_lawyer')
                 AND coalesce(old_office,'') LIKE '%喆律%' AND coalesce(new_office,'') NOT LIKE '%喆律%'),
    -- 供給
    'new_lawyers', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', d, 'name', name, 'office', nullif(btrim(new_office), '')) ORDER BY d, new_office, name), '[]'::jsonb)
                FROM ch WHERE change_type='new_lawyer'),
    'state_removed', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', ch.d, 'name', ch.name, 'office', nullif(btrim(l.office_normalized), ''),
                                                                   'old_state', ch.old_state, 'new_state', ch.new_state) ORDER BY ch.d, ch.name), '[]'::jsonb)
                FROM ch LEFT JOIN moj_lawyers l ON l.lic_no = ch.lic_no
               WHERE ch.change_type='state_change' AND coalesce(ch.old_state,'')='正常' AND coalesce(ch.new_state,'')<>'正常'),
    'discipline', (SELECT coalesce(jsonb_agg(jsonb_build_object('d', ch.d, 'name', ch.name, 'office', nullif(btrim(l.office_normalized), ''),
                                                                'before', moj_disc_text(ch.old_discipline), 'after', moj_disc_text(ch.new_discipline)) ORDER BY ch.d, ch.name), '[]'::jsonb)
                FROM ch LEFT JOIN moj_lawyers l ON l.lic_no = ch.lic_no
               WHERE ch.change_type='discipline_change'),
    -- 規模級距（月快照；prev_n＝期初快照同一家的人數，沒有＝期初不在快照）
    'firms_30plus', (SELECT coalesce(jsonb_agg(jsonb_build_object('firm', e.firm_key, 'n', e.lawyer_n, 'prev_n', b.lawyer_n) ORDER BY e.lawyer_n DESC, e.firm_key), '[]'::jsonb)
                FROM firm_headcount_snapshots e
                LEFT JOIN firm_headcount_snapshots b ON b.snapshot_month = v_snap_beg AND b.firm_key = e.firm_key
               WHERE e.snapshot_month = v_snap_end AND e.is_firm AND e.lawyer_n >= 30),
    'firms_10_29', (SELECT coalesce(jsonb_agg(jsonb_build_object('firm', e.firm_key, 'n', e.lawyer_n, 'prev_n', b.lawyer_n) ORDER BY e.lawyer_n DESC, e.firm_key), '[]'::jsonb)
                FROM firm_headcount_snapshots e
                LEFT JOIN firm_headcount_snapshots b ON b.snapshot_month = v_snap_beg AND b.firm_key = e.firm_key
               WHERE e.snapshot_month = v_snap_end AND e.is_firm AND e.lawyer_n BETWEEN 10 AND 29)
  ) INTO v_res;
  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION industry_watch_details(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION industry_watch_details(date, date) TO service_role;
