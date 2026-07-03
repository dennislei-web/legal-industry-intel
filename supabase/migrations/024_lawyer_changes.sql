-- 律師異動追蹤：事務所變更 / 新進律師 / 執業狀態變更
-- 由 moj_lawyers 上的 trigger 自動記錄，不需要改任何爬蟲程式

CREATE TABLE IF NOT EXISTS moj_lawyer_changes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lic_no text NOT NULL,
  name text,
  change_type text NOT NULL CHECK (change_type IN ('firm_change', 'new_lawyer', 'state_change')),
  old_office text,
  new_office text,
  old_state text,
  new_state text,
  changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lawyer_changes_changed_at ON moj_lawyer_changes (changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_lawyer_changes_lic_no ON moj_lawyer_changes (lic_no);

ALTER TABLE moj_lawyer_changes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated_read_lawyer_changes" ON moj_lawyer_changes;
CREATE POLICY "authenticated_read_lawyer_changes" ON moj_lawyer_changes
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- trigger：office_normalized 或 state 真的變了才記錄（IS DISTINCT FROM 可正確處理 NULL）
CREATE OR REPLACE FUNCTION log_moj_lawyer_change() RETURNS trigger AS $$
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
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS moj_lawyers_log_change ON moj_lawyers;
CREATE TRIGGER moj_lawyers_log_change
  AFTER INSERT OR UPDATE ON moj_lawyers
  FOR EACH ROW EXECUTE FUNCTION log_moj_lawyer_change();
