-- 092: TIPO 商標/專利代理件數（個別代理人×年、事務所×年）
-- 資料源：TIPO 開放資料 FTPS（TmarkAppl / PatentPub / PatentRightsM / PatentRightsD）
-- 產線：scripts/tipo_agent_fetch.py（下載）→ scripts/tipo_agent_stats.py（聚合上傳，整表重建）
-- 口徑：year_tw=申請案號前三碼（民國申請年）；kind: tm=商標申請、pt=專利（發明公開＋新型/設計公告）
--       firm/identity 為「現行代理人名簿」join（現任口徑，名簿外者為 NULL）

CREATE TABLE IF NOT EXISTS tipo_agent_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('tm', 'pt')),
  agent_name text NOT NULL,
  year_tw int NOT NULL,
  cases int NOT NULL,
  firm text,
  identity text,
  is_lawyer boolean NOT NULL DEFAULT false,
  UNIQUE (kind, agent_name, year_tw)
);
CREATE INDEX IF NOT EXISTS idx_tipo_agent_rank ON tipo_agent_stats (kind, year_tw, cases DESC);
CREATE INDEX IF NOT EXISTS idx_tipo_agent_name ON tipo_agent_stats (agent_name);

CREATE TABLE IF NOT EXISTS tipo_firm_stats (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('tm', 'pt')),
  firm text NOT NULL,
  year_tw int NOT NULL,
  cases int NOT NULL,
  agents_n int NOT NULL,
  UNIQUE (kind, firm, year_tw)
);
CREATE INDEX IF NOT EXISTS idx_tipo_firm_rank ON tipo_firm_stats (kind, year_tw, cases DESC);

ALTER TABLE tipo_agent_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE tipo_firm_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tipo_agent_stats_read ON tipo_agent_stats;
CREATE POLICY tipo_agent_stats_read ON tipo_agent_stats FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS tipo_firm_stats_read ON tipo_firm_stats;
CREATE POLICY tipo_firm_stats_read ON tipo_firm_stats FOR SELECT TO anon, authenticated USING (true);
