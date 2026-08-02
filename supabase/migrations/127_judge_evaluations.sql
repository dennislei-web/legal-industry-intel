-- 法官評鑑委員會決議紀錄：司法院「決議書查詢及追蹤資訊」（2012 年迄今全量 ~1,814 筆）
-- 來源腳本：scripts/judge_evaluations.py（手動執行；月增量極低）
-- 口徑：含審查決議「審評字」（多為不付評鑑）與評鑑決議「評字」；
--       公開版決議書「一律遮罩姓名」（成立案亦然，僅姓＋○○），故無法 join 個別法官，
--       name_masked＋org 提供法院層級訊號；與 judge_disciplines / judge_impeachments
--       為前哨→後端關係（評鑑成立→移送職務法庭/監察院）。

CREATE TABLE IF NOT EXISTS judge_evaluations (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_no text NOT NULL,            -- 115年度評字第2號 / 115年度審評字第169號
  decided_date date,                -- 列表所載決議日期
  result text,                      -- 分類：不付評鑑/請求不成立/不受理/免議/成立：移送懲戒法院|移送監察院|建議職務監督/成立/其他
  summary text,                     -- 主文摘要（前 400 字）
  name text,                        -- 具名法官（實測全量為 NULL，保留欄位）
  name_masked text,                 -- 遮罩名（張○○）
  org text,                         -- 受評鑑時任職法院（含「前」）
  doc_url text NOT NULL DEFAULT '', -- 決議書 PDF（早年項目無附件=空字串）
  source_url text,                  -- 司法院公告頁
  scraped_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_no, doc_url)
);

CREATE INDEX IF NOT EXISTS idx_jeval_date ON judge_evaluations (decided_date);
CREATE INDEX IF NOT EXISTS idx_jeval_result ON judge_evaluations (result);

ALTER TABLE judge_evaluations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_jeval" ON judge_evaluations;
CREATE POLICY "auth_read_jeval" ON judge_evaluations
  FOR SELECT USING (auth.uid() IS NOT NULL);
