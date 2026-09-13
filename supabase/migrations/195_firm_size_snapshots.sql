-- ============================================================
-- 195: 事務所規模月快照（firm_headcount_snapshots）
-- ============================================================
-- 問題：站上事務所家數／規模分布只有「現況」（moj_firm_stats_cache 每日覆寫），
--   沒有歷史序列；要回答「這幾個月事務所家數／規模有沒有變」只能用
--   moj_lawyer_changes 倒推（2026-09-13 手工做過一次）。
-- 設計：
--   * firm_headcount_snapshots：snapshot_month × firm_key 的律師數（單位層，
--     含公司/法人；is_firm=名稱含「事務所」）。snapshot_month='YYYY-MM' 代表
--     「該月月底」狀態，由每月 1 日排程（firm-size-snapshot-monthly.yml）
--     呼叫 take_firm_size_snapshot() 寫入上個月。
--   * 歸戶口徑與 moj_firm_statistics()（142 版）一致：現職名冊
--     （deregistered_at IS NULL、排「律師未顯示」/空值）、firm_key 截到第一個
--     「法律/律師事務所」（分所合併），其餘單位（公司/法人）用原名。
--     ⚠ 這裡按證號計人（moj_lawyers 每列一證），moj_firm_statistics() 是姓名
--     唯一歸戶——兩者相差極小（同名同所），但別拿來對到個位數。
--   * firm_headcount_as_of(p_asof)：用 moj_lawyer_changes 把現況倒推到 p_asof
--     時點（現況 − 之後加入 ＋ 之後離開）。只供回填追蹤起點（2026-07-03）
--     之後的月份；追蹤前無法重建。倒推有已知偏差：07 月首波 new_lawyer
--     含補掃入庫噪音（CLAUDE.md），會讓起點略低估，note 欄要標。
--   * firm_size_trend()：前端用，回傳每月 事務所家數／在所律師數／七段規模分布
--     （只算 is_firm）＋非事務所單位數。
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS firm_headcount_snapshots (
  snapshot_month text NOT NULL,          -- 'YYYY-MM'＝該月月底狀態
  firm_key       text NOT NULL,
  lawyer_n       int  NOT NULL,
  is_firm        boolean NOT NULL DEFAULT true,
  taken_at       timestamptz NOT NULL DEFAULT now(),
  note           text,                   -- 回填/倒推口徑註記；正常快照為 NULL
  PRIMARY KEY (snapshot_month, firm_key)
);
CREATE INDEX IF NOT EXISTS idx_fhs_firm ON firm_headcount_snapshots (firm_key);

