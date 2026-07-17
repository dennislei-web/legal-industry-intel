-- 企業法務（in-house）市場：MOJ 登錄反查（律師區＞異動追蹤＞企業法務雷達）
-- 口徑：state_desc='正常' 且未除名的登錄律師，office_normalized 非事務所體系者。
-- ⚠️ 這是「保留執業登錄的 in-house」＝下限估計——多數企業法務不維持登錄，
--    絕對量遠低於真實 in-house 人數；價值在「誰在養登錄律師」與世代結構訊號。
-- 全部即時聚合（moj_lawyers ~1.3 萬列，無需物化表）；異動流向吃 moj_lawyer_changes
--（2026-07-03 起追蹤）會隨時間增值。

-- 雇主類型（依序先中先贏；NULL/空字串回 NULL＝未提供）
CREATE OR REPLACE FUNCTION employer_kind(emp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp IS NULL OR emp = '' THEN NULL
  WHEN emp ~ '公職律師' THEN '政府與公職'
  WHEN emp ~ '律師公會' THEN '非營利與公協會'
  WHEN emp ~ '法律扶助' THEN '非營利與公協會'
  WHEN emp ~ '事務所|法律工場|律師樓' THEN '事務所'
  WHEN emp ~ '財團法人|社團法人|基金會|協會|公會|工會|農會|漁會|策進會|保護中心' THEN '非營利與公協會'
  WHEN emp ~ '總統府|行政院|立法院|司法院|考試院|監察院|政府|公所|議會|法院|檢察署|地檢署|警察|國防部|法務部|外交部|財政部|教育部|經濟部|交通部|勞動部|內政部|衛生福利部|文化部|環境部|農業部|數位發展部|海洋委員會|國稅局|關務署|健保署|勞保局|戶政|監理' THEN '政府與公職'
  WHEN emp ~ '大學|學院|高級中學|高中|國中|國小|學校' THEN '學研機構'
  WHEN emp ~ '銀行|保險|人壽|產物|證券|投信|投顧|金控|金融|期貨|票券|租賃|資融|資產管理|創投|資本|交易所|櫃檯買賣|集中保管|農金' THEN '金融保險'
  WHEN emp ~ '公司|商行|商號|企業社|工作室|醫院|診所' THEN '一般企業'
  ELSE '其他'
END $$;

-- 雇主名歸戶（(股)公司/股份有限公司統一、去分公司分會、法扶各分會歸總會）
CREATE OR REPLACE FUNCTION norm_employer(emp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp ~ '法律扶助基金會' THEN '法律扶助基金會'
  ELSE regexp_replace(regexp_replace(regexp_replace(
    regexp_replace(coalesce(emp, ''), '[\s　]', '', 'g'),
    '[（(]股[）)]公司', '股份有限公司'),
    '(股份有限公司)?[一-龥A-Za-z]{0,8}(分公司|分行|分會)$', ''),
    '(股份有限公司|有限公司)$', '')
END $$;

-- 總覽：非事務所登錄的類型分布＋取證世代結構（in-house 佔比）
CREATE OR REPLACE FUNCTION inhouse_summary()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
WITH act AS (
  SELECT employer_kind(office_normalized) AS kind,
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

-- 雇主排行（歸戶後）：n、平均取證年、名單（鑽取用，前 60 名）
CREATE OR REPLACE FUNCTION inhouse_top_employers(p_kind text DEFAULT NULL, p_limit int DEFAULT 30)
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (
  SELECT norm_employer(office_normalized) AS emp,
         min(employer_kind(office_normalized)) AS kind,
         count(*)::int AS n,
         round(avg((regexp_match(lic_no, '^(\d{2,3})'))[1]::int), 1) AS avg_lic_year,
         (array_agg(name ORDER BY lic_no))[1:60] AS names
  FROM moj_lawyers
  WHERE state_desc = '正常' AND deregistered_at IS NULL
    AND employer_kind(office_normalized) NOT IN ('事務所')
    AND employer_kind(office_normalized) IS NOT NULL
    AND (p_kind IS NULL OR employer_kind(office_normalized) = p_kind)
  GROUP BY 1 ORDER BY n DESC, 1 LIMIT p_limit
) t $$;
ALTER FUNCTION inhouse_top_employers(text, int) SET statement_timeout = '30s';

-- 近期事務所↔非事務所異動（雙向；moj_lawyer_changes，2026-07-03 起）
CREATE OR REPLACE FUNCTION inhouse_recent_moves(p_days int DEFAULT 90, p_limit int DEFAULT 60)
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (
  SELECT name, old_office, new_office, changed_at::date AS changed_on,
         CASE WHEN employer_kind(new_office) NOT IN ('事務所') THEN 'out' ELSE 'in' END AS direction,
         CASE WHEN employer_kind(new_office) NOT IN ('事務所')
              THEN employer_kind(new_office) ELSE employer_kind(old_office) END AS kind
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change'
    AND changed_at >= now() - make_interval(days => p_days)
    AND old_office IS NOT NULL AND new_office IS NOT NULL
    AND employer_kind(old_office) IS NOT NULL AND employer_kind(new_office) IS NOT NULL
    AND (employer_kind(old_office) = '事務所') <> (employer_kind(new_office) = '事務所')
  ORDER BY changed_at DESC LIMIT p_limit
) t $$;
ALTER FUNCTION inhouse_recent_moves(int, int) SET statement_timeout = '30s';

GRANT EXECUTE ON FUNCTION inhouse_summary() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inhouse_top_employers(text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inhouse_recent_moves(int, int) TO anon, authenticated;
