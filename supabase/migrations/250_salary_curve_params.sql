-- 250：年資對年薪整合曲線的模型參數（2026-10-12）
-- 法官／檢察官曲線＝法定推算：年資 n → 俸級 max(1, 25−n)（候補自第 24 級起敘、每年職務評定良好晉一級；法官法 §71、§74）；
--   月薪＝本俸（mig 248 moj_judge_scale base_pay）＋加給；加給只有兩個錨點：第 6 級（710 俸點）＝2015 立法院例示依通案調幅推算
--   （專業 104,500＋115/7 定額 2,000＋職務 33,730）、第 24 級候補第 1 年＝民間整理月薪總額 10–11.4 萬取中點 107,000（減本俸 29,270 得加給 77,730）；
--   其餘俸級在兩錨點間線性內插、第 1–5 級順勢外推。年薪＝月薪 × 14.5（12 個月＋年終工作獎金 1.5＋職務評定良好獎金 1）。檢察官準用（§89）。
-- 律師曲線＝兩段整合：中小所層（Lawsnote 2023 分布內插＋面試筆記底薪換算，取平均）與官方申報層（勞動部法律服務業×律師全年薪資所得，
--   偏中大所；平均數先乘 Lawsnote 分布的中位／平均比換成中位），以名冊推估的受僱律師數為分母、官方調查人數為分子算權重（前端即時算）。
INSERT INTO labor_comp_series (source, role, metric, period, category, sort, stat, value, unit, n, note) VALUES
('judge_pay_model','judge','months_per_year','115','年薪月數',1,'param',14.5,'月',NULL,'12 個月＋年終工作獎金 1.5 個月＋職務評定良好獎金 1 個月（法官法 §74）'),
('judge_pay_model','judge','junior_monthly_total_est','115','候補第 1 年（第 24 級）月薪總額',1,'median_est',107000,'元/月',NULL,'民間整理 2025（候補法官／檢察官月薪約 10 萬–11.4 萬）取中點；官方加給表未取得'),
('judge_pay_model','judge','grade_per_year','115','每年晉級數',1,'param',1,'級',NULL,'法官法 §74：任職滿一年職務評定良好晉一級；連續四年良好另晉級的加速未計，屬保守'),
('judge_pay_model','judge','entry_grade','115','候補起敘級',1,'param',24,'級',NULL,'法官法 §71')
ON CONFLICT (source, role, metric, period, category, stat) DO UPDATE
  SET value = EXCLUDED.value, unit = EXCLUDED.unit, n = EXCLUDED.n, note = EXCLUDED.note, sort = EXCLUDED.sort;

DO $$
DECLARE c int;
BEGIN
  SELECT count(*) INTO c FROM labor_comp_series WHERE source = 'judge_pay_model';
  IF c <> 4 THEN RAISE EXCEPTION 'judge_pay_model rows=% (<>4)', c; END IF;
END $$;

-- 名冊事務所規模分布（mig 244）供前端算受僱律師推估數與官方調查涵蓋權重；聚合值非敏感，比照 lawyer_supply_stats 開放 anon
GRANT EXECUTE ON FUNCTION lawyer_firm_size_dist() TO anon;
