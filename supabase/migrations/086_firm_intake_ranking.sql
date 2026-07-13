-- 新進律師去向：名冊新增律師（moj_lawyer_changes change_type='new_lawyer'，trigger 自 2026-07-03 起）
-- 依新事務所（firm_key，口徑同 083）聚合，看新血都進哪些所。與 083 挖角矩陣同一資料源、互補。
-- 依賴 083 已建的 flow_firm_key(text) / flow_is_firm(text) helper。

CREATE OR REPLACE FUNCTION firm_intake_ranking(p_days int DEFAULT 3650)
RETURNS TABLE(firm_key text, intake int)
LANGUAGE sql STABLE AS $$
  SELECT flow_firm_key(new_office) AS firm_key, count(*)::int AS intake
  FROM moj_lawyer_changes
  WHERE change_type = 'new_lawyer'
    AND changed_at >= now() - make_interval(days => p_days)
    AND flow_is_firm(new_office)
  GROUP BY 1
  ORDER BY count(*) DESC, firm_key;
$$;

GRANT EXECUTE ON FUNCTION firm_intake_ranking(int) TO authenticated;
