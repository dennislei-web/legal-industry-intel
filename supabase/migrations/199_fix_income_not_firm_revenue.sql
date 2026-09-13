-- 199: 修正 197 口徑——Excel「營收/個人收入」欄全是受訪者個人（或其單位）收入，不是全所營收
-- （雷皓明 2026-09-13 糾正：多為合署靠行律師，不能拿來評估全所營收）。六筆 fin.revenue 全改 fin.personal_income，
-- 移除與 firm_analysis_facts 營收推估的對照，notes.summary 同步改字。
BEGIN;
UPDATE firm_field_facts f SET
  dimension_key = 'fin.personal_income',
  db_crosscheck = NULL,
  value_text = CASE
    WHEN n.firm = '眾勤法律事務所' THEN '受訪者（北所主持律師）個人收入約 2,000 萬（原表「營收/個人收入」欄；非全所營收）'
    WHEN n.firm = '威律法律事務所' THEN '受訪者（主持律師）個人收入約 1,500 萬（非全所營收）'
    WHEN n.firm = '宇恒法律事務所' THEN '受訪者（主持律師）自述收入「接近 1 億？」——原表帶問號，個人口徑、僅供參考'
    WHEN n.firm = '立勤國際法律事務所' AND f.value_num = 6000 THEN '受訪者（劉韋廷，合署制下自己的單位 20–30 人）自述收入「據稱 6,000 萬」（非全所營收）'
    WHEN n.firm = '立勤國際法律事務所' THEN '受訪者（黃沛聲，自己的單位 10 人以下）自述收入 2,000–3,000 萬（非全所營收）'
    WHEN n.firm = '成鼎律師事務所' THEN '受訪者（主持律師）個人收入約 1,000 萬（非全所營收）'
    ELSE f.value_text END
FROM firm_field_notes n
WHERE n.id = f.note_id AND f.dimension_key = 'fin.revenue';

UPDATE firm_field_notes SET summary = replace(summary, '北所營收約 2,000 萬', '個人收入約 2,000 萬') WHERE firm = '眾勤法律事務所';
UPDATE firm_field_notes SET summary = replace(summary, '所營收約 1,500 萬', '個人收入約 1,500 萬') WHERE firm = '威律法律事務所' AND summary LIKE '%所營收約 1,500 萬%';
UPDATE firm_field_notes SET summary = replace(summary, '營收「接近 1 億？」（存疑）', '自述收入「接近 1 億？」（個人口徑、存疑）') WHERE firm = '宇恒法律事務所';
UPDATE firm_field_notes SET summary = replace(summary, '營收據稱 6,000 萬', '劉本人單位收入據稱 6,000 萬') WHERE firm = '立勤國際法律事務所' AND summary LIKE '%營收據稱 6,000 萬%';
UPDATE firm_field_notes SET summary = replace(summary, '單位營收 2,000–3,000 萬', '黃本人單位收入 2,000–3,000 萬') WHERE firm = '立勤國際法律事務所' AND summary LIKE '%單位營收 2,000–3,000 萬%';
UPDATE firm_field_notes SET summary = replace(summary, '營收約 1,000 萬；', '個人收入約 1,000 萬；') WHERE firm = '成鼎律師事務所';

UPDATE field_note_dimensions SET description = '受僱薪資、獨立律師或主持律師的個人（或其單位）年收——拜訪名單「營收/個人收入」欄一律歸此，不得當全所營收' WHERE key = 'fin.personal_income';
UPDATE field_note_dimensions SET description = '受訪者明確以「全所」口徑自述的營收才填；個人或單位收入請用 fin.personal_income' WHERE key = 'fin.revenue';
COMMIT;
