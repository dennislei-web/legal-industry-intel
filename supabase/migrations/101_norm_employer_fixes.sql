-- norm_employer 歸戶修正（096/100 的 follow-up）：企業法務雷達雇主排行出現空白列與異體字分裂
-- 1) 貪婪去分支後綴把短名整個吃掉：「三井住友銀行台北分行」「瑞士銀行台北分行」
--    「法國興業銀行台北分行」（≤8字＋分行）被剝成空字串，三家外商銀行還被歸成同一組。
--    改為剝完若空 → 退回只剝 2 字地名版（台北/台中…）→ 再不行保留原名。
-- 2) 台/臺異體字：「國立臺灣大學法務處」vs「國立台灣大學法務處」被分成兩組 → 歸戶前 臺→台。
-- 3) 「法扶基金會」簡寫沒被法扶特例接住（只認全稱），「法扶基金會台南分會」也被剝成空字串
--    → 特例改成全稱/簡寫都歸「法律扶助基金會」。
-- kind 判斷（employer_kind）吃原始名，不受影響；本函數僅供歸戶分組與顯示。

CREATE OR REPLACE FUNCTION norm_employer(emp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp ~ '法律扶助基金會|法扶基金會' THEN '法律扶助基金會'
  ELSE regexp_replace(
    coalesce(
      nullif(regexp_replace(e1, '(股份有限公司)?[一-龥A-Za-z]{0,8}(分公司|分行|分會)$', ''), ''),
      nullif(regexp_replace(e1, '[一-龥A-Za-z]{0,2}(分公司|分行|分會)$', ''), ''),
      e1),
    '(股份有限公司|有限公司)$', '')
END
FROM (SELECT regexp_replace(
        translate(regexp_replace(coalesce(emp, ''), '[\s　]', '', 'g'), '臺', '台'),
        '[（(]股[）)]公司', '股份有限公司') AS e1) s
$$;
