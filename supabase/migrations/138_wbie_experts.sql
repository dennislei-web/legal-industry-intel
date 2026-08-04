-- 138: 職安署「職場霸凌調查專業人士資料庫」每日同步（wbie）＋ B2B 戰情頁後端
-- 資料源：https://etms.osha.gov.tw/wbie/ExpertSearch/GetQualifiedExperts
--（單一 GET 全量 JSON，2026-08-04 實測 1,040 筆；篩選全在前端做，無分頁）
-- 權限設計：
--   wbie_experts / wbie_sync_log = 官方公開名冊與同步統計 → authenticated 可讀
--   wbie_watchlist / b2b_kpi_entries = 內部戰略內容（報名名單/競品清單/KPI）
--     → admin 限定（仿 117 ip_watchlist；資料鎖在 DB，前端 repo 是 public 不可硬編碼）

BEGIN;

-- ============ 1. 名冊主表 ============
CREATE TABLE IF NOT EXISTS wbie_experts (
  id bigint PRIMARY KEY,               -- 官方系統 id
  name text NOT NULL,
  gender text,
  identity text,                       -- 培訓身分（執業律師/心理師/仲裁調解委員…八類）
  email text,
  unit text,                           -- 服務單位
  title text,                          -- 職稱
  phone text,
  is_discount boolean,                 -- 官方 isDiscount 旗標（意義未明，照存）
  areas text[] NOT NULL DEFAULT '{}',  -- 可參與調查區域
  is_zhelu boolean NOT NULL DEFAULT false,      -- unit 含喆律 或 watchlist zhelu 名單命中
  is_competitor boolean NOT NULL DEFAULT false, -- unit 命中 watchlist competitor 關鍵字
  competitor_firm text,                -- 命中的競品歸戶名
  is_lawyer boolean,                   -- 與 moj_lawyers 姓名比對（同名可能誤判，估組成用）
  first_seen date NOT NULL DEFAULT CURRENT_DATE,
  last_seen date NOT NULL DEFAULT CURRENT_DATE,
  removed_at date,                     -- 從名冊消失日（再出現自動清空）
  updated_at timestamptz NOT NULL DEFAULT now(),
  raw jsonb
);
CREATE INDEX IF NOT EXISTS idx_wbie_experts_unit ON wbie_experts (unit);
CREATE INDEX IF NOT EXISTS idx_wbie_experts_identity ON wbie_experts (identity);

ALTER TABLE wbie_experts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wbie_experts_read ON wbie_experts;
CREATE POLICY wbie_experts_read ON wbie_experts
  FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);

COMMENT ON TABLE wbie_experts IS '職安署職場霸凌調查專業人士名冊（每日同步；官方公開資料）';

-- ============ 2. 同步日誌（筆數防呆＋趨勢曲線資料源） ============
CREATE TABLE IF NOT EXISTS wbie_sync_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sync_date date NOT NULL DEFAULT CURRENT_DATE,
  status text NOT NULL DEFAULT 'ok',   -- ok / blocked（筆數異變拒絕寫入）/ error
  total_count int NOT NULL,
  new_count int NOT NULL DEFAULT 0,
  removed_count int NOT NULL DEFAULT 0,
  changed_count int NOT NULL DEFAULT 0,
  zhelu_count int NOT NULL DEFAULT 0,
  competitor_count int NOT NULL DEFAULT 0,
  lawyer_count int,
  milestones jsonb,                    -- 喆律/競品入庫事件（dashboard 通知卡讀這裡）
  details jsonb,                       -- 新增/移除/異動明細
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wbie_sync_log_date ON wbie_sync_log (sync_date DESC);

ALTER TABLE wbie_sync_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wbie_sync_log_read ON wbie_sync_log;
CREATE POLICY wbie_sync_log_read ON wbie_sync_log
  FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);

-- ============ 3. 觀察名單（admin 限定：報名名單＋競品清單） ============
CREATE TABLE IF NOT EXISTS wbie_watchlist (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category text NOT NULL CHECK (category IN ('zhelu', 'competitor')),
  name text,                           -- zhelu：律師全名
  firm_keyword text,                   -- competitor：unit 比對關鍵字
  firm_label text,                     -- competitor：歸戶顯示名
  note text,                           -- 完訓/報名場次等狀態（人工維護）
  sort int NOT NULL DEFAULT 0,
  UNIQUE (category, name, firm_keyword)
);

ALTER TABLE wbie_watchlist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wbie_watchlist_admin_read ON wbie_watchlist;
CREATE POLICY wbie_watchlist_admin_read ON wbie_watchlist
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );
DROP POLICY IF EXISTS wbie_watchlist_admin_write ON wbie_watchlist;
CREATE POLICY wbie_watchlist_admin_write ON wbie_watchlist
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

COMMENT ON TABLE wbie_watchlist IS 'B2B 霸凌線觀察名單（admin 限定）：喆律報名律師＋競品事務所關鍵字';

