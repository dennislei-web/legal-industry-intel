-- 283: 政府標案「決標方式」統計 RPC（產業分析＞政府標案頁「決標方式」卡）
--
-- 背景：爬蟲原本只讀「採購資料:決標方式」，決標公告/定期彙送把該欄放在「已公告資料」區塊，
--       故有競爭的案（準用最有利標／參考最有利標精神）幾乎全缺；2026-11 已自來源回補並修正爬蟲。
-- 口徑：gov_award_method_norm 把原始字串歸成 5 類＋未載明；
--       p_from_year 為 NULL 表全期，否則只計 award_year >= p_from_year。
--   methods：各方式 件數／金額／中位金額／平均投標家數／單一投標件數
--   buckets：金額級距 × 方式 件數（堆疊圖用）
--   firms  ：各方式得標所 TOP 8（分所歸戶，gov_firm_norm，mig 110）

CREATE OR REPLACE FUNCTION gov_award_method_norm(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p IS NULL OR btrim(p) = ''   THEN '未載明'
    WHEN p LIKE '%參考最有利標%'       THEN '參考最有利標精神'
    WHEN p LIKE '%準用最有利標%'       THEN '準用最有利標'
    WHEN p LIKE '%最有利標%'           THEN '最有利標'
    WHEN p LIKE '%最低標%'             THEN '最低標'
    ELSE '其他'
  END;
$fn$;

CREATE OR REPLACE FUNCTION gov_tender_method_stats(p_from_year int DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
WITH b AS (
  SELECT tender_key, count(*) AS n FROM gov_tender_firms GROUP BY 1
),
t AS (
  SELECT g.tender_key, g.total_amount, b.n,
         gov_award_method_norm(g.award_method) AS m,
         CASE WHEN g.total_amount IS NULL      THEN NULL
              WHEN g.total_amount < 500000     THEN 1
              WHEN g.total_amount < 1000000    THEN 2
              WHEN g.total_amount < 5000000    THEN 3
              WHEN g.total_amount < 10000000   THEN 4
              ELSE 5 END AS bk
  FROM gov_tenders g
  LEFT JOIN b USING (tender_key)
  WHERE g.award_year IS NOT NULL
    AND (p_from_year IS NULL OR g.award_year >= p_from_year)
),
methods AS (
  SELECT m,
         count(*)                                                   AS cases,
         coalesce(sum(total_amount), 0)                             AS total_amount,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY total_amount)  AS median_amount,
         round(avg(n), 2)                                           AS avg_bidders,
         count(*) FILTER (WHERE n = 1)                              AS single_bid,
         count(*) FILTER (WHERE n IS NOT NULL)                      AS with_bidders
  FROM t GROUP BY m
),
buckets AS (
  SELECT bk, m, count(*) AS cases, sum(total_amount) AS total_amount
  FROM t WHERE bk IS NOT NULL GROUP BY bk, m
),
fw AS (
  SELECT t.m, gov_firm_norm(f.firm_name) AS firm_key,
         count(DISTINCT t.tender_key) AS wins,
         sum(f.award_amount)          AS total_amount
  FROM gov_tender_firms f
  JOIN t USING (tender_key)
  WHERE f.is_winner
  GROUP BY 1, 2
),
fr AS (
  SELECT fw.*, row_number() OVER (PARTITION BY m ORDER BY wins DESC, total_amount DESC NULLS LAST) AS rk,
         count(*) OVER (PARTITION BY m) AS firms_n
  FROM fw
)
SELECT jsonb_build_object(
  'methods', (SELECT coalesce(jsonb_agg(to_jsonb(methods) ORDER BY cases DESC), '[]'::jsonb) FROM methods),
  'buckets', (SELECT coalesce(jsonb_agg(to_jsonb(buckets) ORDER BY bk, m), '[]'::jsonb) FROM buckets),
  'firms',   (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'm', m, 'firm_key', firm_key, 'wins', wins,
                  'total_amount', total_amount, 'rk', rk, 'firms_n', firms_n) ORDER BY m, rk), '[]'::jsonb)
              FROM fr WHERE rk <= 8)
);
$fn$;
ALTER FUNCTION gov_tender_method_stats(int) SET statement_timeout = '60s';
-- 新建函式預設 PUBLIC/anon 可執行；比照其他標案 RPC 僅限登入者
REVOKE EXECUTE ON FUNCTION gov_tender_method_stats(int) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION gov_award_method_norm(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION gov_tender_method_stats(int) TO authenticated;
GRANT EXECUTE ON FUNCTION gov_award_method_norm(text) TO authenticated;
