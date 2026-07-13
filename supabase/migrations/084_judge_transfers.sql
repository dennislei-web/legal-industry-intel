-- 法官遷調邊：司法院人審會決議（lp-1915，2019-12 起新版網站全量）解析而來
-- 來源腳本：scripts/jy_transfers.py（list → fetch → parse → upload）
-- 用途：把 judge_changes 的 leave+appear 配對到官方遷調邊，區分「轉調」與「推定退場」，
--       同時解掉同名跨院誤判（官方邊 = 姓名+原院+新院+生效日，是權威 ground truth）。

CREATE TABLE IF NOT EXISTS judge_transfers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('transfer', 'support', 'promotion', 'exit')),
    -- transfer=調任他機關 / support=以原職借調辦事（簽名會移動、職缺不動）
    -- promotion=同院兼庭長等（不影響進退場）/ exit=辭職、退休
  name text NOT NULL,
  from_org text NOT NULL,
  from_title text,
  to_org text,                        -- exit 為 NULL
  to_title text,
  effective_date date,                -- 決議段內「自○年○月○日生效」；缺者以決議日代
  decision_title text,                -- 例：司法院115年第5次人事審議委員會決議
  source_url text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_jt_name ON judge_transfers (name);
CREATE INDEX IF NOT EXISTS idx_jt_from ON judge_transfers (from_org);
CREATE INDEX IF NOT EXISTS idx_jt_to ON judge_transfers (to_org);
CREATE INDEX IF NOT EXISTS idx_jt_eff ON judge_transfers (effective_date);

ALTER TABLE judge_transfers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "authenticated_read_judge_transfers" ON judge_transfers;
CREATE POLICY "authenticated_read_judge_transfers" ON judge_transfers
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 異動明細加註解釋欄：retire/transfer 分類由遷調邊 refresh 時回填
ALTER TABLE judge_changes ADD COLUMN IF NOT EXISTS transfer_to text;      -- 退場列：官方邊顯示調往哪裡
ALTER TABLE judge_changes ADD COLUMN IF NOT EXISTS transfer_from text;    -- 進場列：官方邊顯示從哪裡調來
ALTER TABLE judge_changes ADD COLUMN IF NOT EXISTS transfer_url text;     -- 對到的決議 URL

-- 把 judge_changes 對上官方遷調邊（法院名正規化：裁判書側「臺灣高雄少年及家事法院」等
-- 與決議側寫法一致，直接以「姓名＋法院＋時間窗」比對；時間窗 ±9 個月容忍裁判書發布延遲）
CREATE OR REPLACE FUNCTION refresh_judge_change_transfers(window_months int DEFAULT 9)
RETURNS int AS $$
DECLARE
  n int := 0;
BEGIN
  UPDATE judge_changes c SET transfer_to = NULL, transfer_from = NULL, transfer_url = NULL
  WHERE transfer_to IS NOT NULL OR transfer_from IS NOT NULL OR transfer_url IS NOT NULL;

  -- 退場列：該名字從該院被調走／借調（末見月落在生效日 ±window）
  UPDATE judge_changes c
  SET transfer_to = t.to_org, transfer_url = t.source_url
  FROM judge_transfers t
  WHERE c.change_type = 'leave'
    AND c.name = t.name
    AND c.court_name = t.from_org
    AND t.kind IN ('transfer', 'support')
    AND t.from_org <> t.to_org
    AND t.effective_date IS NOT NULL
    AND abs( (extract(year from t.effective_date)*12 + extract(month from t.effective_date))
           - (substr(c.event_month,1,4)::int*12 + substr(c.event_month,5,2)::int) ) <= window_months;
  GET DIAGNOSTICS n = ROW_COUNT;

  -- 退場列：官方確認辭職/退休
  UPDATE judge_changes c
  SET transfer_to = '離職（' || t.to_title || '）', transfer_url = t.source_url
  FROM judge_transfers t
  WHERE c.change_type = 'leave'
    AND c.transfer_to IS NULL
    AND c.name = t.name
    AND c.court_name = t.from_org
    AND t.kind = 'exit'
    AND t.effective_date IS NOT NULL
    AND abs( (extract(year from t.effective_date)*12 + extract(month from t.effective_date))
           - (substr(c.event_month,1,4)::int*12 + substr(c.event_month,5,2)::int) ) <= window_months;

  -- 進場列：該名字被調來該院（首見月落在生效日 ±window）
  UPDATE judge_changes c
  SET transfer_from = t.from_org, transfer_url = t.source_url
  FROM judge_transfers t
  WHERE c.change_type = 'appear'
    AND c.name = t.name
    AND c.court_name = t.to_org
    AND t.kind IN ('transfer', 'support')
    AND t.from_org <> t.to_org
    AND t.effective_date IS NOT NULL
    AND abs( (extract(year from t.effective_date)*12 + extract(month from t.effective_date))
           - (substr(c.event_month,1,4)::int*12 + substr(c.event_month,5,2)::int) ) <= window_months;

  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
