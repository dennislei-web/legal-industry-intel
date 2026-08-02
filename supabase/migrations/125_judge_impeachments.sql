-- 司法人員監察院彈劾紀錄：監察院「彈劾案文」查詢系統（CyBsBox，全量 ~536 件）
-- 來源腳本：scripts/judge_impeachments.py（手動執行；月增量極低）
-- 口徑：僅保留案由可錨定「機關＋職稱＋姓名」且屬法院/檢察署系統者；
--       姓名以 judge_judgment_stats / prosecutor_stats 已知司法官名單交叉驗證截字。
-- 彈劾＝移送懲戒法院職務法庭之前置程序，與 judge_disciplines 為上下游關係。

CREATE TABLE IF NOT EXISTS judge_impeachments (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_no text NOT NULL,            -- 114年劾字第23號
  decided_date date,                -- 審議日期
  name text NOT NULL,               -- 被彈劾人（案由具名）
  role text,                        -- 法官 / 檢察官
  org text,                         -- 案由所載機關
  title text,                       -- 職稱原文（含「前」）
  cause text,                       -- 案由全文（列表版）
  doc_url text,                     -- 彈劾案文（公布版）下載
  progress text,                    -- 監察院網站「處理進度」欄
  scraped_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_no, name)
);

CREATE INDEX IF NOT EXISTS idx_jimp_name ON judge_impeachments (name);

ALTER TABLE judge_impeachments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_jimp" ON judge_impeachments;
CREATE POLICY "auth_read_jimp" ON judge_impeachments
  FOR SELECT USING (auth.uid() IS NOT NULL);
