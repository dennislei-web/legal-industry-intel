-- 律師事務所人才流動（挖角矩陣）
-- 資料源：moj_lawyer_changes（moj_lawyers 上的 trigger 自 2026-07-03 起追蹤 firm_change）
-- firm_key 口徑對齊 offices tab 的 firmKeyRe：截到第一個 (法律|律師)事務所 合併分所（建業高雄所→建業）
-- 分類：
--   firm→firm  = 跨所移動（挖角/出走），矩陣與淨流動排行只計這類
--   非firm→firm = 進入執業（企業法務/公職/新掛靠 回事務所）
--   firm→非firm = 離開執業（去企業/公職/退）

-- office 正規化為 firm_key（NULL-safe）
CREATE OR REPLACE FUNCTION flow_firm_key(office text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN office IS NULL OR btrim(office) = '' THEN NULL
    ELSE coalesce(substring(office FROM '^.+?(?:法律|律師)事務所'), office)
  END;
$$;

-- 是否為執業事務所（含「事務所」字樣）
CREATE OR REPLACE FUNCTION flow_is_firm(office text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT office IS NOT NULL AND office LIKE '%事務所%';
$$;

-- KPI 摘要
CREATE OR REPLACE FUNCTION firm_flow_summary(p_days int DEFAULT 3650)
RETURNS json LANGUAGE sql STABLE AS $$
  WITH win AS (
    SELECT change_type, old_office, new_office
    FROM moj_lawyer_changes
    WHERE changed_at >= now() - make_interval(days => p_days)
  )
  SELECT json_build_object(
    'tracking_since', (SELECT min(changed_at)::date FROM moj_lawyer_changes),
    'firm_to_firm', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND flow_is_firm(old_office) AND flow_is_firm(new_office)
        AND flow_firm_key(old_office) IS DISTINCT FROM flow_firm_key(new_office)),
    'entering', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND NOT flow_is_firm(old_office) AND flow_is_firm(new_office)),
    'leaving', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND flow_is_firm(old_office) AND NOT flow_is_firm(new_office)),
    'new_lawyers', (SELECT count(*) FROM win WHERE change_type='new_lawyer')
  );
$$;

-- 事務所淨流動排行：只計 firm→firm 真實跨所移動
CREATE OR REPLACE FUNCTION firm_flow_ranking(p_days int DEFAULT 3650)
RETURNS TABLE(firm_key text, moved_in int, moved_out int, net int)
LANGUAGE sql STABLE AS $$
  WITH mv AS (
    SELECT flow_firm_key(old_office) AS from_k,
           flow_firm_key(new_office) AS to_k
    FROM moj_lawyer_changes
    WHERE change_type = 'firm_change'
      AND changed_at >= now() - make_interval(days => p_days)
      AND flow_is_firm(old_office) AND flow_is_firm(new_office)
  ), mv2 AS (
    SELECT from_k, to_k FROM mv WHERE from_k IS DISTINCT FROM to_k
  ), ins AS (
    SELECT to_k AS fk, count(*)::int AS c FROM mv2 GROUP BY to_k
  ), outs AS (
    SELECT from_k AS fk, count(*)::int AS c FROM mv2 GROUP BY from_k
  )
  SELECT coalesce(i.fk, o.fk) AS firm_key,
         coalesce(i.c,0) AS moved_in,
         coalesce(o.c,0) AS moved_out,
         coalesce(i.c,0) - coalesce(o.c,0) AS net
  FROM ins i FULL OUTER JOIN outs o ON i.fk = o.fk
  ORDER BY (coalesce(i.c,0) - coalesce(o.c,0)) DESC, coalesce(i.c,0) DESC;
$$;

-- 流動矩陣：A所→B所 邊（抓團隊出走，如 聯誠→義鑫）
CREATE OR REPLACE FUNCTION firm_flow_matrix(p_days int DEFAULT 3650, p_min int DEFAULT 1)
RETURNS TABLE(from_firm text, to_firm text, n int)
LANGUAGE sql STABLE AS $$
  SELECT flow_firm_key(old_office) AS from_firm,
         flow_firm_key(new_office) AS to_firm,
         count(*)::int AS n
  FROM moj_lawyer_changes
  WHERE change_type = 'firm_change'
    AND changed_at >= now() - make_interval(days => p_days)
    AND flow_is_firm(old_office) AND flow_is_firm(new_office)
    AND flow_firm_key(old_office) IS DISTINCT FROM flow_firm_key(new_office)
  GROUP BY 1,2
  HAVING count(*) >= p_min
  ORDER BY count(*) DESC, from_firm, to_firm;
$$;

GRANT EXECUTE ON FUNCTION flow_firm_key(text)      TO authenticated, anon;
GRANT EXECUTE ON FUNCTION flow_is_firm(text)       TO authenticated, anon;
GRANT EXECUTE ON FUNCTION firm_flow_summary(int)   TO authenticated;
GRANT EXECUTE ON FUNCTION firm_flow_ranking(int)   TO authenticated;
GRANT EXECUTE ON FUNCTION firm_flow_matrix(int,int) TO authenticated;