ALTER TABLE firm_headcount_snapshots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_fhs" ON firm_headcount_snapshots;
CREATE POLICY "auth_read_fhs" ON firm_headcount_snapshots
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 單位 key：與 moj_firm_statistics() 的 firm_key 同構（NULL-safe）
CREATE OR REPLACE FUNCTION unit_firm_key(office text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN office IS NULL OR btrim(office) = '' OR office = '律師未顯示' THEN NULL
    WHEN office ~ '(法律事務所|律師事務所)'
      THEN regexp_replace(office, '^(.+?(?:法律|律師)事務所).*$', '\1')
    ELSE office
  END;
$$;

-- 現況（p_asof IS NULL）或倒推到 p_asof 時點的單位人數
CREATE OR REPLACE FUNCTION firm_headcount_as_of(p_asof timestamptz DEFAULT NULL)
RETURNS TABLE(firm_key text, lawyer_n int, is_firm boolean)
LANGUAGE sql STABLE AS $$
  WITH cur AS (
    SELECT unit_firm_key(office_normalized) AS fk, count(*)::int AS n
    FROM moj_lawyers
    WHERE deregistered_at IS NULL
      AND unit_firm_key(office_normalized) IS NOT NULL
    GROUP BY 1
  ),
  -- p_asof 之後加入某單位：新進律師、或跨單位移動的目的地
  joins AS (
    SELECT unit_firm_key(new_office) AS fk, count(*)::int AS n
    FROM moj_lawyer_changes
    WHERE p_asof IS NOT NULL AND changed_at > p_asof
      AND change_type IN ('new_lawyer','firm_change')
      AND unit_firm_key(new_office) IS NOT NULL
      AND (change_type = 'new_lawyer'
           OR unit_firm_key(old_office) IS DISTINCT FROM unit_firm_key(new_office))
    GROUP BY 1
  ),
  -- p_asof 之後離開某單位：跨單位移動的來源、或除名（用其現登錄單位）
  leaves AS (
    SELECT fk, sum(n)::int AS n FROM (
      SELECT unit_firm_key(old_office) AS fk, count(*) AS n
      FROM moj_lawyer_changes
      WHERE p_asof IS NOT NULL AND changed_at > p_asof
        AND change_type = 'firm_change'
        AND unit_firm_key(old_office) IS NOT NULL
        AND unit_firm_key(old_office) IS DISTINCT FROM unit_firm_key(new_office)
      GROUP BY 1
      UNION ALL
      SELECT unit_firm_key(l.office_normalized), count(*)
      FROM moj_lawyer_changes c
      JOIN moj_lawyers l ON l.lic_no = c.lic_no
      WHERE p_asof IS NOT NULL AND c.changed_at > p_asof
        AND c.change_type = 'state_change' AND c.new_state LIKE '%除名%'
        AND unit_firm_key(l.office_normalized) IS NOT NULL
      GROUP BY 1
    ) x GROUP BY fk
  ),
  allk AS (
    SELECT fk FROM cur UNION SELECT fk FROM joins UNION SELECT fk FROM leaves
  )
  SELECT a.fk,
         (coalesce(c.n,0) - coalesce(j.n,0) + coalesce(lv.n,0))::int AS lawyer_n,
         a.fk LIKE '%事務所%' AS is_firm
  FROM allk a
  LEFT JOIN cur c ON c.fk = a.fk
  LEFT JOIN joins j ON j.fk = a.fk
  LEFT JOIN leaves lv ON lv.fk = a.fk
  WHERE (coalesce(c.n,0) - coalesce(j.n,0) + coalesce(lv.n,0)) > 0;
$$;

-- 拍快照：p_month 預設＝上個月（排程每月 1 日跑）；p_asof 預設＝現況。
-- 同月重跑會整月覆寫（冪等）。回傳 json 摘要。
CREATE OR REPLACE FUNCTION take_firm_size_snapshot(
  p_month text DEFAULT NULL,
  p_asof  timestamptz DEFAULT NULL,
  p_note  text DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_month text := coalesce(p_month, to_char((now() AT TIME ZONE 'Asia/Taipei') - interval '1 month', 'YYYY-MM'));
  v_firms int; v_lawyers int; v_units int;
BEGIN
  IF v_month !~ '^\d{4}-\d{2}$' THEN
    RAISE EXCEPTION 'p_month 需為 YYYY-MM，收到 %', v_month;
  END IF;
  DELETE FROM firm_headcount_snapshots WHERE snapshot_month = v_month;
  INSERT INTO firm_headcount_snapshots (snapshot_month, firm_key, lawyer_n, is_firm, note)
  SELECT v_month, h.firm_key, h.lawyer_n, h.is_firm, p_note
  FROM firm_headcount_as_of(p_asof) h;
  SELECT count(*) FILTER (WHERE is_firm), coalesce(sum(lawyer_n) FILTER (WHERE is_firm),0), count(*)
    INTO v_firms, v_lawyers, v_units
  FROM firm_headcount_snapshots WHERE snapshot_month = v_month;
  RETURN json_build_object('month', v_month, 'as_of', coalesce(p_asof, now()),
                           'firms', v_firms, 'firm_lawyers', v_lawyers, 'units', v_units);
END;
$$;

-- 前端趨勢：每月 事務所家數／在所律師數／七段分布（只算 is_firm）＋非事務所單位數
CREATE OR REPLACE FUNCTION firm_size_trend()
RETURNS TABLE(
  snapshot_month text, firms int, firm_lawyers int, other_units int,
  b1 int, b2_3 int, b4_5 int, b6_10 int, b11_20 int, b21_50 int, b50p int,
  note text, taken_at timestamptz
)
LANGUAGE sql STABLE AS $$
  SELECT s.snapshot_month,
         count(*) FILTER (WHERE is_firm)::int,
         coalesce(sum(lawyer_n) FILTER (WHERE is_firm),0)::int,
         count(*) FILTER (WHERE NOT is_firm)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n = 1)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 2 AND 3)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 4 AND 5)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 6 AND 10)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 11 AND 20)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n BETWEEN 21 AND 50)::int,
         count(*) FILTER (WHERE is_firm AND lawyer_n > 50)::int,
         max(s.note),
         max(s.taken_at)
  FROM firm_headcount_snapshots s
  GROUP BY s.snapshot_month
  ORDER BY s.snapshot_month;
$$;

GRANT EXECUTE ON FUNCTION unit_firm_key(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION firm_headcount_as_of(timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION take_firm_size_snapshot(text, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION firm_size_trend() TO authenticated, service_role;

INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency, is_active, notes)
SELECT '事務所規模月快照', 'https://lawyerbc.moj.gov.tw/',
       '法務部律師名冊現職登錄單位 → 每月月底事務所家數／律師數／規模分布快照（firm_headcount_snapshots）',
       'firms', 'firm_size_snapshot', 'monthly', true,
       '每月 1 日台北 00:30 排程（firm-size-snapshot-monthly.yml）呼叫 take_firm_size_snapshot()；2026-06~08 為 moj_lawyer_changes 倒推回填'
WHERE NOT EXISTS (SELECT 1 FROM data_sources WHERE scraper_name = 'firm_size_snapshot');

COMMIT;

-- ---------- 回填（追蹤起點 2026-07-03 之後才可倒推） ----------
-- 2026-06：追蹤起點狀態（≈6 月底，實為 07-03 首次 diff 前），起點含補掃噪音略低估
SELECT take_firm_size_snapshot('2026-06', '2026-07-03 00:00:00+08',
  '倒推回填：追蹤起點 2026-07-03 狀態，非真正月底；07 月首波 new_lawyer 含補掃入庫噪音，家數略低估');
SELECT take_firm_size_snapshot('2026-07', '2026-08-01 00:00:00+08', '倒推回填（moj_lawyer_changes）');
SELECT take_firm_size_snapshot('2026-08', '2026-09-01 00:00:00+08', '倒推回填（moj_lawyer_changes）');
