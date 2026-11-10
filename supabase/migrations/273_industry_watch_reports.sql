-- 產業觀察定期報告（喆律戰情＞產業觀察，admin-only）
-- 每週／每月／每季／每年各產出一份，留存比較。
--   industry_watch_reports：一期一列（cadence＋period_key 唯一），sections＝報告內文、metrics＝可比較的扁平指標
--   industry_watch_metrics(p_start, p_end)：算一個期間的原始數字（只給 service_role，由 scripts/industry_watch_report.py 呼叫）
-- 資料口徑：
--   律師異動（moj_lawyer_changes）乾淨起點 2026-07-27，期間起日早於此一律截到 7/27
--   跨所移動／進入／離開沿用 mig 083 flow_firm_key／flow_is_firm（分所併本所、兩端非事務所的假異動自動排除）
--   規模快照＝firm_headcount_snapshots 月快照；裁判書案量＝firm_dedup_month_stats（所級去重、現任名冊回溯，滯後約 2 個月）

CREATE TABLE IF NOT EXISTS industry_watch_reports (
  id            bigserial PRIMARY KEY,
  cadence       text NOT NULL CHECK (cadence IN ('weekly','monthly','quarterly','yearly')),
  period_key    text NOT NULL,           -- weekly=結束日 2026-11-06、monthly=2026-10、quarterly=2026-Q3、yearly=2026
  period_start  date NOT NULL,
  period_end    date NOT NULL,
  title         text NOT NULL,
  summary       text,                    -- 一段話重點
  highlights    jsonb NOT NULL DEFAULT '[]'::jsonb,   -- 重點句陣列
  sections      jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{heading, note?, bullets?:[], table?:{cols:[],rows:[[]]}}]
  metrics       jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {key:{label,value,unit,group}} 供比較／趨勢
  raw           jsonb,                   -- industry_watch_metrics 原始輸出（除錯／重算用）
  generated_at  timestamptz NOT NULL DEFAULT now(),
  generator     text,
  UNIQUE (cadence, period_key)
);

ALTER TABLE industry_watch_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS industry_watch_reports_admin_read ON industry_watch_reports;
CREATE POLICY industry_watch_reports_admin_read ON industry_watch_reports
  FOR SELECT TO authenticated USING (public.is_intel_admin());
REVOKE ALL ON industry_watch_reports FROM anon;
GRANT SELECT ON industry_watch_reports TO authenticated;

