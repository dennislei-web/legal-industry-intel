-- ============================================================
-- 257: 案由子類擴到全部民事種類（12 種）＋ 供需地圖「領域下鑽」明細改列子類彙總
-- ============================================================
-- 需求（雷 2026-11-03，截圖「損害賠償 — 領域下鑽」）：明細列 372 種案由字串，其實多半只是
--   「請求…」「…等」「再審之訴」「(簡判)」這類程序字樣不同，要整併成有意義的分類。
-- 既有機制（mig 255）：cause_group_map.sub_group 是 generated column，只對「損害賠償」分 8 子類，
--   供事務所版圖下拉用。本 migration 沿用同一欄、同一原則（規則寫 DDL、主題優先於程序、
--   ETL upsert 新鍵自動算），把 CASE 擴到其餘 12 個民事種類，並讓下鑽明細直接讀子類彙總。
--   Postgres 不能 ALTER generated expression，只能 DROP 再 ADD（idx_cgm_sub 跟著掉再建）。
--
-- 子類設計（近 60 月、律師端件數實測；模擬腳本與全部字串分布見 session scratchpad）：
--   損害賠償  ：沿用 255 的 8 類不動（交通／配偶／醫療／智財／國賠／債務不履行／程序／未標明）。
--   特別法    ：勞動 33%、票據 30%、智財與公平交易 11%、公司與證券 8%、國賠 7%、保險 7%、公寓大廈 5%。
--   其他民法  ：剩餘桶 36.7 萬件（損害賠償的 2.2 倍、8,783 種字串），拆 18 類——契約履行與給付 16%、
--               消債更生清算 16%、拆屋還地 13%、不動產權利與登記 13%、共有物分割 10%、強制執行爭議 6%、
--               程序 5%、通行權相鄰 4%、法人商業 3%、確認債權 3%、保全 3%、家事繼承（民事庭）2%、
--               排除侵害 2%、非訟調解仲裁 1%、詐害債權信託、選舉訴訟、人格權；真正無法歸類的「其他」只剩 1.4%。
--   借貸      ：一般借款 96%／信用卡消費金融 3%／程序。
--   買賣      ：賣方請求（給付價金、貨款）45%／買方請求（返還、減少價金、解約、交付）45%／確認買賣關係 7%。
--               不另立「不動產買賣」：案由幾乎不寫標的物，抓得到的不到 1%，列出來會誤導。
--   租賃      ：遷讓房屋／返還租賃物 70%、給付租金 14%、租佃爭議 7%、押租金 4%、確認租賃關係 3%、調整租金 2%。
--   承攬      ：給付工程款／承攬報酬 90%、返還工程款／溢領 8%、瑕疵修補 1%。
--   不當得利  ：返還不當得利 99%（純寫法差異）、程序、代位請求。
--   僱傭      ：確認僱傭關係存在（復職）97%、不存在（雇主提起）1%、程序 2%。
--   委任      ：委任報酬 38%、確認委任關係 25%、董事／經理人委任 22%、律師酬金核定（程序）12%。
--   贈與      ：撤銷贈與 69%、履行贈與契約 14%、確認贈與效力 12%、返還贈與物 5%。
--   合夥      ：清算結算 41%、確認合夥關係 17%、返還出資 16%、分配利益 16%。
--   旅遊（26 件）不細分；刑事／家事／行政的種類本來就是罪名／事件別，不在本次範圍（sub_group 維持 NULL，
--   前端沿用原始寫法表）。
-- 規則慣例：依序比對、先中先贏、主題優先於程序；「再審及程序事件」＝只剩程序字樣的字串。
--   其他民法多一條「純程序開頭」規則放最前（^訴訟救助、^交付法庭錄音…），因為該桶的「交付」「給付」
--   這類主題詞太泛，不先攔會把 1,961 件「交付法庭錄音光碟」算成契約給付。
--   最高法院裁定的案由常是整句含當事人名，仍避免用「醫院」這類會撞到當事人名的詞
--   （其他民法的「公司」是刻意的：該桶裡含「公司」者幾乎都是公司法非訟）。
--
-- 下鑽明細：cause_group_causes 加 sub_groups jsonb
--   [{"g":子類,"n":件數,"k":寫法數,"top":[[原始案由,件數]…前 15]} …] 依件數遞減；無子類的種類為 NULL。
--   refresh_lawyer_cause_stats()（255 全文）同一份 _lc 多一次 rollup；首次建置只 UPDATE 這一欄
--   （total／top_causes 不動，滾動窗相同，建完驗 sum(n)＝total）。
-- 事務所版圖：lawyer_cause_sub_stats／firm_cause_sub_ranking／cause_sub_group_list 不改結構，
--   refresh 後自動多出其餘種類的子類；cause_sub_group_list 排序改成「程序」「未標明／其他…」殿後。
--
-- 驗證（套用後）：
--   select cause_group, total, (select sum((e->>'n')::bigint) from jsonb_array_elements(sub_groups) e) s
--   from cause_group_causes where sub_groups is not null;   -- s 必須＝total
--   select cause_group, count(distinct sub_group) from cause_group_map where sub_group is not null group by 1;

