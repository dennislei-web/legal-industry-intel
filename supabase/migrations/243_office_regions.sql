-- 243：異動兩端的所在地區（事務所 modal「近期人員異動」顯示 台北 → 桃園 之類的地區移動）
--
-- 資料限制：moj_lawyer_changes 只記單位名稱、不記地址；main_region 是「第一個公會」推的，不是執業地。
-- moj_lawyers.address（執業處所地址）由 detail fetch 寫入，只在新發現律師時抓一次、轉所後不會更新。
-- 因此地址只在「抓地址當時人在哪個所」才有效：
--   * detail_fetched_at < 異動時間 → 地址屬於「舊所」
--   * detail_fetched_at > 異動時間 → 地址屬於「新所」
-- 每一端先用律師本人有效地址（可區分同名多地所的分處，如喆律台北／台中），
-- 沒有就退回「該單位所在地」＝當時地址屬於該單位的律師（現職未再轉入者＋已轉出者）縣市眾數。

CREATE OR REPLACE FUNCTION addr_region(p_addr text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN left(a, 2) IN ('台北','新北','桃園','台中','台南','高雄','基隆','新竹','苗栗','彰化',
                        '南投','雲林','嘉義','屏東','宜蘭','花蓮','台東','澎湖','金門','連江')
      THEN left(a, 2)
    ELSE NULL END
  FROM (SELECT replace(regexp_replace(coalesce(p_addr, ''), '^[0-9０-９\s-]+', ''), '臺', '台') AS a) s;
$$;

-- 單位所在地：地址確定屬於該單位的律師之縣市眾數；share＝眾數佔比（<0.8 視為多地所）
CREATE OR REPLACE FUNCTION office_regions(p_offices text[])
RETURNS TABLE(office text, region text, n int, share numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH o AS (SELECT DISTINCT unnest(p_offices) AS office),
  members AS (
    -- 現職：抓地址後沒有再轉入本單位
    SELECT o.office, addr_region(l.address) AS region
    FROM o JOIN moj_lawyers l ON l.office_normalized = o.office
    WHERE l.state_desc = '正常' AND l.deregistered_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM moj_lawyer_changes c
                      WHERE c.lic_no = l.lic_no AND c.change_type IN ('firm_change','new_lawyer')
                        AND c.new_office = o.office AND c.changed_at > l.detail_fetched_at)
    UNION ALL
    -- 已轉出：抓地址時還在本單位
    SELECT o.office, addr_region(l.address)
    FROM o JOIN moj_lawyer_changes c ON c.old_office = o.office AND c.change_type = 'firm_change'
    JOIN moj_lawyers l ON l.lic_no = c.lic_no
    WHERE l.detail_fetched_at < c.changed_at
      AND coalesce(l.office_normalized, '') <> o.office
  ),
  t AS (
    SELECT office, region, count(*)::int AS c FROM members
    WHERE region IS NOT NULL GROUP BY 1, 2
  )
  SELECT DISTINCT ON (t.office) t.office, t.region, t.c,
         round(t.c::numeric / sum(t.c) OVER (PARTITION BY t.office), 2)
  FROM t
  ORDER BY t.office, t.c DESC, t.region;
$$;

-- 每筆異動的兩端地區；*_src：self＝律師本人當時地址、office＝單位眾數
CREATE OR REPLACE FUNCTION change_regions(p_ids bigint[])
RETURNS TABLE(id bigint, from_region text, from_src text, from_multi boolean,
              to_region text, to_src text, to_multi boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH c AS (
    SELECT c.id, c.old_office, c.new_office, c.changed_at,
           addr_region(l.address) AS self_region, l.detail_fetched_at AS fetched
    FROM moj_lawyer_changes c LEFT JOIN moj_lawyers l USING (lic_no)
    WHERE c.id = ANY(p_ids)
  ),
  r AS (
    SELECT * FROM office_regions(
      (SELECT array_agg(x) FROM (SELECT old_office FROM c UNION SELECT new_office FROM c) s(x) WHERE x IS NOT NULL))
  )
  SELECT c.id,
    CASE WHEN c.old_office IS NULL THEN NULL
         WHEN c.fetched < c.changed_at AND c.self_region IS NOT NULL THEN c.self_region ELSE ro.region END,
    CASE WHEN c.old_office IS NULL THEN NULL
         WHEN c.fetched < c.changed_at AND c.self_region IS NOT NULL THEN 'self'
         WHEN ro.region IS NOT NULL THEN 'office' END,
    coalesce(ro.share < 0.8, false),
    CASE WHEN c.new_office IS NULL THEN NULL
         WHEN c.fetched > c.changed_at AND c.self_region IS NOT NULL THEN c.self_region ELSE rn.region END,
    CASE WHEN c.new_office IS NULL THEN NULL
         WHEN c.fetched > c.changed_at AND c.self_region IS NOT NULL THEN 'self'
         WHEN rn.region IS NOT NULL THEN 'office' END,
    coalesce(rn.share < 0.8, false)
  FROM c
  LEFT JOIN r ro ON ro.office = c.old_office
  LEFT JOIN r rn ON rn.office = c.new_office;
$$;

GRANT EXECUTE ON FUNCTION addr_region(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION office_regions(text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION change_regions(bigint[]) TO authenticated, service_role;
