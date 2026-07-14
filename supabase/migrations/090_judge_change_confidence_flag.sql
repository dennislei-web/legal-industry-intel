-- 進退場信心旗標：標記「另一側是否有跨院署名」
-- 用途：進退場數字是署名活躍度上界（退場含休庭誤判、跨院同名續任）。此旗標讓前端算出
--       高信心下界：真退場且退場後全體系再無署名＝較確定離職；真新進且到任前從未署名＝全新。
-- 定義：leave → 退場後(event_month 之後)是否在別院署名；appear → 到任前是否在別院署名。
--       TRUE = 另一側有跨院署名（＝該筆較可能是未廓清的轉調/續任，非乾淨的離職/新任）。

ALTER TABLE judge_changes ADD COLUMN IF NOT EXISTS cross_court_other_side boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION refresh_judge_change_confidence_flag() RETURNS int AS $$
DECLARE n int; n2 int;
BEGIN
  UPDATE judge_changes SET cross_court_other_side = false WHERE cross_court_other_side;

  -- 退場：末見月之後仍在別院署名
  UPDATE judge_changes c SET cross_court_other_side = true
  WHERE c.change_type = 'leave' AND EXISTS (
    SELECT 1 FROM judge_month_stats s
    WHERE s.name = c.name AND s.court_name <> c.court_name
      AND s.court_name <> '未知法院' AND s.yyyymm > c.event_month);
  GET DIAGNOSTICS n = ROW_COUNT;

  -- 進場：首見月之前已在別院署名
  UPDATE judge_changes c SET cross_court_other_side = true
  WHERE c.change_type = 'appear' AND EXISTS (
    SELECT 1 FROM judge_month_stats s
    WHERE s.name = c.name AND s.court_name <> c.court_name
      AND s.court_name <> '未知法院' AND s.yyyymm < c.event_month);
  GET DIAGNOSTICS n2 = ROW_COUNT;

  RETURN n + n2;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