-- 1) 子類對照：重建 generated column（規則見上；改規則＝改這裡再跑 5)）
ALTER TABLE cause_group_map DROP COLUMN IF EXISTS sub_group;
ALTER TABLE cause_group_map ADD COLUMN sub_group text GENERATED ALWAYS AS (
  CASE WHEN cat <> '民事' THEN NULL
    WHEN cause_group = '損害賠償' THEN CASE
      WHEN cause ~ '交通|車禍' THEN '交通事故'
      WHEN cause ~ '配偶|妨害婚姻|通姦|相姦' THEN '侵害配偶權'
      WHEN cause ~ '醫療|醫議|醫事|[(]醫[)]' THEN '醫療糾紛'
      WHEN cause ~ '智財|智慧財產|[(]智[)]|著作|專利|商標|營業秘密|植物品種' THEN '智慧財產'
      WHEN cause ~ '國家損害|國家賠償|國賠|[(]國家[)]' THEN '國家賠償'
      WHEN cause ~ '債務不履行|不完全給付|契約|違約' THEN '債務不履行（契約）'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '未標明類型' END
    WHEN cause_group = '特別法' THEN CASE
      WHEN cause ~ '國家賠償|國賠' THEN '國家賠償'
      WHEN cause ~ '本票|票款|支票|匯票|票據' THEN '票據（本票、支票）'
      WHEN cause ~ '專利|著作|商標|營業秘密|智財|智慧財產|公平交易|植物品種|積體電路' THEN '智慧財產與公平交易'
      WHEN cause ~ '資遣|退休金|工資|薪資|加班費|職業災害|職災|獎金|勞動|勞基|勞工|勞保|勞退|競業|工作規則|年資|特休|解僱|調職|雇主|僱用' THEN '勞動（工資、資遣、退休、職災）'
      WHEN cause ~ '保險|保單|保費' THEN '保險'
      WHEN cause ~ '管理費|區分所有權|公寓大廈|管理委員會|住戶|管委會' THEN '公寓大廈'
      WHEN cause ~ '股東|公司|董事|檢查人|證券|期貨|監察人|重整|有價證券|投資人|經理人' THEN '公司與證券'
      WHEN cause ~ '消費者|消保|消費' THEN '消費者保護'
      WHEN cause ~ '個人資料|個資' THEN '個人資料保護'
      WHEN cause ~ '政府採購|採購' THEN '政府採購'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他特別法' END
    WHEN cause_group = '其他民法' THEN CASE
      WHEN cause ~ '^(請求|聲請|依職權)?(交付法庭錄音|法庭錄音|訴訟救助|裁定確定訴訟費用額|確定訴訟費用額|選任特別代理人|秘密保持命令|補繳裁判費|公示送達|限期起訴|發還擔保金|返還擔保金|再審之訴$|閱覽卷宗|閱卷|退還裁判費|核定訴訟標的價額|聲請.*費用額)' THEN '再審及程序事件'
      WHEN cause ~ '臨時管理人|清算人|檢查人|重整|商業事件|裁定解散|法人|社團|財團|祭祀公業|派下|公司|股票|股份|董事|監察人|股東|破產|帳冊|帳簿|簿冊|歸入權|決議|理事|監事|會員' THEN '法人、商業與團體事務'
      WHEN cause ~ '更生|消債|消費者債務|免責|復權|清算' THEN '消費者債務清理（更生、清算）'
      WHEN cause ~ '遺產|繼承|遺囑|特留分|應繼分|離婚|收養|死亡宣告|宣告死亡|剩餘財產|夫妻|親權|監護|扶養|認領|婚姻|子女|親子' THEN '家事與繼承（民事庭）'
      WHEN cause ~ '詐害|信託|第三人撤銷' THEN '撤銷詐害債權與信託行為'
      WHEN cause ~ '名譽|配偶|人格|隱私|肖像' THEN '人格權（名譽、配偶權）'
      WHEN cause ~ '分割|共有物' THEN '共有物分割'
      WHEN cause ~ '拆屋還地|拆除|返還土地|返還房屋|返還所有物|返還不動產|返還停車位|返還車位|騰空|返還借名|遷讓|交還土地|交還房屋' THEN '拆屋還地與返還土地房屋'
      WHEN cause ~ '通行權|袋地|界址|越界|相鄰|漏水|修復|修繕|排水|鄰地|通行' THEN '通行權、界址與相鄰（含漏水）'
      WHEN cause ~ '移轉登記|塗銷|所有權|抵押權|地上權|登記|借名|優先購買權|典權|地役|不動產役權|耕地|三七五|農育權|建物|土地' THEN '不動產權利與登記'
      WHEN cause ~ '假扣押|假處分|定暫時狀態|保全證據|保全處分|證據保全|緊急處置' THEN '保全程序（假扣押、假處分、定暫時狀態）'
      WHEN cause ~ '異議之訴|停止執行|聲明異議|強制執行|許可執行|拍賣抵押物|拍賣擔保物|提存|參與分配|分配表|執行' THEN '強制執行爭議'
      WHEN cause ~ '當選無效|選舉無效|罷免|選舉' THEN '選舉訴訟'
      WHEN cause ~ '排除侵害|防止侵害|妨害|禁止' THEN '排除侵害與妨害禁止'
      WHEN cause ~ '支付命令|公示催告|除權判決|調解|仲裁|本票' THEN '非訟聲請、調解與仲裁'
      WHEN cause ~ '履行|違約金|解除契約|回復原狀|報酬|服務費|款項|代墊|投資款|保證金|補償金|定金|給付|返還|退還|交付|合約|契約|協議' THEN '契約履行與各類給付'
      WHEN cause ~ '確認' THEN '確認債權或法律關係'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任|裁判費|法庭錄音|特別代理人|閱覽|卷宗|迴避|續行訴訟|訴之追加|鑑定人|第三審|核定|確定訴訟|退還|補繳|公示送達|限期起訴|擔保金' THEN '再審及程序事件'
      ELSE '其他' END
    WHEN cause_group = '借貸' THEN CASE
      WHEN cause ~ '信用卡|簽帳卡|現金卡|消費款' THEN '信用卡／消費金融'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '一般借款（返還、清償）' END
    WHEN cause_group = '買賣' THEN CASE
      WHEN cause ~ '確認' THEN '確認買賣關係'
      WHEN cause ~ '返還|減少|解除|瑕疵|交付|回復原狀|退還|退款' THEN '買方請求（返還、減少價金、解約、交付）'
      WHEN cause ~ '價金|貨款|給付' THEN '賣方請求（給付價金、貨款）'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他買賣爭議' END
    WHEN cause_group = '租賃' THEN CASE
      WHEN cause ~ '租佃|三七五|耕地' THEN '租佃爭議（耕地）'
      WHEN cause ~ '遷讓|返還租賃|返還房屋|騰空|返還土地|返還店面|返還攤位|返還車位|返還停車位' THEN '遷讓房屋／返還租賃物'
      WHEN cause ~ '押租金|押金|保證金' THEN '押租金返還'
      WHEN cause ~ '調整租金|調整' THEN '調整租金'
      WHEN cause ~ '租金' THEN '給付租金'
      WHEN cause ~ '確認' THEN '確認租賃關係'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他租賃爭議' END
    WHEN cause_group = '承攬' THEN CASE
      WHEN cause ~ '返還|溢領|退還' THEN '返還工程款／溢領'
      WHEN cause ~ '修繕|修補|瑕疵|修復|減少報酬|重作' THEN '瑕疵修補與修繕'
      WHEN cause ~ '工程款|承攬報酬|報酬|給付|酬金' THEN '給付工程款／承攬報酬'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他承攬爭議' END
    WHEN cause_group = '不當得利' THEN CASE
      WHEN cause ~ '代位' THEN '代位請求'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '返還不當得利' END
    WHEN cause_group = '僱傭' THEN CASE
      WHEN cause ~ '不存在' THEN '確認僱傭關係不存在（雇主提起）'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '確認僱傭關係存在（復職）' END
    WHEN cause_group = '委任' THEN CASE
      WHEN cause ~ '董事|監察人|經理人|董監' THEN '董事／經理人委任關係'
      WHEN cause ~ '律師酬金|律師報酬|第三審律|酌定' THEN '律師酬金核定（程序）'
      WHEN cause ~ '確認' THEN '確認委任關係'
      WHEN cause ~ '報酬|費用|款|酬金|給付|返還' THEN '委任報酬與費用'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他委任爭議' END
    WHEN cause_group = '贈與' THEN CASE
      WHEN cause ~ '撤銷' THEN '撤銷贈與'
      WHEN cause ~ '確認|無效' THEN '確認贈與效力'
      WHEN cause ~ '履行|交付|給付|移轉' THEN '履行贈與契約'
      WHEN cause ~ '返還' THEN '返還贈與物'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他贈與爭議' END
    WHEN cause_group = '合夥' THEN CASE
      WHEN cause ~ '清算|結算|決算' THEN '合夥清算與結算'
      WHEN cause ~ '出資|退夥' THEN '返還合夥出資'
      WHEN cause ~ '利益|盈餘|分配|紅利' THEN '分配合夥利益'
      WHEN cause ~ '確認' THEN '確認合夥關係'
      WHEN cause ~ '再審|聲請|聲明|抗告|假扣押|假處分|管轄|訴訟救助|承受訴訟|更正|補充判決|訴訟費用|訴訟標的價額|停止訴訟|繼續審判|參加訴訟|選任' THEN '再審及程序事件'
      ELSE '其他合夥爭議' END
  END
) STORED;
CREATE INDEX IF NOT EXISTS idx_cgm_sub ON cause_group_map (cause_group, sub_group) WHERE sub_group IS NOT NULL;

