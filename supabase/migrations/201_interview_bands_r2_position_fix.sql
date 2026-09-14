-- ============================================================
-- 201: 面試筆記市場帶 r2 — 職位分類修正（雷皓明 2026-09-14 指出「受僱律師」與「實習律師（含轉受僱）」被拆成兩列）
-- ============================================================
-- 原因：bands.ps1 的職位分類把所有含「實習」的職位（含「實習律師→受僱律師」31 筆）都歸實習律師，
--       但這些人回報的是受僱薪（50–80 千元），與純實習薪（30–36）混在一格；「受僱律師」列則只剩外部直聘者。
-- 修正：含實習且有 受僱／受雇／轉正／正職／→ 字樣者歸 lawyer（受僱律師，含實習轉正）；純實習才是 trainee-lawyer。
--       重算後 publishable 63 格數字＋加班費＋喆律層，版本 v1r2-38chunks 取代 v1-38chunks；
--       兩條 peer facts（崇錦、吳弘鵬「實習→受僱 55–60 千元」）的維度同步由 comp.trainee_pay 改 comp.associate_pay_band。
-- 前端標籤同步：lawyer＝「受僱律師（含實習轉正）」、trainee-lawyer＝「實習律師（實習期間）」。
BEGIN;

DELETE FROM interview_market_bands WHERE source_version = 'v1-38chunks';

