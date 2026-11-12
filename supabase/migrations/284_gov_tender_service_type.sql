-- 284：政府標案「服務內容」分類（2026-11-12）
-- 目的：回答「律所標到的政府案件在做什麼」——訴訟、顧問、法制研究、法普……
--
-- 做法：
--   1. gov_tender_service_type(title)：只看標案名稱的「有序關鍵字規則」，先中先贏，回 12 類之一。
--      規則順序（前面的優先）：翻譯→其他；專利商標申請；訓練／執法／宣導；對民眾的法律服務；
--      「之研究／委託研究」；法遵稽核；批量訴訟委外（有「年度／開口／委外」且沒有審級、案號等個案特徵）；
--      仲裁調解；追償執行；個案訴訟；爭議／申訴；法制修法；常年顧問；專案顧問；一般法律服務；其他。
--      比對前先拿掉「研究院／研究所／訓練場／工程處…」這些機關名用字，免得「核能研究所專利申請」被當成研究案。
--   2. gov_tenders.service_type：STORED generated column，ETL（scripts/gov_tenders.py）不用改，新案 upsert 進來自動分類。
--      之後要改規則：CREATE OR REPLACE 函數後，DROP COLUMN service_type 再 ADD 一次（generated column 不會自動重算）。
--   3. gov_tender_service_stats()：只算「得標者含律師事務所」的案子（廠商名含 法律／律師，排除學校、基金會、學會、協會、研究院）。
--      金額＝律所得標者的決標金額合計；廠商層沒有金額且得標者全是律所時，退回用全案決標金額。
--
-- 準確度：隨機抽 100 件人工複核約 95 件正確。錯的多是名稱同時含兩種服務（「法律諮詢及訴訟服務」）或名稱太短。
--   招標文件的實際工作項目沒有讀，所以混合型標案只能歸到名稱最突出的那一類。
-- 驗證：本函數對全表 7,530 個標案名稱的結果，與 Python 原型逐筆比對零差異（套用當下）。
--
-- 套用前先確認 pg_stat_activity 沒有長 refresh 在跑（ADD COLUMN 會觸發 PostgREST 重載 schema，
--   見 reference_postgrest_schema_reload_lock_outage）。

BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.gov_tender_service_type(p_title text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $fn$
DECLARE
  t text := regexp_replace(coalesce(p_title, ''), '研究(院|所)|訓練場|工程(處|局|分局|司|會)', '', 'g');
  spec constant text := '字第|第[一二三123]審|[一二三]審|上訴|更[一二三123]審|更審|再審|抗告|請求|起訴|控訴|假扣押|假處分|與.{2,20}(公司|間)|不服|國外訴訟';
BEGIN
  IF t ~ '翻譯|英譯|中譯' THEN
    RETURN '其他';
  END IF;
  IF t ~ '專利|商標' AND t ~ '申請|註冊|維護|年費|申辦|費用|答辯|審查費' AND t !~ '訴訟|侵權|研究|救濟' THEN
    RETURN '智財申請維護';
  END IF;
  IF t ~ '宣導|教育訓練|人員訓練|訓練計畫|訓練班|講習|研習|課程|工作坊|講座|研討會|培訓|培育|執法|禁菸|菸害'
     AND t !~ '訴訟|仲裁|草案|條例|研擬' THEN
    RETURN '教育訓練與法普宣導';
  END IF;
  IF t ~ '法律扶助|訴訟扶助|市民.{0,6}(法律|諮詢)|民眾.{0,6}(法律|諮詢)|免費法律|法律諮詢服務站|台商|臺商|受災者|公害糾紛|原住民.{0,8}法律(服務|諮詢|扶助)|消費(者)?.{0,4}訴訟|勞資爭議.{0,10}(計畫|扶助)|勞工權益'
     AND t !~ '研究|草案' THEN
    RETURN '民眾法律服務';
  END IF;
  IF t ~ '之研究|研究案|委託研究|研究計畫' THEN
    RETURN '法制研究與修法';
  END IF;
  IF t ~ '法遵|遵循|稽核|查核' THEN
    RETURN '法遵與稽核';
  END IF;
  IF t ~ '訴訟|爭訟|訴願|行政救濟'
     AND t ~ '年度|開口|[0-9]{2,3}年|暨所屬|委外|委託民間|(處理|辦理).{0,6}(訴訟|爭訟)(案件|事件)'
     AND t !~ spec THEN
    RETURN '批量訴訟委外';
  END IF;
  IF t ~ '仲裁|調解' THEN
    RETURN '仲裁調解與履約爭議';
  END IF;
  IF t ~ '強制執行|強烈執行|支付命令|催收|追償|訴追|行政執行|續行執行|債權.*(執行|追|收|確保)|逾期(戶|放款)|拍賣|補償金|追繳|不法利得' THEN
    RETURN '債權追償與強制執行';
  END IF;
  IF t ~ (spec || '|訴訟|爭訟|訴願|告訴|辯護|求償|損害賠償|拆屋還地|返還|給付|遷讓|不當得利|國賠|國家賠償|撤銷|行政救濟|涉訟|和解|索賠|賠償|占用|佔用|侵權|平衡稅|反傾銷|事件|洩漏|救濟|行政訴') THEN
    RETURN '個案訴訟代理';
  END IF;
  IF t ~ '爭議|申訴|異議' THEN
    RETURN '仲裁調解與履約爭議';
  END IF;
  IF t ~ '研究|法制|修法|草案|研訂|研修|研析|研擬|立法|法規|法令|法.{0,6}修正|條例|自治' THEN
    RETURN '法制研究與修法';
  END IF;
  IF t ~ '常年' THEN
    RETURN '常年顧問與法律諮詢';
  END IF;
  IF t ~ '總顧問|協議書|契約.{0,4}審查|促參|促進民間參與|民間參與|民間經營|委外經營|委託經營|BOT|ROT|OT案|招商|地上權|投資|釋股|民營化|併購|合資|契約範本|(契約|合約).{0,6}(撰擬|研擬|審閱|草擬|談判)|法律暨財務|法律及財務|財務.{0,4}顧問|LNG|天然氣|購電|建設計畫|統包|工程.{0,12}法律|履約管理|終止契約|遷冊|執照|採購案.{0,6}(法律|顧問)|都市更新|開發案|標售|公司化|改制' THEN
    RETURN '專案法律顧問';
  END IF;
  IF t ~ '法律顧問|諮詢|法律意見|法律專業|法律服務|法律事務|法律.*顧問|律師|法務|法律|法津' THEN
    RETURN '常年顧問與法律諮詢';
  END IF;
  IF t ~ '政策|可行性|制度' THEN
    RETURN '法制研究與修法';
  END IF;
  RETURN '其他';
END;
$fn$;

ALTER TABLE public.gov_tenders DROP COLUMN IF EXISTS service_type;
ALTER TABLE public.gov_tenders
  ADD COLUMN service_type text GENERATED ALWAYS AS (public.gov_tender_service_type(title)) STORED;
CREATE INDEX IF NOT EXISTS idx_gov_tenders_service_type ON public.gov_tenders(service_type);

-- 服務內容統計：一次回整頁要用的東西（jsonb）
--   cats  ：各類件數／金額／中位數／單獨投標數／投標家數合計
--   years ：年 × 類 的件數與金額（前端自己併成五年一組）
--   firms ：各類近 p_recent_years 年得標金額前 3 的律所
--   units ：各類近 p_recent_years 年發案金額前 3 的機關
CREATE OR REPLACE FUNCTION public.gov_tender_service_stats(p_recent_years int DEFAULT 5)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH ff AS (
    SELECT tender_key, firm_name, is_winner, award_amount,
           (firm_name ~ '法律|律師' AND firm_name !~ '大學|學院|基金會|學會|協會|研究院') AS law
    FROM gov_tender_firms
  ), f AS (
    SELECT tender_key,
           count(*) AS nbid,
           count(*) FILTER (WHERE is_winner) AS nwin,
           count(*) FILTER (WHERE is_winner AND law) AS nlaw,
           sum(award_amount) FILTER (WHERE is_winner AND law) AS law_amt
    FROM ff GROUP BY 1
  ), base AS (
    SELECT t.tender_key, t.unit_name, t.award_year, t.service_type, f.nbid, f.nlaw,
           CASE WHEN coalesce(f.law_amt, 0) = 0 AND f.nwin = f.nlaw THEN coalesce(t.total_amount, 0)
                WHEN t.total_amount > 0 AND f.law_amt > t.total_amount AND f.nwin = f.nlaw THEN t.total_amount
                ELSE coalesce(f.law_amt, 0) END AS amt
    FROM gov_tenders t JOIN f USING (tender_key)
    WHERE f.nlaw > 0
  ), recent AS (
    SELECT * FROM base WHERE award_year >= extract(year FROM now())::int - p_recent_years
  ), cats AS (
    SELECT service_type AS cat, count(*) AS cases, sum(amt) AS amount,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY amt) FILTER (WHERE amt > 0) AS median,
           count(*) FILTER (WHERE nbid = 1) AS single_bid, sum(nbid) AS bidders,
           (SELECT count(*) FROM recent r WHERE r.service_type = b.service_type) AS cases_recent,
           (SELECT coalesce(sum(amt), 0) FROM recent r WHERE r.service_type = b.service_type) AS amount_recent
    FROM base b GROUP BY service_type
  ), yrs AS (
    SELECT award_year AS y, service_type AS cat, count(*) AS n, sum(amt) AS amt
    FROM base WHERE award_year IS NOT NULL GROUP BY 1, 2
  ), fw AS (
    SELECT r.service_type AS cat, regexp_replace(ff.firm_name, '\s+', '', 'g') AS firm,
           count(*) AS n,
           sum(CASE WHEN ff.award_amount IS NOT NULL OR r.nlaw > 1 THEN coalesce(ff.award_amount, 0) ELSE r.amt END) AS amt
    FROM recent r JOIN ff USING (tender_key)
    WHERE ff.is_winner AND ff.law
    GROUP BY 1, 2
  ), fw3 AS (
    SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY cat ORDER BY amt DESC, n DESC) AS rk FROM fw) x WHERE rk <= 3
  ), uw AS (
    SELECT service_type AS cat, unit_name AS unit, count(*) AS n, sum(amt) AS amt
    FROM recent WHERE unit_name IS NOT NULL AND unit_name <> '' GROUP BY 1, 2
  ), uw3 AS (
    SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY cat ORDER BY amt DESC, n DESC) AS rk FROM uw) x WHERE rk <= 3
  )
  SELECT jsonb_build_object(
    'scope', (SELECT jsonb_build_object('cases', count(*), 'amount', sum(amt),
                                        'all_cases', (SELECT count(*) FROM gov_tenders),
                                        'min_year', min(award_year), 'max_year', max(award_year),
                                        'recent_from', extract(year FROM now())::int - p_recent_years) FROM base),
    'cats',  (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.cases DESC) FROM cats c),
    'years', (SELECT jsonb_agg(jsonb_build_array(y, cat, n, amt) ORDER BY y, cat) FROM yrs),
    'firms', (SELECT jsonb_agg(jsonb_build_object('cat', cat, 'firm', firm, 'n', n, 'amt', amt) ORDER BY cat, rk) FROM fw3),
    'units', (SELECT jsonb_agg(jsonb_build_object('cat', cat, 'unit', unit, 'n', n, 'amt', amt) ORDER BY cat, rk) FROM uw3)
  );
$$;
ALTER FUNCTION public.gov_tender_service_stats(int) SET statement_timeout = '60s';

-- 權限：比照 mig 271，匿名不可直打
REVOKE EXECUTE ON FUNCTION public.gov_tender_service_stats(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.gov_tender_service_stats(int) TO authenticated, service_role;

COMMIT;
