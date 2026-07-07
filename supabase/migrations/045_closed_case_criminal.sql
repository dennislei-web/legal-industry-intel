-- 終結案件微資料：納入地院刑事訴訟檔（closed_case_stats.py 擴充）
-- file_type='刑事訴訟' 的列語意：
--   total_cases    = 地院刑事訴訟終結案件數（一、二審訴訟案類，only 資料夾名含「地方法院」）
--   defendant_rep  = 案內任一被告「選任律師辯護」（含-法律扶助）的案件數 → 有委任律師口徑
--   plaintiff_rep  = 自訴人有律師代理件數（案件層欄 22）
--   both_rep       = 0（刑事無兩造概念）
--   defense        = 被告層「辯護及代理」值分布（被告數計，含公設辯護人/義務律師細分）
-- 民事/家事列 defense 為 NULL。
-- 高院/最高/智財刑事檔版式不同（被告層辯護欄位置不同），不解析。

ALTER TABLE closed_case_month_stats ADD COLUMN IF NOT EXISTS defense jsonb;

COMMENT ON COLUMN closed_case_month_stats.defense IS
  '刑事訴訟檔被告層「辯護及代理」分布（被告數計）：選任律師辯護/選任律師辯護-法律扶助/公設辯護人辯護/義務律師辯護/無';

-- 法院名正規化：202101~202506 月包資料夾名帶「民事/刑事」後綴（「臺灣臺北地方法院民事」），
-- 202507 起無後綴。去後綴＋去空格，與 courts.name / court_case_stats 對齊
-- （已驗證去後綴後無 (yyyymm, court_name, file_type) 唯一鍵衝突；冪等）。
-- closed_case_stats.py 的 norm_court() 同步做相同正規化，防未來月包格式回退。
UPDATE closed_case_month_stats
SET court_name = regexp_replace(replace(court_name, ' ', ''), '(民事|刑事)$', '')
WHERE court_name ~ '(民事|刑事)$' OR court_name LIKE '% %';
