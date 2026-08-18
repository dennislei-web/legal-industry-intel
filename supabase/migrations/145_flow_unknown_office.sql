-- ============================================================
-- 145: 人才流動 KPI 排除「未登錄事務所」（空白／佔位字串「律師未顯示」）
-- ============================================================
-- 問題：法務部名冊未登錄或不公開事務所時，office 欄可能是空白，
--   2026-08-13 起爬蟲改寫入字面值「律師未顯示」（同 migration 142 的佔位字串）。
--   firm_flow_summary() 的 entering/leaving 只判斷「是不是事務所」，
--   於是「未登錄」被當成「企業/公職」：
--     離開執業 117 筆中有 66 筆其實是 office 變空白（未必離開執業）
--     進入執業  48 筆中有 29 筆其實是 office 由空白首次登錄
--   佔位字串上線後這個誤計只會持續擴大。
--
-- 修法：新增 flow_is_unknown()，entering/leaving 兩端都要求「已知」才計入，
--   讓 KPI 回到字面語意（事務所 ↔ 具名企業/公職/機構）。
--   另回傳 to_unknown / from_unknown 兩個計數，讓前端可揭露被排除的量。
--
-- ranking / matrix / intake 不需改：flow_is_firm() 天然排除佔位字串與空白。

-- 未登錄：NULL / 空白 / 官方佔位字串，語意皆為「不知道在哪」
CREATE OR REPLACE FUNCTION flow_is_unknown(office text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT office IS NULL OR btrim(office) = '' OR btrim(office) = '律師未顯示';
$$;

-- = 083 原版，僅 entering/leaving 加「另一端須為已知」條件 + 兩個新計數
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
    -- 進入執業：具名的非事務所（企業/公職/機構）→ 事務所
    'entering', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND NOT flow_is_firm(old_office) AND NOT flow_is_unknown(old_office)
        AND flow_is_firm(new_office)),
    -- 離開執業：事務所 → 具名的非事務所
    'leaving', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND flow_is_firm(old_office)
        AND NOT flow_is_firm(new_office) AND NOT flow_is_unknown(new_office)),
    -- 離所後去向未登錄（不等於離開執業，僅供揭露）
    'to_unknown', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND flow_is_firm(old_office) AND flow_is_unknown(new_office)),
    -- 原本未登錄、本期登錄事務所（不等於進入執業，僅供揭露）
    'from_unknown', (SELECT count(*) FROM win WHERE change_type='firm_change'
        AND flow_is_unknown(old_office) AND flow_is_firm(new_office)),
    'new_lawyers', (SELECT count(*) FROM win WHERE change_type='new_lawyer')
  );
$$;

GRANT EXECUTE ON FUNCTION flow_is_unknown(text)  TO authenticated, anon;
GRANT EXECUTE ON FUNCTION firm_flow_summary(int) TO authenticated;
