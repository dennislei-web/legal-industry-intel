-- refresh_judge_judgment_stats() 撞 role 預設 statement_timeout（57014）
-- mig 123 加了 doctype_total/1y/5y 三組 jsonb 彙總後執行時間超過 8s 上限，
-- doctypefill 完成後 workflow 的 refresh 連兩天靜默 500（job 只印狀態碼不擋）。
-- 比照 046/049 慣例掛 function-level timeout。

ALTER FUNCTION refresh_judge_judgment_stats() SET statement_timeout = '600s';
