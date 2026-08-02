-- 法官/檢察官懲戒紀錄：FJUD 懲戒法院職務法庭（TPJ，2020-07 設立起）裁判解析
-- 來源腳本：scripts/judge_disciplines.py（手動執行；職務法庭案量極低 ~2-3 篇/月）
-- 口徑：僅職務法庭懲戒案（含判決與裁定，裁定多為停止職務）；「職」字案（法官不服
-- 職務監督，當事人角色相反）不納入；改制前公務員懲戒委員會（鑑字）未納入。
-- name 為裁判全文具名（官方公開），join 靠姓名 → 前端顯示 org 供同名區辨。

CREATE TABLE IF NOT EXISTS judge_disciplines (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_no text NOT NULL,            -- 115年度懲字第2號懲戒判決
  kind text,                        -- 判決 / 裁定
  case_cause text,                  -- 裁判案由（懲戒）
  decided_date date,
  name text NOT NULL,               -- 被付懲戒人（具名）
  role text,                        -- 法官 / 檢察官（全文解析，盡力而為）
  org text,                         -- 案發時任職機關（全文解析，盡力而為）
  sanction text,                    -- 結果分類（免除法官職務/撤職/罰款/申誡/停止職務/不受懲戒/免議/上訴駁回…）
  main_text text,                   -- 主文全文（去空白，前 600 字）
  source_url text NOT NULL,         -- FJUD 裁判原文
  scraped_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_no, name)
);

CREATE INDEX IF NOT EXISTS idx_jdis_name ON judge_disciplines (name);
CREATE INDEX IF NOT EXISTS idx_jdis_date ON judge_disciplines (decided_date);

ALTER TABLE judge_disciplines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_read_jdis" ON judge_disciplines;
CREATE POLICY "auth_read_jdis" ON judge_disciplines
  FOR SELECT USING (auth.uid() IS NOT NULL);