-- 喆律 115 年培訓報名名單（Playbook 第九章；note=2026-08-03 已知狀態）
INSERT INTO wbie_watchlist (category, name, note, sort) VALUES
  ('zhelu', '陳映臻', '高雄場已完訓', 1),
  ('zhelu', '蘇端雅', '高雄場已完訓', 2),
  ('zhelu', '黃書炫', '雲嘉南場 7/31-8/1', 3),
  ('zhelu', '林品妘', '7 月底場', 4),
  ('zhelu', '張元毓', '台北場 8/23-24', 5),
  ('zhelu', '林桑羽', '台北場 8/23-24', 6),
  ('zhelu', '張文祈', '台北場 8/23-24', 7),
  ('zhelu', '廖懿涵', '候補，8/10 通知', 8),
  ('zhelu', '陶光星', '台北四場 10/24-25', 9),
  ('zhelu', '柯雪莉', '未在報名名單、2026-08-04 發現已入庫', 10)
ON CONFLICT DO NOTHING;

-- 競品事務所（競品深度分析報告八所口徑＋人資顧問報告警戒線）
INSERT INTO wbie_watchlist (category, firm_keyword, firm_label, note, sort) VALUES
  ('competitor', '勝綸',   '勝綸',   '13 人/人均 120 件，唯一正面對手（含勝綸企管顧問）', 20),
  ('competitor', '宇恒',   '宇恒',   '17 人法顧訂閱工廠', 21),
  ('competitor', '瑋燁',   '瑋燁',   '翁瑋實質一人所', 22),
  ('competitor', '業鑫',   '業鑫',   '訴訟集中陳業鑫/張仁興 2 人', 23),
  ('competitor', '有澤',   '有澤',   '36 人高端顧問棲位', 24),
  ('competitor', '理致',   '理致',   '高雄卡位對手', 25),
  ('competitor', '圓矩',   '圓矩',   '×Hahow 聯名已上線', 26),
  ('competitor', '和一健康', '和一健康', '非律師侵入警戒線（新北勞檢專家入場輔導得標者）', 27)
ON CONFLICT DO NOTHING;

-- ============ 4. 戰略 KPI 手填表（admin 限定） ============
CREATE TABLE IF NOT EXISTS b2b_kpi_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  metric text NOT NULL,        -- 指標名（演講場次/名單數/健檢/首單/入庫人數/漏斗段…）
  period text NOT NULL,        -- 期間標籤（'90d' 或 '2026-08' 等）
  actual numeric,              -- 實測值（手填）
  target numeric,              -- 目標值
  assumption numeric,          -- 假設值（漏斗轉化率用，%）
  unit_label text,             -- 單位（場/人/件/%）
  note text,
  sort int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (metric, period)
);

ALTER TABLE b2b_kpi_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS b2b_kpi_admin_read ON b2b_kpi_entries;
CREATE POLICY b2b_kpi_admin_read ON b2b_kpi_entries
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );
DROP POLICY IF EXISTS b2b_kpi_admin_write ON b2b_kpi_entries;
CREATE POLICY b2b_kpi_admin_write ON b2b_kpi_entries
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND role = 'admin')
  );

COMMENT ON TABLE b2b_kpi_entries IS 'B2B 霸凌線 90 天 KPI＋漏斗假設 vs 實測（admin 限定手填）';

-- KPI@90 天目標（Playbook v3.3 第十章）
INSERT INTO b2b_kpi_entries (metric, period, target, unit_label, note, sort) VALUES
  ('演講場次（帶 CTA 規格）', '90d', 6,   '場', NULL, 1),
  ('名單數',                  '90d', 150, '人', '掃碼留資累計', 2),
  ('合規健檢',                '90d', 25,  '件', NULL, 3),
  ('首單成交',                '90d', 8,   '件', '50 萬+ 營收', 4),
  ('人才庫入庫',              '90d', 3,   '人', '在途 9 人；2026-08-04 已 4 人達標', 5),
  ('法顧報價',                '90d', 3,   '家', NULL, 6)
ON CONFLICT (metric, period) DO NOTHING;

-- 漏斗四段假設值（Playbook v3.3 第七章；actual 待首季實測回填）
INSERT INTO b2b_kpi_entries (metric, period, assumption, unit_label, note, sort) VALUES
  ('漏斗①到場→掃碼留資',   'funnel', 40, '%', '實體活動 QR 領講義行規 30-50% 取中值', 11),
  ('漏斗②留資→合規健檢',   'funnel', 17.5, '%', 'B2B 名單→約談常見區間 10-25%，採 15-20%', 12),
  ('漏斗③健檢→首單',       'funnel', 27.5, '%', '喆律 B2C 免費諮詢→委任經驗外推，採 25-30%（均價 6 萬）', 13),
  ('漏斗④首單→年內二單',   'funnel', 40, '%', '折抵設計目標值', 14)
ON CONFLICT (metric, period) DO NOTHING;

-- ============ 5. 資料來源頁登錄 ============
INSERT INTO data_sources (name, url, description, data_type, scraper_name, update_frequency, is_active, notes)
SELECT '職安署霸凌調查專業人士資料庫', 'https://etms.osha.gov.tw/wbie/ExpertSearch/SearchIndex',
       '職場霸凌調查專業人士官方名冊（姓名/培訓身分/服務單位/區域）', 'experts',
       'wbie_sync', 'daily', true, '每日台北凌晨同步（wbie-sync.yml）；筆數異變防呆 exit 2'
WHERE NOT EXISTS (SELECT 1 FROM data_sources WHERE scraper_name = 'wbie_sync');

COMMIT;
