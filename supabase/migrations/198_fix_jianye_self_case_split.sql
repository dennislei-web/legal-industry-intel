-- 198: 修正 197 誤植——建業自案拆分是「所 9：律師 1」（雷皓明 2026-09-13 糾正），與寰瀛同型
BEGIN;
UPDATE firm_field_facts
SET value_text = '自案拆分 9:1＝建業拿 9 成、律師拿 1 成（受訪者親歷；與寰瀛「律師 1：所 9」同型）',
    db_crosscheck = '與寰瀛受僱律師口述（律師 1：所 9）互證：中大型所自案幾乎全歸所'
WHERE dimension_key = 'comp.self_case_split' AND subject_scope = 'peer' AND subject_firm = '建業法律事務所';
UPDATE firm_field_notes
SET summary = replace(summary, '自案拆分 9:1。', '自案拆分所 9：律師 1。')
WHERE firm = '新凱國際法律事務所' AND interviewed_on = DATE '2023-01-01';
COMMIT;
