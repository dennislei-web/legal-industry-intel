-- 懲戒記錄異動入 moj_lawyer_changes（2026-10-31）
--
-- 起因：詳細頁每週掃描（moj_detail_sweep.py）發現官網懲戒記錄改成「無」時，直接把
-- moj_lawyers.discipline 清成 NULL；異動追蹤只記事務所與執業狀態，舊內容就此消失
-- （10-31 首次全量掃描 7 筆「懲戒記錄移除」，事後已查不到原本是哪幾筆懲戒）。
--
-- 改法：由 trigger 記錄（任何寫入路徑都會記、OLD 值在同一交易拿到），change_type 新增
-- 'discipline_change'，舊／新內容原樣存 old_discipline／new_discipline（舊管線是 MOJ HTML
-- 片段、帶決議書連結 ID；新站是純文字）。
--
-- 判定「有沒有變」比的是案號集合（「112年度台覆字第12號」這類字串），不是整串文字：
-- 舊 HTML → 新站純文字的格式換新不會被當成異動，但同時新增／撤銷一筆案號仍抓得到。
-- 兩邊都抽不到案號時才退回比去標籤後的文字。「無」與空字串都當成沒有懲戒。

ALTER TABLE moj_lawyer_changes
  ADD COLUMN IF NOT EXISTS old_discipline text,
  ADD COLUMN IF NOT EXISTS new_discipline text;

ALTER TABLE moj_lawyer_changes DROP CONSTRAINT IF EXISTS moj_lawyer_changes_change_type_check;
ALTER TABLE moj_lawyer_changes ADD CONSTRAINT moj_lawyer_changes_change_type_check
  CHECK (change_type IN ('firm_change', 'new_lawyer', 'state_change', 'discipline_change'));

-- 去標籤＋壓空白；空字串／「無」→ NULL
CREATE OR REPLACE FUNCTION moj_disc_text(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(NULLIF(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '<[^>]*>', ' ', 'g'),
                                            '\s+', ' ', 'g')), ''), '無')
$$;

-- 案號集合（排序去重）；抽不到回 NULL
CREATE OR REPLACE FUNCTION moj_disc_cases(p text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT array_agg(DISTINCT m[1] ORDER BY m[1])
  FROM regexp_matches(coalesce(moj_disc_text(p), ''), '(\d{2,3}年度\S{1,6}?字第\d+號)', 'g') AS m
$$;

CREATE OR REPLACE FUNCTION public.log_moj_lawyer_change()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  d_old text;
  d_new text;
  c_old text[];
  c_new text[];
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO moj_lawyer_changes (lic_no, name, change_type, new_office, new_state)
    VALUES (NEW.lic_no, NEW.name, 'new_lawyer', NEW.office_normalized, NEW.state_desc);
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.office_normalized IS DISTINCT FROM OLD.office_normalized THEN
      INSERT INTO moj_lawyer_changes (lic_no, name, change_type, old_office, new_office)
      VALUES (NEW.lic_no, NEW.name, 'firm_change', OLD.office_normalized, NEW.office_normalized);
    END IF;
    IF NEW.state_desc IS DISTINCT FROM OLD.state_desc AND OLD.state_desc IS NOT NULL THEN
      INSERT INTO moj_lawyer_changes (lic_no, name, change_type, old_state, new_state)
      VALUES (NEW.lic_no, NEW.name, 'state_change', OLD.state_desc, NEW.state_desc);
    END IF;
    IF NEW.discipline IS DISTINCT FROM OLD.discipline THEN
      d_old := moj_disc_text(OLD.discipline);
      d_new := moj_disc_text(NEW.discipline);
      c_old := moj_disc_cases(OLD.discipline);
      c_new := moj_disc_cases(NEW.discipline);
      IF (d_old IS NULL) <> (d_new IS NULL)
         OR (c_old IS NOT NULL OR c_new IS NOT NULL) AND c_old IS DISTINCT FROM c_new
         OR (c_old IS NULL AND c_new IS NULL) AND d_old IS DISTINCT FROM d_new THEN
        INSERT INTO moj_lawyer_changes (lic_no, name, change_type, old_discipline, new_discipline)
        VALUES (NEW.lic_no, NEW.name, 'discipline_change', OLD.discipline, NEW.discipline);
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
