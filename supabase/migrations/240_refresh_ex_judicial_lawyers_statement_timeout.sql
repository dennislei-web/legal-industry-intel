-- ============================================================
-- 240: refresh_ex_judicial_lawyers() 補 SET statement_timeout（純 metadata，函數本體不動）
-- ============================================================
-- 事故：這支由 moj-licno-scan.yml（每週六／每月 1 日）經 .github/scripts/refresh-rpcs.sh 走
--   PostgREST RPC 呼叫。repo 內最新定義（mig 151）與線上 proconfig（2026-10-03 直連實查：只有
--   search_path=public）都沒有 SET statement_timeout → 吃 authenticator 預設的 8 秒。
--   CI log：2026-08-15～09-12 連 6 週第一次嘗試都在 8.2～9.4 秒回 HTTP 500（57014），靠 60 秒後
--   重試才 204（08-15 到第 3 次才過）；09-19／09-26／10-02 一次過（6.0～8.4 秒）。全量 DELETE＋
--   重算 upsert 本來就貼著 8 秒上限，DB 忙一點就被砍。2026-10-02 起 refresh-rpcs.sh 重試 3 次
--   仍失敗會讓 job 紅燈（main 4bb12e6），三次都超時的那天 licno-scan 就紅在最後的 gate 步驟。
--
-- 修法：比照 mig 238 第 3 段，只下 ALTER FUNCTION … SET statement_timeout（純 metadata），
--   函數本體維持 mig 151。值用 600s 與 refresh 鏈其他函數一致；實際跑 6～9 秒，CI 端 curl 的
--   --max-time 是 180 秒，600s 只是不讓 DB 端先砍。PostgREST（v14.4）會把函數層的
--   SET statement_timeout 提升成交易層設定，所以這行對 RPC 有效（CLAUDE.md「已知 Gotchas」）。
--   ⚠️ 之後用 CREATE OR REPLACE 重寫這支函數時，要把 SET statement_timeout 寫進 CREATE 裡
--      （CREATE OR REPLACE 不帶 SET 會把 proconfig 清掉，又回到 8 秒）。

BEGIN;
SET LOCAL lock_timeout = '10s';  -- 拿不到鎖就整檔失敗重來，不要卡住前端讀取

ALTER FUNCTION refresh_ex_judicial_lawyers() SET statement_timeout = '600s';

COMMIT;

-- statement_timeout 讀自 PostgREST 的 schema cache，馬上重載（否則數十秒內仍沿用 8 秒）
NOTIFY pgrst, 'reload schema';