INSERT INTO interview_market_bands (note_id, dimension_key, level, size_band, position_kind, year, unit, n_entries, n_candidates, n_firms, median, p25, p75, cat_counts, verified_share, source_version)
SELECT n.id, b.dimension_key, b.level, b.size_band, b.position_kind, b.year::int, b.unit, b.n_entries::int, b.n_candidates::int, b.n_firms::int, b.median::numeric, b.p25::numeric, b.p75::numeric, b.cat_counts::jsonb, b.verified_share::int, b.source_version FROM
  (SELECT id FROM firm_field_notes WHERE channel = '面試筆記彙整' AND interviewed_on = DATE '2026-09-14' ORDER BY id DESC LIMIT 1) n,
  (VALUES
  ('comp.staff_pay_band', 'band×pos×year', '1-3', 'legal-staff-admin', 115, '千元/月', 4, 4, 4, 35.8, NULL, NULL, NULL, 100, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos×year', '4-10', 'legal-staff-admin', 115, '千元/月', 3, 3, 3, 35, NULL, NULL, NULL, 67, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos×year', '4-10', 'lawyer', 115, '千元/月', 7, 7, 7, 60, 60, 70, NULL, 100, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos×year', '11-30', 'lawyer', 115, '千元/月', 3, 3, 3, 58, NULL, NULL, NULL, 100, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos×year', '1-3', 'lawyer', 115, '千元/月', 6, 6, 5, 60, 60, 60, NULL, 83, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos×year', '1-3', 'lawyer', 114, '千元/月', 6, 6, 6, 65, 62, 65, NULL, 50, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos×year', '4-10', 'lawyer', 114, '千元/月', 12, 12, 10, 60, 60, 65, NULL, 83, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos×year', '11-30', 'lawyer', 114, '千元/月', 7, 7, 5, 60, 60, 60, NULL, 71, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos×year', '4-10', 'legal-staff-admin', 113, '千元/月', 7, 6, 7, 35, 30, 42, NULL, 0, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos×year', '1-3', 'legal-staff-admin', 113, '千元/月', 6, 6, 6, 32.5, 27.5, 35, NULL, 0, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos', 'unknown', 'legal-staff-admin', NULL, '千元/月', 6, 6, 0, 32, 31, 32, NULL, 50, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos', '1-3', 'legal-staff-admin', NULL, '千元/月', 12, 12, 12, 35.5, 28.59, 37, NULL, 42, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos', '4-10', 'legal-staff-admin', NULL, '千元/月', 12, 11, 12, 35, 30, 44, NULL, 33, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'band×pos', '31+', 'legal-staff-admin', NULL, '千元/月', 5, 4, 5, 35, NULL, NULL, NULL, 0, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos', '4-10', 'lawyer', NULL, '千元/月', 19, 19, 17, 60, 60, 70, NULL, 89, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos', '11-30', 'lawyer', NULL, '千元/月', 10, 10, 8, 60, 58, 60, NULL, 80, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos', '1-3', 'lawyer', NULL, '千元/月', 12, 12, 11, 63.5, 60, 70, NULL, 67, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'band×pos', 'unknown', 'lawyer', NULL, '千元/月', 4, 4, 0, 68, NULL, NULL, NULL, 75, 'v1r2-38chunks'),
  ('comp.trainee_pay', 'band×pos', '4-10', 'trainee-lawyer', NULL, '千元/月', 3, 3, 2, 30, NULL, NULL, NULL, 33, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'pos×year', 'all', 'legal-staff-admin', 115, '千元/月', 10, 9, 8, 36.5, 33, 38, NULL, 80, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'pos×year', 'all', 'part-time', 115, '千元/月', 3, 3, 2, 34, NULL, NULL, NULL, 67, 'v1r2-38chunks'),
  ('comp.trainee_pay', 'pos×year', 'all', 'trainee-lawyer', 115, '千元/月', 4, 4, 3, 32.5, NULL, NULL, NULL, 75, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'pos×year', 'all', 'lawyer', 115, '千元/月', 19, 19, 16, 60, 60, 71, NULL, 89, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'pos×year', 'all', 'lawyer', 114, '千元/月', 28, 26, 22, 61, 60, 70, NULL, 68, 'v1r2-38chunks'),
  ('comp.trainee_pay', 'pos×year', 'all', 'trainee-lawyer', 114, '千元/月', 7, 6, 4, 33, 30, 35, NULL, 86, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'pos×year', 'all', 'legal-staff-admin', 114, '千元/月', 7, 7, 5, 37, 32, 38, NULL, 57, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'pos×year', 'all', 'legal-staff-admin', 113, '千元/月', 19, 15, 17, 32, 30, 35, NULL, 0, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'pos', 'all', 'legal-staff-admin', NULL, '千元/月', 36, 31, 30, 35, 31, 38, NULL, 33, 'v1r2-38chunks'),
  ('comp.staff_pay_band', 'pos', 'all', 'part-time', NULL, '千元/月', 4, 4, 3, 32.5, NULL, NULL, NULL, 75, 'v1r2-38chunks'),
  ('comp.trainee_pay', 'pos', 'all', 'trainee-lawyer', NULL, '千元/月', 11, 10, 7, 33, 30, 35, NULL, 82, 'v1r2-38chunks'),
  ('comp.associate_pay_band', 'pos', 'all', 'lawyer', NULL, '千元/月', 47, 45, 38, 60, 60, 70, NULL, 77, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', 'unknown', 'legal-staff-admin', NULL, '月', 22, 19, 0, 9.5, 7, 16, NULL, 45, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '1-3', 'legal-staff-admin', NULL, '月', 35, 30, 34, 10, 5, 20, NULL, 34, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '11-30', 'part-time', NULL, '月', 5, 5, 4, 9, 2, 12, NULL, 40, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '4-10', 'legal-staff-admin', NULL, '月', 24, 22, 22, 20.5, 7, 45, NULL, 38, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '31+', 'legal-staff-admin', NULL, '月', 6, 5, 6, 12.5, 12, 13, NULL, 17, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '11-30', 'legal-staff-admin', NULL, '月', 7, 6, 7, 13, 7, 15, NULL, 43, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '4-10', 'part-time', NULL, '月', 8, 8, 7, 6, 2, 11, NULL, 25, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '1-3', 'part-time', NULL, '月', 8, 8, 8, 4, 2, 4, NULL, 12, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '11-30', 'trainee-lawyer', NULL, '月', 10, 10, 10, 6, 5, 6, NULL, 70, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '4-10', 'lawyer', NULL, '月', 25, 25, 22, 14, 7, 34, NULL, 92, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '4-10', 'trainee-lawyer', NULL, '月', 14, 14, 13, 6, 6, 6, NULL, 50, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', 'unknown', 'trainee-lawyer', NULL, '月', 7, 7, 0, 5, 3, 6, NULL, 71, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '11-30', 'lawyer', NULL, '月', 14, 13, 11, 14.5, 9, 26, NULL, 64, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', 'unknown', 'lawyer', NULL, '月', 6, 6, 0, 3.5, 1, 4, NULL, 67, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '1-3', 'lawyer', NULL, '月', 26, 24, 21, 13.5, 9, 18, NULL, 65, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '1-3', 'trainee-lawyer', NULL, '月', 17, 17, 15, 6, 6, 6, NULL, 59, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '31+', 'lawyer', NULL, '月', 3, 3, 2, 18, NULL, NULL, NULL, 0, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '31+', 'trainee-lawyer', NULL, '月', 5, 5, 4, 6, 5, 6, NULL, 20, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', 'unknown', 'part-time', NULL, '月', 6, 5, 0, 1.5, 1, 2, NULL, 67, 'v1r2-38chunks'),
  ('talent.tenure', 'band×pos', '31+', 'part-time', NULL, '月', 3, 3, 3, 10, NULL, NULL, NULL, 33, 'v1r2-38chunks'),
  ('talent.tenure', 'pos', 'all', 'legal-staff-admin', NULL, '月', 94, 65, 69, 12, 7, 22, NULL, 37, 'v1r2-38chunks'),
  ('talent.tenure', 'pos', 'all', 'part-time', NULL, '月', 30, 28, 22, 4, 2, 10, NULL, 33, 'v1r2-38chunks'),
  ('talent.tenure', 'pos', 'all', 'other', NULL, '月', 5, 4, 2, 5, NULL, NULL, NULL, 20, 'v1r2-38chunks'),
  ('talent.tenure', 'pos', 'all', 'trainee-lawyer', NULL, '月', 53, 52, 42, 6, 5, 6, NULL, 57, 'v1r2-38chunks'),
  ('talent.tenure', 'pos', 'all', 'lawyer', NULL, '月', 74, 61, 56, 13, 8, 27, NULL, 72, 'v1r2-38chunks'),
  ('comp.bonus_months', 'band×pos', '1-3', 'legal-staff-admin', NULL, '月', 3, 3, 3, 1.5, NULL, NULL, NULL, 33, 'v1r2-38chunks'),
  ('comp.bonus_months', 'band×pos', '4-10', 'legal-staff-admin', NULL, '月', 4, 4, 4, 1, NULL, NULL, NULL, 50, 'v1r2-38chunks'),
  ('comp.bonus_months', 'band×pos', '11-30', 'lawyer', NULL, '月', 7, 7, 6, 2, 1.5, 2, NULL, 71, 'v1r2-38chunks'),
  ('comp.bonus_months', 'band×pos', '1-3', 'lawyer', NULL, '月', 7, 7, 6, 1, 0, 1.5, NULL, 57, 'v1r2-38chunks'),
  ('comp.bonus_months', 'band×pos', '4-10', 'lawyer', NULL, '月', 10, 10, 9, 1.5, 0, 2, NULL, 90, 'v1r2-38chunks'),
  ('comp.bonus_months', 'pos', 'all', 'legal-staff-admin', NULL, '月', 10, 9, 9, 1.5, 1, 1.5, NULL, 40, 'v1r2-38chunks'),
  ('comp.bonus_months', 'pos', 'all', 'lawyer', NULL, '月', 25, 24, 22, 2, 1, 2, NULL, 72, 'v1r2-38chunks'),
  ('comp.overtime_pay', 'pos', 'all', 'legal-staff-admin', NULL, '件', 10, 10, NULL, NULL, NULL, NULL, '{"有":6,"無":4,"補休":0}', NULL, 'v1r2-38chunks'),
  ('comp.overtime_pay', 'pos', 'all', 'lawyer', NULL, '件', 26, 25, NULL, NULL, NULL, NULL, '{"有":6,"無":20,"補休":0}', NULL, 'v1r2-38chunks'),
  ('comp.overtime_pay', 'band×pos', '4-10', 'legal-staff-admin', NULL, '件', 5, 5, NULL, NULL, NULL, NULL, '{"有":3,"無":2,"補休":0}', NULL, 'v1r2-38chunks'),
  ('comp.overtime_pay', 'band×pos', '4-10', 'lawyer', NULL, '件', 11, 11, NULL, NULL, NULL, NULL, '{"有":3,"無":8,"補休":0}', NULL, 'v1r2-38chunks'),
  ('comp.overtime_pay', 'band×pos', '11-30', 'lawyer', NULL, '件', 6, 6, NULL, NULL, NULL, NULL, '{"有":1,"無":5,"補休":0}', NULL, 'v1r2-38chunks'),
  ('comp.overtime_pay', 'band×pos', '1-3', 'lawyer', NULL, '件', 8, 8, NULL, NULL, NULL, NULL, '{"有":2,"無":6,"補休":0}', NULL, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法務', 115, '千元/月', 18, 18, NULL, 40, 37, 43, NULL, 83, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '律師', 115, '千元/月', 23, 23, NULL, 65, 60, 75, NULL, 74, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '客戶關係', 115, '千元/月', 14, 14, NULL, 45, 44, 45, NULL, 0, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法顧律師', 115, '千元/月', 8, 8, NULL, 85, 75, 100, NULL, 100, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '律師', 114, '千元/月', 29, 29, NULL, 68, 60, 70, NULL, 59, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法務', 114, '千元/月', 28, 28, NULL, 35.5, 35, 40, NULL, 21, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法顧律師', 114, '千元/月', 9, 9, NULL, 60, 60, 65, NULL, 100, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '人資', 114, '千元/月', 7, 7, NULL, 42, 35, 50, NULL, 0, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role×year', 'zhelu', '法務', 113, '千元/月', 71, 59, NULL, 35, 33, 40, NULL, 14, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '法務', NULL, '千元/月', 117, 105, NULL, 36, 35, 40, NULL, 26, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '律師', NULL, '千元/月', 52, 52, NULL, 65, 60, 72, NULL, 65, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '客戶關係', NULL, '千元/月', 14, 14, NULL, 45, 44, 45, NULL, 0, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '法顧律師', NULL, '千元/月', 17, 17, NULL, 75, 60, 80, NULL, 100, 'v1r2-38chunks'),
  ('talent.applicant_expected_pay', 'role', 'zhelu', '人資', NULL, '千元/月', 7, 7, NULL, 42, 35, 50, NULL, 0, 'v1r2-38chunks')
  ) AS b(dimension_key, level, size_band, position_kind, year, unit, n_entries, n_candidates, n_firms, median, p25, p75, cat_counts, verified_share, source_version);

UPDATE firm_field_facts SET dimension_key = 'comp.associate_pay_band', value_num = 5.5, value_qual = '~',
  value_text = '實習→受僱 5.5–6 萬／月（試用 5.5、正式 5.8、受僱 6）'
WHERE subject_firm = '崇錦法律事務所' AND dimension_key = 'comp.trainee_pay'
  AND note_id = (SELECT id FROM firm_field_notes WHERE channel = '面試筆記彙整' ORDER BY id DESC LIMIT 1);

UPDATE firm_field_facts SET dimension_key = 'comp.associate_pay_band', value_num = 6, value_qual = '=',
  value_text = '實習→受僱 6 萬／月；三節各 1 萬、年終 1 個月；有加班費、配公務機（2 筆一致）'
WHERE subject_firm = '吳弘鵬律師事務所' AND dimension_key = 'comp.trainee_pay'
  AND note_id = (SELECT id FROM firm_field_notes WHERE channel = '面試筆記彙整' ORDER BY id DESC LIMIT 1);

COMMIT;
