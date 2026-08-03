-- 專業法庭切 tab 慢的根治：法官名單 RPC 改 jsonb 單發版
-- 原因：PostgREST 對 RPC 的 range 分頁是「每頁重跑整個聚合再切片」，
--       cat_judge_stats(刑事) 3,000+ 列 → fetchAllRpc 串行 4+ 頁 × ~1.4s ≈ 6s。
-- jsonb 回傳是單一值，不受 max-rows=1000 上限：聚合只跑一次、一趟往返抓完。
-- 包裝既有 RPC（口徑/過濾完全沿用 mig 126/132），行為差異只有傳輸形狀。

CREATE OR REPLACE FUNCTION cat_judge_stats_json(p_cat text DEFAULT NULL, p_court_like text DEFAULT NULL)
RETURNS jsonb AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
  FROM cat_judge_stats(p_cat, p_court_like) t;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cat_judge_stats_json(text, text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION cat_judge_stats_json(text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION subcat_judge_stats_json(p_category text)
RETURNS jsonb AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
  FROM subcat_judge_stats(p_category) t;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION subcat_judge_stats_json(text) SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION subcat_judge_stats_json(text) TO anon, authenticated;
