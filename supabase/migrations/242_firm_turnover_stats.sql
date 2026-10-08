-- 242：事務所律師離職率（年化）— 事務所總覽「人才流動快照」下方
--
-- 口徑（比照事務所人資「真離職率」）：
--   分子＝觀察期內離開該所的律師（去他所／轉未登錄／退出執業），每人每所計一次；
--         離開後又回原所（現名冊仍在原所）不計；
--         整所改名或併入他所（firm_open_close kind rename/merge）比照內部轉換不計。
--         退出執業＝state_change 正常→非正常且現仍非正常（多為「名冊查無（推定除名）」）。
--   分母＝firm_headcount_snapshots 觀察期內各月快照的平均人數（is_firm）。
--   年化＝×365／觀察天數。觀察起點固定 2026-07-27（7/3–7/26 為首輪補登噪音）。
--   名冊人數含老闆／合夥人，且律師離職後未必即時變更登錄 → 本口徑為下限。
--   1 人所另列（離開＝收掉自己的所，不是員工離職），不併入主數字。

CREATE OR REPLACE FUNCTION firm_turnover_stats()
RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
WITH W AS (
  SELECT timestamptz '2026-07-27' AS t0,
         (SELECT max(changed_at) FROM moj_lawyer_changes) AS t1
), rm AS (
  SELECT x->>'firm_key' AS fk
  FROM json_array_elements(firm_open_close()->'closed') x
  WHERE x->>'kind' IN ('rename','merge') AND (x->>'closed_at')::date >= date '2026-07-27'
), hc AS (
  SELECT firm_key AS fk, avg(lawyer_n)::numeric AS avg_n
  FROM firm_headcount_snapshots
  WHERE is_firm AND snapshot_month >= '2026-07'
  GROUP BY 1
), hcb AS (
  SELECT fk, avg_n,
         CASE WHEN avg_n < 1.5 THEN 1 WHEN avg_n < 4.5 THEN 2 WHEN avg_n < 9.5 THEN 3
              WHEN avg_n < 29.5 THEN 4 ELSE 5 END AS band
  FROM hc
), mv AS (
  SELECT DISTINCT ON (c.lic_no, flow_firm_key(c.old_office))
         c.lic_no, flow_firm_key(c.old_office) AS src,
         CASE WHEN flow_is_firm(c.new_office) THEN 'firm' ELSE 'unlisted' END AS dest
  FROM moj_lawyer_changes c
  JOIN moj_lawyers l USING (lic_no)
  CROSS JOIN W
  WHERE c.change_type = 'firm_change' AND c.changed_at >= W.t0
    AND flow_is_firm(c.old_office)
    AND flow_firm_key(c.old_office) IS DISTINCT FROM flow_firm_key(c.new_office)
    AND flow_firm_key(l.office_normalized) IS DISTINCT FROM flow_firm_key(c.old_office)
  ORDER BY c.lic_no, flow_firm_key(c.old_office), c.changed_at
), st AS (
  SELECT DISTINCT ON (c.lic_no) c.lic_no, flow_firm_key(l.office_normalized) AS src, 'exit' AS dest
  FROM moj_lawyer_changes c
  JOIN moj_lawyers l USING (lic_no)
  CROSS JOIN W
  WHERE c.change_type = 'state_change' AND c.old_state = '正常' AND c.new_state <> '正常'
    AND c.changed_at >= W.t0
    AND flow_is_firm(l.office_normalized) AND l.state_desc <> '正常'
  ORDER BY c.lic_no, c.changed_at
), ev AS (
  SELECT * FROM mv
  UNION ALL
  SELECT * FROM st WHERE lic_no NOT IN (SELECT lic_no FROM mv)
), evj AS (
  SELECT ev.*, h.band, h.avg_n
  FROM ev JOIN hcb h ON h.fk = ev.src
  WHERE ev.src NOT IN (SELECT fk FROM rm)
), per_firm AS (
  SELECT h.fk, h.avg_n, h.band,
         count(e.lic_no)::int AS leave_n,
         count(e.lic_no) FILTER (WHERE e.dest = 'firm')::int AS to_firm,
         count(e.lic_no) FILTER (WHERE e.dest = 'unlisted')::int AS to_unlisted,
         count(e.lic_no) FILTER (WHERE e.dest = 'exit')::int AS to_exit
  FROM hcb h LEFT JOIN evj e ON e.src = h.fk
  GROUP BY h.fk, h.avg_n, h.band
), bands AS (
  SELECT band, count(*)::int AS firms, round(sum(avg_n))::int AS avg_n,
         sum(leave_n)::int AS leave_n, sum(to_firm)::int AS to_firm,
         sum(to_unlisted)::int AS to_unlisted, sum(to_exit)::int AS to_exit
  FROM per_firm GROUP BY band
)
SELECT json_build_object(
  't0', (SELECT t0::date FROM W),
  't1', (SELECT t1::date FROM W),
  'days', (SELECT round(extract(epoch FROM t1 - t0) / 86400, 1) FROM W),
  'months', (SELECT array_agg(DISTINCT snapshot_month ORDER BY snapshot_month)
             FROM firm_headcount_snapshots WHERE snapshot_month >= '2026-07'),
  'excluded_rm', (SELECT count(*) FROM ev WHERE src IN (SELECT fk FROM rm)),
  'excluded_nosnap', (SELECT count(*) FROM ev WHERE src NOT IN (SELECT fk FROM hc)),
  'bands', (SELECT json_agg(b ORDER BY band) FROM bands b),
  'firms', (SELECT json_agg(json_build_object(
              'firm_key', fk, 'avg_n', round(avg_n, 1), 'leave_n', leave_n,
              'to_firm', to_firm, 'to_unlisted', to_unlisted, 'to_exit', to_exit)
            ORDER BY leave_n / avg_n DESC, avg_n DESC)
            FROM per_firm WHERE avg_n >= 20)
);
$$;

GRANT EXECUTE ON FUNCTION firm_turnover_stats() TO authenticated, service_role;
