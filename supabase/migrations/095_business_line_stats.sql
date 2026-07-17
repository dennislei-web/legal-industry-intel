-- 業務線量體拆解（產業分析＞訴訟市場＞市場趨勢）
-- 在 cause_map 的「種類」之上疊一層「業務線」戰略視角（跨檔型：繼承橫跨民訴+家訴、
-- 智財橫跨民訴+刑訴），資料源 = closed_case_cause_national（月×檔型×原始案由，mig 064）。
-- 口徑決策：
--   * 只納「訴訟」三檔型（民訴覆蓋官方 ~82%、刑訴 ~92%、家訴每案一列）；
--     民事非訟/家事非訟覆蓋率低（39%/16%，mig 064 註解）→ 不納入，避免假精度
--   * 刑事計數單位 = 被告人次，與民/家事「案件數」不同單位，前端分開呈現、不得加總
--   * 刑事用條號精準拆：§185-3/185-4（酒駕/肇逃）+§284（過失傷害）+§276（過失致死）→ 交通刑事
--     （§284/§276 車禍佔絕對多數，含少量工安/醫療過失，屬上限誤差）
--   * 民訴「特別法/其他民法」大桶用案由關鍵字拆（勞動/智財/票據/不動產/繼承/催收…），
--     規則依 cause_raw_top 實測 top 案由字串設計，剩餘歸「其他民事」
-- 每月更新：closed-case-stats-monthly.yml 跑完 pipeline 後 curl 呼叫 refresh_business_line_stats()

