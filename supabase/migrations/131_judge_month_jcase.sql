-- Phase 2 細分專庭：法官×月×字別 長表 ＋ 字別→類別映射表
-- 設計主張：DB 存「正規化字別原始計數」（全字別，不只已映射者），分類映射查詢時 JOIN——
-- 之後新增專庭類別＝往 jcase_category_map INSERT＋前端加 chip，不必重跑任何解析。
-- 資料來源：jcasefill.py 回填 2020-01 起（逐案快取另存本地 .judgment_work/{ym}_jcase_cases.jsonl.gz）。

CREATE TABLE IF NOT EXISTS judge_month_jcase (
  name text NOT NULL,
  court_name text NOT NULL,
  yyyymm text NOT NULL,
  jcase text NOT NULL,
  n int NOT NULL,
  PRIMARY KEY (name, court_name, yyyymm, jcase)
);
-- 前綴比對用（RPC 內 jcase LIKE prefix || '%'）
CREATE INDEX IF NOT EXISTS idx_jmj_jcase ON judge_month_jcase (jcase text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_jmj_ym ON judge_month_jcase (yyyymm);
ALTER TABLE judge_month_jcase ENABLE ROW LEVEL SECURITY;  -- 無 anon 政策：僅 service key 寫、SECURITY DEFINER RPC 讀

-- 法院×月×字別 案件數（每案計一次、含未抽到法官的案件）——年度量/法院榜用這口徑；
-- judge_month_jcase 是法官人次口徑（合議庭一案計多法官），僅供名單/佔比。
CREATE TABLE IF NOT EXISTS court_month_jcase (
  court_name text NOT NULL,
  yyyymm text NOT NULL,
  jcase text NOT NULL,
  n int NOT NULL,
  PRIMARY KEY (court_name, yyyymm, jcase)
);
CREATE INDEX IF NOT EXISTS idx_cmj_jcase ON court_month_jcase (jcase text_pattern_ops);
ALTER TABLE court_month_jcase ENABLE ROW LEVEL SECURITY;

-- 字別→專庭類別映射（prefix 比對；exclude=true 為同類別的排除前綴）
CREATE TABLE IF NOT EXISTS jcase_category_map (
  category text NOT NULL,
  prefix text NOT NULL,
  exclude boolean NOT NULL DEFAULT false,
  note text,
  PRIMARY KEY (category, prefix)
);
ALTER TABLE jcase_category_map ENABLE ROW LEVEL SECURITY;

INSERT INTO jcase_category_map (category, prefix, exclude, note) VALUES
  ('勞動', '勞', false, '勞訴/勞簡/勞上/勞抗/勞專調/勞執/勞補/勞小/勞聲…（勞動事件法 2020-01 起）'),
  ('勞動', '勞安', true, '職業安全衛生刑事案，非勞動事件'),
  ('消債', '消債', false, '消債更/消債清/消債職聲免/消債聲/消債抗…（幾乎全為裁定）'),
  ('國民法官', '國審', false, '國審/國審強處/國審聲/國審重訴/國審交訴…（112 年起）')
ON CONFLICT (category, prefix) DO UPDATE SET exclude = EXCLUDED.exclude, note = EXCLUDED.note;
