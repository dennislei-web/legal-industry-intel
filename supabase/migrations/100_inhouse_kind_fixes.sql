-- 企業法務雷達分類修正（096 的 follow-up）：清掉「其他」類的誤入雜訊
-- 1) 個人名義掛牌（登錄名=「○○○律師」）＝獨立執業，歸事務所體系，不再誤入 in-house
-- 2) 登錄名＝律師本名（如「倪煥淑」）同上——單參數函式看不到本名，加 (emp, lawyer_name) 雙參數版供 RPC 用
-- 3) 外國律所（LLP 結尾、律師行、Mayer Brown JSM、Davis&Davis）歸事務所
-- 4) 研究院/工研院→學研機構；營運處/總管理處/法務處/集團/有線電視/企業→一般企業；聯合會→非營利與公協會

CREATE OR REPLACE FUNCTION employer_kind(emp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp IS NULL OR emp = '' THEN NULL
  WHEN emp ~ '公職律師' THEN '政府與公職'
  WHEN emp ~ '律師公會|聯合會' THEN '非營利與公協會'
  WHEN emp ~ '法律扶助' THEN '非營利與公協會'
  WHEN emp ~ '事務所|法律工場|律師樓|律師行|法務所|律師所|事務務所|律師服務處' THEN '事務所'
  WHEN emp ~ '^[一-龥]{1,4}(大)?律師$' OR emp ~ '法律$' THEN '事務所'  -- 個人名義掛牌／「○○法律」簡寫＝獨立執業
  WHEN emp ~* '(LLP)$' OR emp ~* '^(MayerbrownJSM|Davis&Davis)$' THEN '事務所'  -- 外國律所（名冊已去空白）
  WHEN emp ~ '財團法人|社團法人|基金會|協會|公會|工會|農會|漁會|策進會|保護中心' THEN '非營利與公協會'
  WHEN emp ~ '總統府|行政院|立法院|司法院|考試院|監察院|政府|公所|議會|法院|檢察署|地檢署|警察|國防部|法務部|外交部|財政部|教育部|經濟部|交通部|勞動部|內政部|衛生福利部|文化部|環境部|農業部|數位發展部|海洋委員會|國稅局|關務署|健保署|勞保局|戶政|監理|行政法人|國家住宅及都市更新中心' THEN '政府與公職'
  WHEN emp ~ '大學|學院|高級中學|高中|國中|國小|學校|工研院|研究院' THEN '學研機構'
  WHEN emp ~ '銀行|保險|人壽|產物|證券|投信|投顧|金控|金融|期貨|票券|租賃|資融|資產管理|創投|資本|交易所|櫃檯買賣|集中保管|農金' THEN '金融保險'
  WHEN emp ~ '公司|商行|商號|企業社|工作室|醫院|診所|營運處|總管理處|法務處|集團|有線電視|企業|科技|電子|光電|半導體|能源|通訊|製藥|生技|DHL' THEN '一般企業'
  ELSE '其他'
END $$;

-- 雙參數版：登錄名＝本名（±「律師」）視為獨立執業（事務所體系）
CREATE OR REPLACE FUNCTION employer_kind(emp text, lawyer_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp IS NULL OR emp = '' THEN NULL
  WHEN lawyer_name IS NOT NULL AND lawyer_name <> ''
       AND regexp_replace(emp, '[\s　]', '', 'g') IN (lawyer_name, lawyer_name || '律師', lawyer_name || '大律師', lawyer_name || '聯絡處', lawyer_name || '律師聯絡處')
    THEN '事務所'
  ELSE employer_kind(emp)
END $$;

-- 三支 RPC 改用雙參數版（其餘邏輯不變）
CREATE OR REPLACE FUNCTION inhouse_summary()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
WITH act AS (
  SELECT employer_kind(office_normalized, name) AS kind,
         (regexp_match(lic_no, '^(\d{2,3})'))[1]::int AS ly
  FROM moj_lawyers
  WHERE state_desc = '正常' AND deregistered_at IS NULL
), cohort AS (
  SELECT CASE WHEN ly < 80 THEN '79年前' WHEN ly < 90 THEN '80-89'
              WHEN ly < 100 THEN '90-99' WHEN ly < 110 THEN '100-109'
              ELSE '110後' END AS bucket,
         min(ly) AS ord,
         count(*) AS total,
         count(*) FILTER (WHERE kind NOT IN ('事務所') AND kind IS NOT NULL) AS non_firm
  FROM act WHERE ly IS NOT NULL GROUP BY 1
)
SELECT json_build_object(
  'total_active', (SELECT count(*) FROM act),
  'no_office',    (SELECT count(*) FROM act WHERE kind IS NULL),
  'by_kind', (SELECT coalesce(json_agg(json_build_object('kind', kind, 'n', n) ORDER BY n DESC), '[]'::json)
              FROM (SELECT kind, count(*) AS n FROM act WHERE kind IS NOT NULL AND kind <> '事務所' GROUP BY 1) k),
  'by_cohort', (SELECT coalesce(json_agg(json_build_object('bucket', bucket, 'total', total, 'non_firm', non_firm) ORDER BY ord), '[]'::json)
                FROM cohort)
) $$;
ALTER FUNCTION inhouse_summary() SET statement_timeout = '30s';

CREATE OR REPLACE FUNCTION inhouse_top_employers(p_kind text DEFAULT NULL, p_limit int DEFAULT 30)
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (
  SELECT norm_employer(office_normalized) AS emp,
         min(employer_kind(office_normalized, name)) AS kind,
         count(*)::int AS n,
         round(avg((regexp_match(lic_no, '^(\d{2,3})'))[1]::int), 1) AS avg_lic_year,
         (array_agg(name ORDER BY lic_no))[1:60] AS names
  FROM moj_lawyers
  WHERE state_desc = '正常' AND deregistered_at IS NULL
    AND employer_kind(office_normalized, name) NOT IN ('事務所')
    AND employer_kind(office_normalized, name) IS NOT NULL
    AND (p_kind IS NULL OR employer_kind(office_normalized, name) = p_kind)
  GROUP BY 1 ORDER BY n DESC, 1 LIMIT p_limit
) t $$;
ALTER FUNCTION inhouse_top_employers(text, int) SET statement_timeout = '30s';

CREATE OR REPLACE FUNCTION inhouse_recent_moves(p_days int DEFAULT 90, p_limit int DEFAULT 60)
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (
  SELECT name, old_office, new_office, changed_at::date AS changed_on,
         CASE WHEN employer_kind(new_office, name) NOT IN ('事務所') THEN 'out' ELSE 'in' END AS direction,
         CASE WHEN employer_kind(new_office, name) NOT IN ('事務所')
              THEN employer_kind(new_office, name) ELSE employer_kind(old_office, name) END AS kind
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change'
    AND changed_at >= now() - make_interval(days => p_days)
    AND old_office IS NOT NULL AND new_office IS NOT NULL
    AND employer_kind(old_office, name) IS NOT NULL AND employer_kind(new_office, name) IS NOT NULL
    AND (employer_kind(old_office, name) = '事務所') <> (employer_kind(new_office, name) = '事務所')
  ORDER BY changed_at DESC LIMIT p_limit
) t $$;
ALTER FUNCTION inhouse_recent_moves(int, int) SET statement_timeout = '30s';
