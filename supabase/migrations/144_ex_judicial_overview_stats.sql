-- 144: 前司法官律師總覽統計 RPC（律師區總覽 KPI 卡用）
--
-- 口徑：moj_lawyers state_desc='正常'（現行執業）× ex_judicial_lawyers 高/中信心，
-- 以姓名去重；judges/prosecutors 有交集（審檢都做過者兩邊都算）。
-- gazette_n = 公報回補線（mig 141）貢獻的人數。

CREATE OR REPLACE FUNCTION ex_judicial_overview_stats()
RETURNS TABLE (active_total bigint, exj_total bigint, judges bigint, prosecutors bigint, gazette_n bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  WITH active AS (SELECT DISTINCT name FROM moj_lawyers WHERE state_desc = '正常'),
  exj AS (
    SELECT e.name,
           bool_or(e.kind = 'judge') AS wj,
           bool_or(e.kind = 'prosecutor') AS wp,
           bool_or(e.source = 'gazette') AS gz
    FROM ex_judicial_lawyers e
    JOIN active a USING (name)
    WHERE e.confidence IN ('high', 'medium')
    GROUP BY e.name
  )
  SELECT (SELECT count(*) FROM active),
         (SELECT count(*) FROM exj),
         (SELECT count(*) FILTER (WHERE wj) FROM exj),
         (SELECT count(*) FILTER (WHERE wp) FROM exj),
         (SELECT count(*) FILTER (WHERE gz) FROM exj);
$fn$;
