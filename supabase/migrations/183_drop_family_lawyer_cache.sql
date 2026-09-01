-- 183: 家事律師 cache 家族退役（IA 重整 P3-3 收尾，2026-09-01 使用者核可）
-- 「家事律師版圖」已泛化為「領域律師版圖」（mig 182 lawyer_cause_court_stats＋
--   cause_top_lawyers/cause_court_*），前端於 commit 7b7f60e 下線本家族全部引用，
--   production 驗證無回歸後執行本清理。
-- 移除：mig 035/040 底層 RPC、mig 049 五年 cache、mig 055 年 cache 全家族。
-- 保留：family_judge_stats() / family_cases_by_year()（家事「分析」頁與專業法庭仍在用，
--   屬法官統計、非本家族）。
-- ETL 呼叫點（scripts/judgment_stats.py refresh_stats、.github/workflows/judgment-causefill.yml）
--   已同步移除 'refresh_family_lawyer_stats'——本 migration 與該 commit 需一起上。

DROP FUNCTION IF EXISTS refresh_family_lawyer_stats();
DROP FUNCTION IF EXISTS family_lawyer_stats();
DROP FUNCTION IF EXISTS family_lawyer_by_court();
DROP FUNCTION IF EXISTS family_lawyer_stats_by_year();
DROP FUNCTION IF EXISTS family_lawyer_by_court_by_year();
DROP FUNCTION IF EXISTS family_lawyer_years();

DROP TABLE IF EXISTS family_lawyer_stats_cache;
DROP TABLE IF EXISTS family_lawyer_by_court_cache;
DROP TABLE IF EXISTS family_lawyer_year_cache;
DROP TABLE IF EXISTS family_lawyer_by_court_year_cache;
