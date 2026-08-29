-- 1 億+ 標的案件逐案明細（mig 174）：第六節離群值警示的可下鑽資料
-- 產出：scripts/big_amount_cases.py —— 終結案件微資料月包（官方標的金額 >= 1 億）
--       × clients 快取（律師/當事人/攻守/案由），按 JID 前 4 段 join。
-- detail = [{name, camp, parties[]}]（該案每位有裁判書紀錄的律師與其代理當事人）；
-- lawyer_names 為查詢用扁平陣列（&& overlap）。amount 單位元。

CREATE TABLE IF NOT EXISTS big_amount_cases (
  jid          text   PRIMARY KEY,
  ym           text   NOT NULL,              -- 終結月（西元 yyyymm）
  court        text,
  cat          text,
  title        text,                          -- 案由
  amount       bigint NOT NULL,               -- 官方登錄標的金額（元）
  appeal_level int    NOT NULL DEFAULT 1,     -- 1/2/3 審（依法院代碼）
  lawyer_names text[] NOT NULL DEFAULT '{}',
  detail       jsonb  NOT NULL DEFAULT '[]'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_bac_amount ON big_amount_cases (amount DESC);
CREATE INDEX IF NOT EXISTS idx_bac_names  ON big_amount_cases USING gin (lawyer_names);

ALTER TABLE big_amount_cases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_bac" ON big_amount_cases;
CREATE POLICY "auth_read_bac" ON big_amount_cases
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- 按律師名單撈某所的 1 億+ 案（POST body 帶名單，避免長 URL）
CREATE OR REPLACE FUNCTION firm_big_cases(p_names text[])
RETURNS SETOF big_amount_cases LANGUAGE sql STABLE AS $$
  SELECT * FROM big_amount_cases
  WHERE lawyer_names && p_names
  ORDER BY amount DESC
  LIMIT 200;
$$;