CREATE OR REPLACE FUNCTION industry_watch_metrics(p_start date, p_end date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $$
DECLARE
  v_cs   date := greatest(p_start, date '2026-07-27');   -- 異動乾淨起點
  v_res  jsonb;
  v_yms  text[];
  v_snap_end text;
  v_snap_beg text;
BEGIN
  -- 裁判書月份：期間整段往前推 2 個月（司法院公開滯後約 2 個月，月報 10 月看 8 月、季報 Q3 看 5–7 月），
  -- 每期固定錯開才能前後期比較；推完仍沒有資料就取最新一個月
  SELECT array_agg(DISTINCT ym ORDER BY ym) INTO v_yms
    FROM firm_dedup_month_stats
   WHERE ym BETWEEN to_char(p_start - interval '2 months','YYYYMM')
                AND to_char(date_trunc('month', p_end) - interval '2 months','YYYYMM');
  IF v_yms IS NULL THEN
    SELECT ARRAY[max(ym)] INTO v_yms FROM firm_dedup_month_stats;
  END IF;

  SELECT max(snapshot_month) INTO v_snap_end FROM firm_headcount_snapshots WHERE snapshot_month <= to_char(p_end,'YYYY-MM');
  SELECT max(snapshot_month) INTO v_snap_beg FROM firm_headcount_snapshots WHERE snapshot_month <  to_char(p_start,'YYYY-MM');

  WITH ch AS (
    SELECT c.*, (c.changed_at AT TIME ZONE 'Asia/Taipei')::date AS d
      FROM moj_lawyer_changes c
     WHERE c.changed_at >= (v_cs::timestamp AT TIME ZONE 'Asia/Taipei')
       AND c.changed_at <  ((p_end + 1)::timestamp AT TIME ZONE 'Asia/Taipei')
  ), mv AS (
    SELECT name, flow_firm_key(old_office) AS from_k, flow_firm_key(new_office) AS to_k
      FROM ch
     WHERE change_type='firm_change' AND flow_is_firm(old_office) AND flow_is_firm(new_office)
       AND flow_firm_key(old_office) IS DISTINCT FROM flow_firm_key(new_office)
  ), net AS (
    SELECT fk, sum(i)::int AS moved_in, sum(o)::int AS moved_out, (sum(i)-sum(o))::int AS net FROM (
      SELECT to_k AS fk, 1 AS i, 0 AS o FROM mv UNION ALL SELECT from_k, 0, 1 FROM mv) z
     GROUP BY fk
  ), oc AS (
    SELECT to_jsonb(t) AS j FROM firm_open_close() t
  ), opened AS (
    SELECT e FROM oc, jsonb_array_elements(oc.j->'opened') e
     WHERE (e->>'opened_at')::date BETWEEN v_cs AND p_end
  ), closed AS (
    SELECT e FROM oc, jsonb_array_elements(oc.j->'closed') e
     WHERE (e->>'closed_at')::date BETWEEN v_cs AND p_end
  ), snap AS (
    SELECT snapshot_month,
           count(*) FILTER (WHERE is_firm) AS firms,
           sum(lawyer_n) FILTER (WHERE is_firm) AS lawyers,
           count(*) FILTER (WHERE is_firm AND lawyer_n = 1) AS s1,
           count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 2 AND 4) AS s2_4,
           count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 5 AND 9) AS s5_9,
           count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 10 AND 29) AS s10_29,
           count(*) FILTER (WHERE is_firm AND lawyer_n >= 30) AS s30
      FROM firm_headcount_snapshots
     WHERE snapshot_month IN (v_snap_end, v_snap_beg)
     GROUP BY snapshot_month
  ), jd AS (
    SELECT firm_key, sum(dedup_cases)::int AS cases
      FROM firm_dedup_month_stats
     WHERE ym = ANY(v_yms) AND firm_key LIKE '%事務所%'
     GROUP BY firm_key
  ), jr AS (
    SELECT firm_key, cases, rank() OVER (ORDER BY cases DESC) AS rk FROM jd
  ), rep AS (
    SELECT file_type, sum(n)::int AS n, sum(repped_n)::int AS repped
      FROM closed_case_amount_rep
     WHERE yyyymm = ANY(v_yms)
     GROUP BY file_type
  )
  SELECT jsonb_build_object(
    'period', jsonb_build_object('start', p_start, 'end', p_end, 'changes_from', v_cs),
    'lawyer_count', jsonb_build_object(
        'begin', (SELECT value FROM industry_stats WHERE stat_type='lawyer_count' AND created_at < (p_start::timestamp AT TIME ZONE 'Asia/Taipei') ORDER BY created_at DESC LIMIT 1),
        'begin_first', (SELECT value FROM industry_stats WHERE stat_type='lawyer_count' AND created_at >= (p_start::timestamp AT TIME ZONE 'Asia/Taipei') ORDER BY created_at LIMIT 1),
        'end', (SELECT value FROM industry_stats WHERE stat_type='lawyer_count' AND created_at < ((p_end+1)::timestamp AT TIME ZONE 'Asia/Taipei') ORDER BY created_at DESC LIMIT 1)),
    'guild_gain', (SELECT coalesce(jsonb_agg(jsonb_build_object('region', region, 'gain', gain, 'end', v_end) ORDER BY gain DESC), '[]'::jsonb) FROM (
        SELECT region,
               (array_agg(value ORDER BY created_at DESC))[1] AS v_end,
               (array_agg(value ORDER BY created_at DESC))[1] - (array_agg(value ORDER BY created_at))[1] AS gain
          FROM industry_stats
         WHERE stat_type='guild_lawyer_count'
           AND created_at >= ((p_start - 7)::timestamp AT TIME ZONE 'Asia/Taipei')
           AND created_at <  ((p_end + 1)::timestamp AT TIME ZONE 'Asia/Taipei')
         GROUP BY region) g),
    'flow', jsonb_build_object(
        'firm_to_firm', (SELECT count(*) FROM mv),
        'entering', (SELECT count(*) FROM ch WHERE change_type='firm_change' AND NOT flow_is_firm(old_office) AND flow_is_firm(new_office) AND coalesce(old_office,'') <> ''),
        'leaving',  (SELECT count(*) FROM ch WHERE change_type='firm_change' AND flow_is_firm(old_office) AND NOT flow_is_firm(new_office)),
        'new_lawyers', (SELECT count(*) FROM ch WHERE change_type='new_lawyer'),
        'firm_change_all', (SELECT count(*) FROM ch WHERE change_type='firm_change' AND (flow_is_firm(old_office) OR flow_is_firm(new_office))),
        'state_removed', (SELECT count(*) FROM ch WHERE change_type='state_change' AND coalesce(old_state,'')='正常' AND coalesce(new_state,'')<>'正常'),
        'state_restored', (SELECT count(*) FROM ch WHERE change_type='state_change' AND coalesce(new_state,'')='正常' AND coalesce(old_state,'')<>'正常'),
        'discipline', (SELECT count(*) FROM ch WHERE change_type='discipline_change')),
    'net_top', (SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.net DESC, n.moved_in DESC), '[]'::jsonb) FROM (SELECT * FROM net WHERE net > 0 ORDER BY net DESC, moved_in DESC LIMIT 10) n),
    'net_bottom', (SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.net, n.moved_out DESC), '[]'::jsonb) FROM (SELECT * FROM net WHERE net < 0 ORDER BY net, moved_out DESC LIMIT 10) n),
    'team_moves', (SELECT coalesce(jsonb_agg(jsonb_build_object('from', from_k, 'to', to_k, 'n', n, 'names', names) ORDER BY n DESC), '[]'::jsonb) FROM (
        SELECT from_k, to_k, count(*)::int AS n, jsonb_agg(name ORDER BY name) AS names FROM mv GROUP BY 1,2 HAVING count(*) >= 3) t),
    'moves_list', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', name, 'from', from_k, 'to', to_k) ORDER BY from_k, name), '[]'::jsonb) FROM (
        SELECT * FROM mv ORDER BY from_k, name LIMIT 80) t),
    'intake_top', (SELECT coalesce(jsonb_agg(jsonb_build_object('firm', fk, 'n', n) ORDER BY n DESC, fk), '[]'::jsonb) FROM (
        SELECT flow_firm_key(new_office) AS fk, count(*)::int AS n FROM ch
         WHERE change_type='new_lawyer' AND flow_is_firm(new_office) GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 10) t),
    'opened', jsonb_build_object(
        'n', (SELECT count(*) FROM opened),
        'by_kind', (SELECT coalesce(jsonb_object_agg(k, c), '{}'::jsonb) FROM (SELECT e->>'kind' k, count(*) c FROM opened GROUP BY 1) z),
        'top', (SELECT coalesce(jsonb_agg(jsonb_build_object('firm', e->>'firm_key', 'kind', e->>'kind', 'n', (e->>'active_n')::int, 'from', e->'from_firms', 'split_from', e->>'split_from') ORDER BY (e->>'active_n')::int DESC), '[]'::jsonb)
                  FROM (SELECT e FROM opened WHERE e->>'kind' <> 'rename' ORDER BY (e->>'active_n')::int DESC LIMIT 15) z)),
    'closed', jsonb_build_object(
        'n', (SELECT count(*) FROM closed),
        'by_kind', (SELECT coalesce(jsonb_object_agg(k, c), '{}'::jsonb) FROM (SELECT e->>'kind' k, count(*) c FROM closed GROUP BY 1) z),
        'top', (SELECT coalesce(jsonb_agg(jsonb_build_object('firm', e->>'firm_key', 'kind', e->>'kind', 'n', (e->>'departed')::int, 'dest', e->>'dest_firm') ORDER BY (e->>'departed')::int DESC), '[]'::jsonb)
                  FROM (SELECT e FROM closed WHERE e->>'kind' <> 'rename' ORDER BY (e->>'departed')::int DESC LIMIT 15) z)),
    'zhelu_moves', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', name, 'type', change_type, 'from', old_office, 'to', new_office, 'd', d) ORDER BY d), '[]'::jsonb)
        FROM ch WHERE change_type IN ('firm_change','new_lawyer') AND (coalesce(old_office,'') LIKE '%喆律%' OR coalesce(new_office,'') LIKE '%喆律%')),
    'discipline_list', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', name, 'office', coalesce(new_office, old_office), 'd', d) ORDER BY d), '[]'::jsonb)
        FROM ch WHERE change_type='discipline_change'),
    'snapshot', jsonb_build_object(
        'end_month', v_snap_end, 'begin_month', v_snap_beg,
        'end', (SELECT to_jsonb(s) - 'snapshot_month' FROM snap s WHERE snapshot_month = v_snap_end),
        'begin', (SELECT to_jsonb(s) - 'snapshot_month' FROM snap s WHERE snapshot_month = v_snap_beg)),
    'judgment', jsonb_build_object(
        'yms', to_jsonb(v_yms),
        'firms_total', (SELECT sum(cases) FROM jd),
        'zhelu_cases', (SELECT cases FROM jr WHERE firm_key = '喆律法律事務所'),
        'zhelu_rank', (SELECT rk FROM jr WHERE firm_key = '喆律法律事務所'),
        'top10', (SELECT coalesce(jsonb_agg(jsonb_build_object('firm', firm_key, 'cases', cases, 'rank', rk) ORDER BY rk, firm_key), '[]'::jsonb) FROM (SELECT * FROM jr ORDER BY rk, firm_key LIMIT 10) t)),
    'rep_rate', (SELECT coalesce(jsonb_object_agg(file_type, jsonb_build_object('n', n, 'repped', repped)), '{}'::jsonb) FROM rep)
  ) INTO v_res;
  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION industry_watch_metrics(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION industry_watch_metrics(date, date) TO service_role;

COMMENT ON TABLE industry_watch_reports IS '產業觀察定期報告（週／月／季／年），scripts/industry_watch_report.py 產生；前端 喆律戰情＞產業觀察（admin-only）';