-- 2) 下鑽明細表加子類彙總欄
ALTER TABLE cause_group_causes ADD COLUMN IF NOT EXISTS sub_groups jsonb;

-- 3) 重建 refresh_lawyer_cause_stats（255 全文＋ sub_groups rollup）
CREATE OR REPLACE FUNCTION refresh_lawyer_cause_stats() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout TO '900s' AS $$
DECLARE cutoff text;
BEGIN
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM')
    INTO cutoff FROM lawyer_month_stats WHERE causes IS NOT NULL;
  IF cutoff IS NULL THEN RETURN; END IF;

  CREATE TEMP TABLE _lc ON COMMIT DROP AS
    SELECT l.name, k.key AS ck, sum((k.value)::int)::int AS n
    FROM lawyer_month_stats l, jsonb_each_text(l.causes) k
    WHERE l.causes IS NOT NULL AND l.yyyymm >= cutoff
    GROUP BY 1, 2;

  TRUNCATE lawyer_cause_stats;
  INSERT INTO lawyer_cause_stats (name, cases_5yr, by_group, top_causes)
  SELECT c.name, c.total, g.by_group, t.top_causes
  FROM (SELECT name, sum(n)::int AS total FROM _lc GROUP BY 1) c
  JOIN (
    SELECT name, jsonb_object_agg(grp, gn) AS by_group FROM (
      SELECT l.name, coalesce(m.cause_group, split_part(l.ck, '|', 1)) AS grp,
             sum(l.n)::int AS gn
      FROM _lc l LEFT JOIN cause_group_map m ON m.ck = l.ck
      GROUP BY 1, 2) s
    GROUP BY name) g USING (name)
  JOIN (
    SELECT name, jsonb_agg(jsonb_build_array(ck, n) ORDER BY n DESC) AS top_causes FROM (
      SELECT name, ck, n, row_number() OVER (PARTITION BY name ORDER BY n DESC) AS rn
      FROM _lc) s
    WHERE rn <= 20
    GROUP BY name) t USING (name);

  -- 案由種類鑽取表（同一份 _lc，多一次 rollup；mig 257 加子類彙總 sub_groups）
  TRUNCATE cause_group_causes;
  INSERT INTO cause_group_causes (cause_group, cat, total, distinct_causes, top_causes, sub_groups)
  WITH agg AS (
    SELECT coalesce(m.cause_group, split_part(l.ck, '|', 1)) AS grp,
           coalesce(m.cat, split_part(l.ck, '|', 1)) AS cat,
           coalesce(m.cause, split_part(l.ck, '|', 2)) AS cause,
           m.sub_group AS sg,
           sum(l.n)::bigint AS n
    FROM _lc l LEFT JOIN cause_group_map m ON m.ck = l.ck
    GROUP BY 1, 2, 3, 4
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY grp ORDER BY n DESC) AS rn,
              row_number() OVER (PARTITION BY grp, sg ORDER BY n DESC, cause) AS srn
    FROM agg
  ), subs AS (
    SELECT grp, sg, sum(n) AS sn, count(*) AS sk,
           jsonb_agg(jsonb_build_array(cause, n) ORDER BY n DESC, cause) FILTER (WHERE srn <= 15) AS stop
    FROM ranked WHERE sg IS NOT NULL GROUP BY grp, sg
  ), subj AS (
    SELECT grp, jsonb_agg(jsonb_build_object('g', sg, 'n', sn, 'k', sk, 'top', coalesce(stop, '[]'::jsonb))
                          ORDER BY sn DESC, sg) AS sub_groups
    FROM subs GROUP BY grp
  )
  SELECT r.grp, min(r.cat), sum(r.n)::bigint, count(*)::int,
         coalesce(jsonb_agg(jsonb_build_array(r.cause, r.n) ORDER BY r.n DESC)
                  FILTER (WHERE r.rn <= 40), '[]'::jsonb),
         j.sub_groups
  FROM ranked r LEFT JOIN subj j ON j.grp = r.grp
  GROUP BY r.grp, j.sub_groups;

  -- 年度下鑽表（mig 098；巢狀呼叫有自己的 statement_timeout）
  PERFORM refresh_lawyer_cause_year_stats();
  -- 法院層物化表（mig 182）
  PERFORM refresh_lawyer_cause_court_stats();
  -- 子類物化表（mig 255；257 起涵蓋全部民事種類）
  PERFORM refresh_lawyer_cause_sub_stats();
