-- 246：書記官特考 115 年列（2026-10-07 榜示）＋「正額／增額錄取」兩欄（考試院公報口徑）
--   官方來源：考試院公報第 45 卷第 49 期（115-10-07）「115 年公務人員特種考試司法人員、法務部
--   調查局調查人員及海岸巡防人員考試錄取人員名單」（選特二字第 1151500790 號）——
--   四等法院書記官 970 名＝正額錄取 557＋增額錄取 413；三等法院書記官第一試 30 名
--   （115 年首度開缺，到考 106，須再口試後定案，不入本表、前端文字提及）。
--   報考 3,835／到考 2,552＝公職王＋三民輔考兩源一致（考選部各類科到考數無單獨公告）；
--   錄取率 970÷2,552＝38.01%（口徑同歷年：錄取÷到考，非÷報考）。
--   quota_regular＝考前需用正額（原暫定 373＋7 月增列 182＝555）、quota_extra＝榜示前擬增額 402
--   （TKB 引考選部），與 113/114 列同口徑（113：541/150→錄取 548/156；114：519/213→536/222）。
--   新欄 pass_regular／pass_extra＝榜示正額／增額錄取（公報），113–115 回填，108–112 留 NULL。
--   年更 SOP：10 月上旬放榜 → gazette.exam.gov.tw「國家考試錄取(及格)人員榜(名)單」抓公報 PDF，
--   PyMuPDF 抽文字後 grep「法院書記官類科」「正額錄取」「增額錄取」（數字為中文大寫）。

ALTER TABLE clerk_exam_stats ADD COLUMN IF NOT EXISTS pass_regular int;
ALTER TABLE clerk_exam_stats ADD COLUMN IF NOT EXISTS pass_extra int;
COMMENT ON COLUMN clerk_exam_stats.quota_regular IS '考前需用正額（含考前增列）';
COMMENT ON COLUMN clerk_exam_stats.quota_extra   IS '榜示前公告擬增額';
COMMENT ON COLUMN clerk_exam_stats.pass_regular  IS '榜示正額錄取（考試院公報）';
COMMENT ON COLUMN clerk_exam_stats.pass_extra    IS '榜示增額錄取（考試院公報）';
COMMENT ON COLUMN clerk_exam_stats.pass_rate     IS '錄取率 %＝final_pass÷takers（到考）';

INSERT INTO clerk_exam_stats (year_roc, applicants, takers, quota_regular, quota_extra, final_pass, pass_rate, pass_regular, pass_extra) VALUES
  (115, 3835, 2552, 555, 402, 970, 38.01, 557, 413)
ON CONFLICT (year_roc) DO UPDATE SET
  applicants = EXCLUDED.applicants, takers = EXCLUDED.takers,
  quota_regular = EXCLUDED.quota_regular, quota_extra = EXCLUDED.quota_extra,
  final_pass = EXCLUDED.final_pass, pass_rate = EXCLUDED.pass_rate,
  pass_regular = EXCLUDED.pass_regular, pass_extra = EXCLUDED.pass_extra;

UPDATE clerk_exam_stats SET pass_regular = 536, pass_extra = 222 WHERE year_roc = 114;
UPDATE clerk_exam_stats SET pass_regular = 548, pass_extra = 156 WHERE year_roc = 113;
