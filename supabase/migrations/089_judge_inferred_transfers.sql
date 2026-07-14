-- 異動補全：署名軌跡推定轉調（官方邊之外的漏配補回）
-- 背景：官方遷調邊（mig 084）僅比對到 ~一半跨院流動，其餘漏進「進場/退場」。
--       高院尤甚：94 個「真新進」中 77 個其實是升上來的職涯法官。
-- 作法：把「A院退場 → B院進場、時間銜接、且 A/B 署名區間不長期重疊（＝同一人非同名）」
--       補標為異動（推定）。官方邊優先，僅對未配到官方邊者做推定。
-- 同名防呆：兩院[首見,末見]區間重疊 > max_overlap 個月 → 視為同名兩人，不連。
--          （與 mig 043「不做跨院連連看」的顧慮相同，此處用區間重疊當仲裁而非硬連）

ALTER TABLE judge_changes ADD COLUMN IF NOT EXISTS inferred_to text;    -- 退場列：推定調往
ALTER TABLE judge_changes ADD COLUMN IF NOT EXISTS inferred_from text;  -- 進場列：推定來自

CREATE OR REPLACE FUNCTION refresh_judge_change_inferred_transfers(
  win_after  int DEFAULT 12,   -- 進場可落在退場後 N 個月內
  win_before int DEFAULT 3,    -- 或退場前 M 個月內（交接期先到新院署名）
  max_overlap int DEFAULT 6    -- A/B 署名區間重疊上限（超過視為同名兩人）
) RETURNS int AS $$
DECLARE n int; n2 int;
BEGIN
  UPDATE judge_changes SET inferred_to = NULL, inferred_from = NULL
  WHERE inferred_to IS NOT NULL OR inferred_from IS NOT NULL;

  -- 每 (name,court) 署名區間（月序整數）。直接用署名軌跡接，不需對側有 leave/appear 事件，
  -- 才能涵蓋借調型（原院無真正退場）與較早調動。
  CREATE TEMP TABLE _spans ON COMMIT DROP AS
  SELECT name, court_name,
         min(substr(yyyymm,1,4)::int*12 + substr(yyyymm,5,2)::int) AS f,
         max(substr(yyyymm,1,4)::int*12 + substr(yyyymm,5,2)::int) AS l
  FROM judge_month_stats
  WHERE court_name <> '未知法院'
  GROUP BY name, court_name;
  CREATE INDEX ON _spans (name);

  -- 進場列 → 推定來自：該名字在到任月前後、於別院署過名（末見月最接近 am），
  --   且兩院署名區間重疊 <= max_overlap（＝同一人先後在任，非同名並存兩人）
  UPDATE judge_changes c SET inferred_from = b.from_c
  FROM (
    SELECT DISTINCT ON (ap.id) ap.id AS appear_id, s.court_name AS from_c
    FROM judge_changes ap
    JOIN _spans sb ON sb.name = ap.name AND sb.court_name = ap.court_name
    JOIN _spans s  ON s.name = ap.name AND s.court_name <> ap.court_name
    WHERE ap.change_type = 'appear' AND ap.transfer_from IS NULL
      AND s.l BETWEEN (substr(ap.event_month,1,4)::int*12+substr(ap.event_month,5,2)::int) - win_after
                  AND (substr(ap.event_month,1,4)::int*12+substr(ap.event_month,5,2)::int) + win_before
      AND greatest(0, least(s.l, sb.l) - greatest(s.f, sb.f) + 1) <= max_overlap
    ORDER BY ap.id,
             abs(s.l - (substr(ap.event_month,1,4)::int*12+substr(ap.event_month,5,2)::int)),
             greatest(0, least(s.l, sb.l) - greatest(s.f, sb.f) + 1)
  ) b
  WHERE c.id = b.appear_id;
  GET DIAGNOSTICS n = ROW_COUNT;

  -- 退場列 → 推定調往：該名字在末見月前後、於別院開始署名（首見月最接近 lm）
  UPDATE judge_changes c SET inferred_to = b.to_c
  FROM (
    SELECT DISTINCT ON (lv.id) lv.id AS leave_id, s.court_name AS to_c
    FROM judge_changes lv
    JOIN _spans sa ON sa.name = lv.name AND sa.court_name = lv.court_name
    JOIN _spans s  ON s.name = lv.name AND s.court_name <> lv.court_name
    WHERE lv.change_type = 'leave' AND lv.transfer_to IS NULL
      AND s.f BETWEEN (substr(lv.event_month,1,4)::int*12+substr(lv.event_month,5,2)::int) - win_before
                  AND (substr(lv.event_month,1,4)::int*12+substr(lv.event_month,5,2)::int) + win_after
      AND greatest(0, least(sa.l, s.l) - greatest(sa.f, s.f) + 1) <= max_overlap
    ORDER BY lv.id,
             abs(s.f - (substr(lv.event_month,1,4)::int*12+substr(lv.event_month,5,2)::int)),
             greatest(0, least(sa.l, s.l) - greatest(sa.f, s.f) + 1)
  ) b
  WHERE c.id = b.leave_id;
  GET DIAGNOSTICS n2 = ROW_COUNT;

  RETURN n + n2;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
