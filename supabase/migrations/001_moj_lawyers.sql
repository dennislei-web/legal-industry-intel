-- ============================================================
-- MOJ 律師名冊（法務部 lawyerbc.moj.gov.tw 全量爬取結果）
-- ============================================================
-- 設計原則：
-- 1. 不動現有 law_firms / lawyers / lawsnote_lawyers 等表
-- 2. MOJ 資料獨立一張 moj_lawyers，作為現役律師 ground truth
-- 3. 事務所以「正規化名稱」為 dedupe key（MOJ 的 office 欄位已是登記全名）
-- 4. 提供新 RPC moj_firm_statistics 供前端切換
-- ============================================================

CREATE TABLE IF NOT EXISTS moj_lawyers (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  -- 律師證號（唯一）
  lic_no TEXT NOT NULL UNIQUE,
  -- 姓名
  name TEXT NOT NULL,
  -- 性別
  sex TEXT,
  -- 事務所名稱（MOJ 登記原文）
  office TEXT,
  -- 正規化事務所名稱（去空白、去「律師未提供」等佔位）
  office_normalized TEXT,
  -- 所屬公會（可能多個）
  guild_names TEXT[],
  -- 主要地區（從公會推斷）
  main_region TEXT,
  -- 法院（部分律師會顯示）
  court TEXT[],
  -- 原始資料
  raw_data JSONB,
  scraped_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_moj_lawyers_name ON moj_lawyers(name);
CREATE INDEX IF NOT EXISTS idx_moj_lawyers_office_norm ON moj_lawyers(office_normalized);
CREATE INDEX IF NOT EXISTS idx_moj_lawyers_region ON moj_lawyers(main_region);

-- RLS：登入者可讀
ALTER TABLE moj_lawyers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_moj_lawyers" ON moj_lawyers
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- Trigger：自動更新 updated_at
CREATE TRIGGER moj_lawyers_updated_at BEFORE UPDATE ON moj_lawyers
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- RPC：事務所統計（從 MOJ 律師聚合）
-- ============================================================
CREATE OR REPLACE FUNCTION moj_firm_statistics()
RETURNS TABLE (
  firm_name TEXT,
  lawyer_count BIGINT,
  main_region TEXT,
  guild_names TEXT[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    office_normalized AS firm_name,
    COUNT(*)::BIGINT AS lawyer_count,
    MODE() WITHIN GROUP (ORDER BY main_region) AS main_region,
    ARRAY_AGG(DISTINCT g) FILTER (WHERE g IS NOT NULL) AS guild_names
  FROM moj_lawyers
  LEFT JOIN LATERAL UNNEST(guild_names) AS g ON TRUE
  WHERE office_normalized IS NOT NULL
    AND office_normalized <> ''
  GROUP BY office_normalized
  ORDER BY lawyer_count DESC;
$$;

-- ============================================================
-- RPC：MOJ 地區分布
-- ============================================================
CREATE OR REPLACE FUNCTION moj_region_distribution()
RETURNS TABLE (
  region TEXT,
  count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(main_region, '未分類') AS region,
    COUNT(*)::BIGINT AS count
  FROM moj_lawyers
  GROUP BY main_region
  ORDER BY count DESC;
$$;

-- ============================================================
-- RPC：公會律師人數統計（從 MOJ）
-- ============================================================
CREATE OR REPLACE FUNCTION moj_guild_statistics()
RETURNS TABLE (
  guild_name TEXT,
  lawyer_count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g AS guild_name,
    COUNT(DISTINCT lic_no)::BIGINT AS lawyer_count
  FROM moj_lawyers
  LEFT JOIN LATERAL UNNEST(guild_names) AS g ON TRUE
  WHERE g IS NOT NULL AND g <> ''
  GROUP BY g
  ORDER BY lawyer_count DESC;
$$;

-- 授權匿名/auth 呼叫 RPC
GRANT EXECUTE ON FUNCTION moj_firm_statistics() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION moj_region_distribution() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION moj_guild_statistics() TO anon, authenticated;