END $$;
GRANT EXECUTE ON FUNCTION refresh_lawyer_cause_stats() TO service_role;

-- 4) 子類下拉清單：排序改成所有種類通用（具名子類依件數；「再審及程序事件」次後；「未標明…」「其他…」殿後）
CREATE OR REPLACE FUNCTION cause_sub_group_list()
RETURNS TABLE (cause_group text, sub_group text, cases bigint, lawyers int) AS $$
  SELECT cause_group, sub_group, sum(case_count)::bigint, count(*)::int
  FROM lawyer_cause_sub_stats
  WHERE yr = 0
  GROUP BY 1, 2
  ORDER BY 1,
           CASE WHEN sub_group = '再審及程序事件' THEN 1
                WHEN sub_group ~ '^(未標明|其他)' THEN 2 ELSE 0 END,
           3 DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
ALTER FUNCTION cause_sub_group_list() SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION cause_sub_group_list() TO anon, authenticated;

-- 5) 首次建置：只補 cause_group_causes.sub_groups（同一滾動窗，total／top_causes 不動）＋重建子類物化表
WITH cutoff AS (
  SELECT to_char(to_date(max(yyyymm) || '01', 'YYYYMMDD') - interval '59 months', 'YYYYMM') AS c
  FROM lawyer_month_stats WHERE causes IS NOT NULL
), lc AS (
  SELECT k.key AS ck, sum((k.value)::int)::bigint AS n
  FROM lawyer_month_stats l CROSS JOIN LATERAL jsonb_each_text(l.causes) k
  WHERE l.causes IS NOT NULL AND l.yyyymm >= (SELECT c FROM cutoff)
  GROUP BY 1
), agg AS (
  SELECT m.cause_group AS grp, m.sub_group AS sg, m.cause, l.n
  FROM lc l JOIN cause_group_map m ON m.ck = l.ck
  WHERE m.sub_group IS NOT NULL
), ranked AS (
  SELECT *, row_number() OVER (PARTITION BY grp, sg ORDER BY n DESC, cause) AS srn FROM agg
), subs AS (
  SELECT grp, sg, sum(n) AS sn, count(*) AS sk,
         jsonb_agg(jsonb_build_array(cause, n) ORDER BY n DESC, cause) FILTER (WHERE srn <= 15) AS stop
  FROM ranked GROUP BY grp, sg
), subj AS (
  SELECT grp, jsonb_agg(jsonb_build_object('g', sg, 'n', sn, 'k', sk, 'top', coalesce(stop, '[]'::jsonb))
                        ORDER BY sn DESC, sg) AS sub_groups
  FROM subs GROUP BY grp
)
UPDATE cause_group_causes c SET sub_groups = j.sub_groups FROM subj j WHERE c.cause_group = j.grp;

SELECT refresh_lawyer_cause_sub_stats();
NOTIFY pgrst, 'reload schema';
