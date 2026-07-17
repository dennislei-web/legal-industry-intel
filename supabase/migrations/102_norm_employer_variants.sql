-- norm_employer 歸戶 v3（101 的 follow-up）：合併寫法變體＋修分行剝除的舊傷
-- 1) 括號正規化：(股)公司/(股)有限公司→股份有限公司；丟「句尾括號註記」
--    （台南市立醫院(委託秀傳醫療社團法人經營)→台南市立醫院）；再拆殘餘括號字元
--    （匯豐(台灣)商業銀行→匯豐台灣商業銀行，與「匯豐台灣商業銀行(股)公司」合組）。
-- 2) 國別商前綴：美商/法商/瑞士商/英屬○○商…去前綴——「瑞士商瑞士銀行」與
--    「瑞士銀行台北分行」（同一家 UBS）合組；也治好 096 以來的舊傷：
--    「法商東方匯理銀行台北分行」被 {0,8} 貪婪匹配剝到只剩「法商」。
-- 3) 分行剝除改兩段式：名字含「股份有限公司/有限公司+地區+分公司」才允許長剝（≤8字），
--    否則只剝 2 字地名（台北分行/敦化分行…），不再把銀行本名吃進去。
-- 4) 去開頭法人前綴：財團法人/社團法人（含「團法○○」缺字容錯——名冊有「團法工業技術研究院」）
--    → (財團法人)證券投資人及期貨交易人保護中心、(財團法人)民間司法改革基金會、
--      (財團法人)工業技術研究院 各自合組。中段法人字樣不動（佛教慈濟醫療財團法人台北慈濟醫院維持原樣）。
-- 5) 簡稱對照：工研院→工業技術研究院（目前名冊僅此一例，法扶簡寫已由特例處理）。
-- 6) employer_kind 補：工業技術研究院/工研院 一律歸學研機構（原本掛「財團法人」的兩位
--    被財團法人規則先攔成非營利，同一雇主拆在兩個 tab 各算一半）。

CREATE OR REPLACE FUNCTION norm_employer(emp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp ~ '法律扶助基金會|法扶基金會' THEN '法律扶助基金會'
  WHEN fin = '工研院' THEN '工業技術研究院'
  ELSE fin
END
FROM (
  SELECT regexp_replace(
    CASE
      WHEN e5 ~ '(股份有限公司|有限公司)[一-龥A-Za-z]{0,8}(分公司|分行|分會)$'
        THEN coalesce(nullif(regexp_replace(e5, '(股份有限公司|有限公司)[一-龥A-Za-z]{0,8}(分公司|分行|分會)$', ''), ''), e5)
      ELSE coalesce(nullif(regexp_replace(e5, '[一-龥A-Za-z]{0,2}(分公司|分行|分會)$', ''), ''), e5)
    END,
    '(股份有限公司|有限公司)$', '') AS fin
  FROM (
    SELECT coalesce(nullif(regexp_replace(e4, '^(財團法人|社團法人|團法人?)', ''), ''), e4) AS e5
    FROM (
      SELECT coalesce(nullif(regexp_replace(e3, '^(美商|法商|英商|德商|日商|港商|韓商|澳商|星商|新加坡商|香港商|瑞士商|荷蘭商|盧森堡商|開曼群島商|薩摩亞商|百慕達商|英屬[一-龥]{2,4}商)', ''), ''), e3) AS e4
      FROM (
        SELECT translate(coalesce(nullif(regexp_replace(e2, '[（(][^（）()]*[）)]$', ''), ''), e2), '（）()', '') AS e3
        FROM (
          SELECT regexp_replace(
                   translate(regexp_replace(coalesce(emp, ''), '[\s　]', '', 'g'), '臺', '台'),
                   '[（(]股[）)](有限)?公司', '股份有限公司') AS e2
        ) a
      ) b
    ) c
  ) d
) e
$$;

-- 工研院歸類補丁：插在財團法人規則之前（其餘規則與 mig 100 相同）
CREATE OR REPLACE FUNCTION employer_kind(emp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN emp IS NULL OR emp = '' THEN NULL
  WHEN emp ~ '公職律師' THEN '政府與公職'
  WHEN emp ~ '律師公會|聯合會' THEN '非營利與公協會'
  WHEN emp ~ '法律扶助' THEN '非營利與公協會'
  WHEN emp ~ '事務所|法律工場|律師樓|律師行|法務所|律師所|事務務所|律師服務處' THEN '事務所'
  WHEN emp ~ '^[一-龥]{1,4}(大)?律師$' OR emp ~ '法律$' THEN '事務所'  -- 個人名義掛牌／「○○法律」簡寫＝獨立執業
  WHEN emp ~* '(LLP)$' OR emp ~* '^(MayerbrownJSM|Davis&Davis)$' THEN '事務所'  -- 外國律所（名冊已去空白）
  WHEN emp ~ '工業技術研究院|工研院' THEN '學研機構'  -- 先於財團法人規則，避免同雇主拆兩類
  WHEN emp ~ '財團法人|社團法人|基金會|協會|公會|工會|農會|漁會|策進會|保護中心' THEN '非營利與公協會'
  WHEN emp ~ '總統府|行政院|立法院|司法院|考試院|監察院|政府|公所|議會|法院|檢察署|地檢署|警察|國防部|法務部|外交部|財政部|教育部|經濟部|交通部|勞動部|內政部|衛生福利部|文化部|環境部|農業部|數位發展部|海洋委員會|國稅局|關務署|健保署|勞保局|戶政|監理|行政法人|國家住宅及都市更新中心' THEN '政府與公職'
  WHEN emp ~ '大學|學院|高級中學|高中|國中|國小|學校|工研院|研究院' THEN '學研機構'
  WHEN emp ~ '銀行|保險|人壽|產物|證券|投信|投顧|金控|金融|期貨|票券|租賃|資融|資產管理|創投|資本|交易所|櫃檯買賣|集中保管|農金' THEN '金融保險'
  WHEN emp ~ '公司|商行|商號|企業社|工作室|醫院|診所|營運處|總管理處|法務處|集團|有線電視|企業|科技|電子|光電|半導體|能源|通訊|製藥|生技|DHL' THEN '一般企業'
  ELSE '其他'
END $$;
