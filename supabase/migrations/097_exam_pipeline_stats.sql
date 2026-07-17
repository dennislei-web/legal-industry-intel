-- 考選部先行指標：律師考試／司法官考試歷年報考與及格（律師區＞供給預測 tab）
-- 律師二試及格 → 職前訓練 → 隔年前後執業登錄，是「新科律師進場」的前緣 1–2 年領先指標。
-- 資料源與驗證：
--   * 114 年＝考選部官方統計表（wHandStatisticsFile.ashx?file_id=3477，二試及格 1,042 首度破千）
--   * 104–113 律師＝輔考機構彙整（高點/志光保成，各選試組別加總），與考選部榜示新聞稿
--     交叉核對：110=940、111=913、113=980 均吻合
--   * 106–114 司法官＝公職王彙整（三試最終錄取），111=158、113=182 與新聞稿吻合
-- 口徑注意：一試為司律合考（同卷分報），律師/司法官報考人數有大量重複報名者；
--   律師 final_pass＝二試及格、司法官 final_pass＝三試錄取；
--   108–109 律師及格低谷＝當年二試 400 分門檻刷落較多（110 年調整後無人被門檻否決）。
-- 年更方式：每年 10–11 月二試/三試放榜後手動 INSERT 一列（無自動管線）。

CREATE TABLE IF NOT EXISTS exam_pipeline_stats (
  year_roc int NOT NULL,     -- 民國年
  exam text NOT NULL,        -- 律師 / 司法官
  applicants int,            -- 一試報名
  takers int,                -- 一試到考
  stage1_pass int,           -- 一試及格/錄取
  final_pass int,            -- 律師=二試及格；司法官=三試錄取
  PRIMARY KEY (year_roc, exam)
);

ALTER TABLE exam_pipeline_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_eps" ON exam_pipeline_stats;
CREATE POLICY "read_eps" ON exam_pipeline_stats FOR SELECT USING (true);
GRANT SELECT ON exam_pipeline_stats TO anon, authenticated;

INSERT INTO exam_pipeline_stats (year_roc, exam, applicants, takers, stage1_pass, final_pass) VALUES
  (104, '律師', 10291,  8309, 2745,  822),
  (105, '律師', 10361,  8711, 2881,  860),
  (106, '律師', 11118,  9256, 3069,  924),
  (107, '律師', 10621,  8846, 2932,  759),
  (108, '律師', 10872,  8964, 3037,  549),
  (109, '律師', 11589,  9620, 3175,  650),
  (110, '律師', 11755,  9110, 3059,  940),
  (111, '律師', 11599,  9342, 3150,  913),
  (112, '律師', 12038,  9864, 3341,  988),
  (113, '律師', 12463, 10232, 3378,  980),
  (114, '律師', 13042, 10569, 3611, 1042),
  (106, '司法官',  9819,  8372, 2766,  100),
  (107, '司法官',  9418,  8029, 2665,   76),
  (108, '司法官',  9743,  8175, 2787,  106),
  (109, '司法官', 10245,  8681, 2962,  175),
  (110, '司法官', 10444,  8285, 2832,  140),
  (111, '司法官', 10241,  8440, 2817,  158),
  (112, '司法官', 10597,  8866, 2998,  201),
  (113, '司法官', 10751,  9014, 3014,  182),
  (114, '司法官', 10789,  9004, 3069,  136)
ON CONFLICT (year_roc, exam) DO UPDATE SET
  applicants = EXCLUDED.applicants, takers = EXCLUDED.takers,
  stage1_pass = EXCLUDED.stage1_pass, final_pass = EXCLUDED.final_pass;