CREATE OR REPLACE FUNCTION biz_line(ft text, grp text, cause text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN ft = '民事訴訟' THEN CASE
    WHEN grp = '損害賠償' THEN '車禍與侵權賠償'
    WHEN grp = '借貸' THEN '借貸與金錢債務'
    WHEN grp = '租賃' THEN '不動產'
    WHEN grp = '承攬' THEN '工程承攬'
    WHEN grp = '僱傭' THEN '勞動僱傭'
    WHEN grp = '特別法' THEN CASE
      WHEN cause ~ '勞動|職業災害|職災|工資|薪資|資遣費|退休金|加班費|獎金' THEN '勞動僱傭'
      WHEN cause ~ '著作權|商標|專利|營業秘密|公平交易' THEN '智慧財產'
      WHEN cause ~ '票款|本票|匯票|支票' THEN '借貸與金錢債務'
      WHEN cause ~ '管理費|公寓大廈|區分所有權' THEN '不動產'
      WHEN cause ~ '公司|股東|證券|期貨|海商|檢查人|政府採購|重整|清算' THEN '公司商事'
      ELSE '其他民事'  -- 國賠/保險/消保等（量小，鑽取可見明細）
    END
    WHEN grp = '其他民法' THEN CASE
      WHEN cause ~ '遺產|繼承|特留分|應繼分' THEN '繼承與遺產'
      WHEN cause ~ '分割共有物|拆屋還地|遷讓|返還土地|返還房屋|返還不動產|所有權移轉|移轉登記|塗銷|抵押權|通行權|地上權|越界|漏水|優先購買|土地|房屋|不動產|耕地|租佃|地租' THEN '不動產'
      WHEN cause ~ '電信費|電話費|停車費|服務費|有線電視|網路費|會費|電費|瓦斯費' THEN '借貸與金錢債務'
      WHEN cause ~ '工程' THEN '工程承攬'
      ELSE '其他民事'  -- 除權判決/再審/異議之訴等程序案由為大宗
    END
    WHEN grp IN ('買賣', '贈與', '委任', '合夥', '旅遊') THEN '契約與買賣'
    ELSE '其他民事'  -- 不當得利等
  END
  WHEN ft = '家事訴訟' THEN CASE
    WHEN grp IN ('離婚', '夫妻財產', '婚姻無效及確認') THEN '離婚與婚姻'
    WHEN grp IN ('親子關係', '扶養') THEN '親子與扶養'
    WHEN grp = '繼承訴訟' THEN '繼承與遺產'
    ELSE '其他家事'
  END
  WHEN ft = '刑事訴訟' THEN CASE
    -- 條號優先（脫離所屬罪章）：§284 過失傷害在傷害罪章、§276 過失致死在殺人罪章
    WHEN cause IN ('刑法§185-3', '刑法§185-4', '刑法§284', '刑法§276') THEN '交通刑事'
    WHEN grp = '公共危險罪' THEN '交通刑事'  -- 其餘（放火/失火等）佔本罪章 <3%
    WHEN grp IN ('詐欺罪', '洗錢防制法', '詐欺犯罪危害防制條例', '組織犯罪防制條例') THEN '詐欺與洗錢'
    WHEN grp ~ '毒品|麻醉藥品' THEN '毒品'
    WHEN grp IN ('傷害罪', '殺人罪', '妨害自由罪', '強盜及海盜罪', '搶奪罪', '恐嚇取財罪',
                 '擄人勒贖罪', '妨害秩序罪', '槍砲彈藥刀械管制條例', '家庭暴力防治法') THEN '暴力與人身犯罪'
    WHEN grp ~ '性剝削' OR grp IN ('妨害性自主罪', '妨害風化罪', '性騷擾防治法',
                 '妨害性隱私及不實性影像罪', '跟蹤騷擾防制法', '性侵害犯罪防治法') THEN '性犯罪與跟騷'
    WHEN grp IN ('妨害名譽及信用罪', '妨害秘密罪', '妨害電腦使用罪', '個人資料保護法') THEN '名譽個資與網路'
    WHEN grp IN ('竊盜罪', '侵占罪', '贓物罪', '毀棄損壞罪') THEN '竊盜侵占與財產犯罪'
    WHEN grp IN ('偽造文書印文罪', '背信及重利罪', '偽造有價證券罪', '偽造貨幣罪', '瀆職罪',
                 '證券交易法', '銀行法', '商業會計法', '貪污治罪條例', '稅捐稽徵法', '期貨交易法',
                 '政府採購法', '公司法', '金融控股公司法', '多層次傳銷管理法',
                 '證券投資信託及顧問法') THEN '白領與財經犯罪'
    WHEN grp IN ('商標法', '著作權法', '營業秘密法') THEN '智慧財產'
    ELSE '其他刑事'
  END
  ELSE NULL  -- 民事非訟/家事非訟不納入
END $$;

-- 年度×業務線×檔型（前端趨勢圖/成長表；列數 ~ 6年×19線×3檔型 < 300）
CREATE TABLE IF NOT EXISTS business_line_yearly (
  y text NOT NULL,
  line text NOT NULL,
  file_type text NOT NULL,
  n bigint NOT NULL,
  months int NOT NULL,          -- 該年有資料的月數（辨識部分年度）
  PRIMARY KEY (y, line, file_type)
);

-- 業務線 → 原始案由 top 40（鑽取 modal；全期間累計）
CREATE TABLE IF NOT EXISTS business_line_causes (
  line text NOT NULL,
  file_type text NOT NULL,
  total bigint NOT NULL,
  distinct_causes int NOT NULL,
  top_causes jsonb NOT NULL,    -- [["案由", n], ...] 前 40
  PRIMARY KEY (line, file_type)
);

-- 公開司法資料，開放層級對齊 cause_group_causes（mig 080）
ALTER TABLE business_line_yearly ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_bly" ON business_line_yearly;
CREATE POLICY "read_bly" ON business_line_yearly FOR SELECT USING (true);
ALTER TABLE business_line_causes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_blc" ON business_line_causes;
CREATE POLICY "read_blc" ON business_line_causes FOR SELECT USING (true);
GRANT SELECT ON business_line_yearly, business_line_causes TO anon, authenticated;

CREATE OR REPLACE FUNCTION refresh_business_line_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout TO '300s' AS $$
BEGIN
  CREATE TEMP TABLE _bl ON COMMIT DROP AS
    SELECT left(yyyymm, 4) AS y, yyyymm, file_type, cause, case_count,
           biz_line(file_type, cause_group, cause) AS line
    FROM closed_case_cause_national
    WHERE file_type IN ('民事訴訟', '家事訴訟', '刑事訴訟');

  TRUNCATE business_line_yearly;
  INSERT INTO business_line_yearly (y, line, file_type, n, months)
  SELECT y, line, file_type, sum(case_count)::bigint, count(DISTINCT yyyymm)::int
  FROM _bl GROUP BY 1, 2, 3;

  TRUNCATE business_line_causes;
  INSERT INTO business_line_causes (line, file_type, total, distinct_causes, top_causes)
  WITH agg AS (
    SELECT line, file_type, cause, sum(case_count)::bigint AS n
    FROM _bl GROUP BY 1, 2, 3
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY line, file_type ORDER BY n DESC) AS rn FROM agg
  )
  SELECT line, file_type, sum(n)::bigint, count(*)::int,
         coalesce(jsonb_agg(jsonb_build_array(cause, n) ORDER BY n DESC)
                  FILTER (WHERE rn <= 40), '[]'::jsonb)
  FROM ranked GROUP BY 1, 2;
END $$;

GRANT EXECUTE ON FUNCTION refresh_business_line_stats() TO service_role;

SELECT refresh_business_line_stats();
