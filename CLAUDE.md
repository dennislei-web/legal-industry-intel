# Legal Industry Intel

台灣法律產業情報網站 — 律師、事務所、法官、法院的資料查詢與分析。

## 架構

- **前端**：`public/index.html` — 單檔 SPA（純 HTML/JS/CSS + Supabase JS SDK）
- **後端**：Supabase（Auth + PostgreSQL + RLS）
- **部署**：GitHub Pages（前端）+ Supabase（後端）+ GitHub Actions（爬蟲定時任務）
- **Production URL**：https://dennislei-web.github.io/legal-industry-intel/

## 關鍵檔案

- `public/index.html` — 整個前端 SPA（登入 + 儀表板 + 所有頁面）
- `supabase/migrations/*.sql` — DB schema / RLS policy / materialized view
- `scripts/moj_*.py` — 法務部律師爬蟲
- `scripts/scrape_lawsnote*.py` — Lawsnote 律師/法官/案件爬蟲
- `scripts/twba_lawyer_scraper.py` — 全聯會律師爬蟲
- `scripts/scrape_firm_websites.py` — 事務所官網爬蟲
- `.github/workflows/*.yml` — 爬蟲排程（多數 workflow_dispatch 手動觸發）

## 資料表（主要）

- `moj_lawyers` — 法務部律師主表（lic_no 為主鍵）
- `moj_firm_stats_cache` — 事務所統計快取表（普通 table，非 MV），由 `refresh_firm_stats_cache` RPC 以 UPSERT 更新（migration 020）
- `firm_profiles` — 事務所補充資料（官網、備註等手動編輯）
- `firm_websites` — 爬蟲找到的官網；**官網成立條件 = 該網域首頁含所名**（`verified=true`，
  migration 065）。`moj_firm_statistics()` 只出 verified 官網，另疊 blocklist/共用URL/外國TLD 過濾。
  ⚠️ **重寫 moj_firm_statistics() 時務必保留 clean_web 官網清洗段**——048 重寫時弄丟過一次，
  雜訊官網 428→1073 全數回歸（065 修復）。共用驗證邏輯在 `scripts/website_verify.py`；
  既有資料重驗跑 `scripts/verify_firm_websites.py`（直打 PostgREST：本機 .env 是新版
  sb_secret key，舊版 supabase-py 會報 Invalid API key）
- `judges` / `courts` / `judges_combined` — 法官/法院
- `prosecutor_month_stats` / `prosecutor_stats` — 檢察官統計（migration 029），`judgment_stats.py` 從刑事裁判書萃取「檢察官○○○提起公訴/到庭執行職務」＋所屬檢察署，`refresh_prosecutor_stats` RPC 彙總；約半數刑事判決不具名檢察官，案件數為下限估計
- `prosecutor_offices` — 檢察署基本資料 30 署（migration 033 種子）；**現職檢察官數用 `prosecutor_active_summary()` / `prosecutor_active_by_office()` RPC**（最新資料月具名數＋跨署主要歸屬去重，實測與法務統計官方 114 年底 1,460 誤差 <1%）。`prosecutor_stats` 的列數是五年累計（人×署）組合，**不是現職人數**，別直接當檢察官總數用
- **檢察官姓名雜訊（migration 066，2026-07）**：舊版抽取 regex 允許 `\s` 跨換行，「…檢察署檢察官\n被　告　○○」會把被告名抓成檢察官，359 月累積 ~1 萬個假名（「累計具名人數」曾膨脹到 17,752）。已刪歷史假名列＋`prosecutor_active_summary().names_total` 改「跨 ≥12 個資料月」門檻（=2,646）；`judgment_stats.py` 的 `RE_PROS_*` 改僅容許水平空白＋擴充 `RE_PROS_BAD`（**停用字與 066 清洗 pattern 同步，改一邊要同步另一邊**）。殘餘零星假名（像真人名的誤抓被告）仍在 month_stats，靠門檻擋在 KPI 外
- `moj_lawyer_changes` — 律師異動紀錄（事務所變更/新進/執業狀態），由 `moj_lawyers` 上的 trigger `moj_lawyers_log_change` 自動寫入（migration 024），前端「異動追蹤」tab 讀取；律師 modal 另有「登錄單位異動歷程」卡（`renderLawyerFirmHistoryCard`，按證號列 firm_change/state_change 時間軸，new_lawyer 事件因補掃入庫噪音不列）
- `lawyer_members` — 律師公會會員（按地區公會）
- `user_profiles` — 使用者角色 (admin/user)

## 律師異動追蹤（工作流動）

- `scripts/moj_office_refresh.py` — 逐位比對 MOJ API 的事務所/執業狀態，只 PATCH 有變動的律師，trigger 自動記到 `moj_lawyer_changes`
- MOJ API 每筆 ~3-5 秒，全量要 ~15 小時 → `moj-office-refresh.yml` 每日凌晨 1 點按證號 hash 分 7 片跑（`--shard k 7`），一週刷完一輪
- `moj-licno-scan.yml` 每週日凌晨 2 點掃新證號 112~115（發現新進律師，INSERT 也會被 trigger 記錄）；
  另每月 2 日凌晨 2 點**全年份洞補掃**（92~最新、無 years 參數，~5,000 查詢 3~5.5 小時、跳過 detail fetch）——
  抓「早年掃描時查無（停業/未入會）、之後回役」的律師（例：廣于霙 95臺檢證字第7043號，2026-07 補入）
- 注意：`moj_lawyer_detail_fetch.py` **不會**更新 office 欄位（只補 detail），別誤以為它能偵測異動
- **事務所熄燈/新設（mig 117）**：RPC `firm_open_close()` 回 json `{closed, opened}`，前端「異動追蹤」兩張收合卡。
  關閉=追蹤期間有流失（轉所/停業/除名）且現「正常未除名」數歸零；新設=所有成員都是追蹤期間才轉入
  （現職無人缺轉入紀錄、離開者離開前也有轉入紀錄）。firm_key 同 083 flow_firm_key 分所歸戶；
  **整所改名會一關一開同時出現在兩表**（footnote 已標注）。前端對 RPC error 容錯顯示「尚未啟用」
- **除名偵測（mig 079）**：MOJ「確定查無」（200 空 data / 404，`query_lic_status()` 已排除網路抖動）
  兩段確認——首輪記 `dereg_candidate_at`，下輪（≥3 天）仍查無才標 `deregistered_at` +
  state_desc=「名冊查無（推定除名）」（trigger 自動入異動追蹤）；之後又查得到會自動解除（自癒）。
  已除名者不計入 `moj_firm_statistics()` 人數與 `moj_solo_firm_lawyers`；firm modal 清單沉底標「已除名」。
  單筆手動：`moj_office_refresh.py --check <證號>`（唯讀）/ `--mark-dereg <證號>`（三次確認後標記）

## 裁判書開放資料管線（法官統計）

- `scripts/judgment_stats.py`：opendata.judicial.gov.tw 每月裁判書 RAR → 解析全文抽承審法官 → `judge_month_stats`（月聚合）→ RPC `refresh_judge_judgment_stats()` → `judge_judgment_stats` → `judges_combined` view（官方統計優先、Lawsnote fallback）
- **裁判書資料集是「會員限定」**：下載需先 POST `/api/MemberTokens` 登入（帳密在 `scripts/.env` 的 `JUDICIAL_OPENDATA_USER/PWD`，不需 Turnstile）；資料集查詢用 `/api/Datasets?Keyword=YYYYMM裁判書`，下載 `/api/FilesetLists/{fileSetId}/file` 帶 Bearer token
- 月包晚兩個月發布（約每月 15 日）；`judgment-stats-monthly.yml` 每月 17 日自動增量
- 已回填 2020-01 ~ 2025-04；`avg_processing_days` 是估算值（裁判日 − 案號年 1/1），僅供法官間相對比較
- **多 session 注意**：backfill 不要兩個 session 同時跑（會撞 `.judgment_work` 檔案鎖與 upload 重複鍵）

## 法官/檢察官懲戒紀錄（migration 121）

- `scripts/judge_disciplines.py`：FJUD（judgment.judicial.gov.tw）進階查詢 `jud_court=TPJ`
  （懲戒法院職務法庭＋改制前司法院職務法庭，101 年起全量 164 篇）→ 解析被付懲戒人/
  機關/主文/結果分類 → `judge_disciplines`（(case_no,name) upsert 冪等）
- FJUD 流程：Default_AD.aspx POST → 中繼頁 hidden 轉 qryresult.aspx → iframe
  qryresultlst.aspx?q={hash}&page=N（20 筆/頁）；**須 http1.1 + 瀏覽器 UA**，節流 1.2s
- **版式陷阱**：新制當事人列「label＋2+半形空白＋姓名」；舊制（司法院職務法庭）是
  「label＋單一全形空白＋姓名」，101-102 年還有姓名後帶「（機關職稱）」或全形空白＋機關；
  105 年前檢察署舊名「地方法院檢察署」（COURT_RE 長詞優先）
- 「訴/聲/停」字案＝職務案件（法官告司法院）無被付懲戒人，解析為 0 列屬正常
- 手動執行（職務法庭案量 ~2-3 篇/月，久久跑一次即可）；前端＝法官 modal 紅框「懲戒與彈劾」卡
  ＋徽章＋法官名錄 ⚠（兩表聯集 `ensureJudgeDiscSet`）
- **TPP 模式**（`python judge_disciplines.py tpp`）：改制前公懲會＋現制懲戒法庭，
  全文關鍵字「法院法官」（222 筆完整）＋「檢察署檢察官」（**撞 FJUD 500 筆上限，檢察官
  歷史懲戒不全量**，補全需按 jud_year 年度切片）；require_role 過濾非司法人員；
  FJUD 對公懲會收錄約 2006 起，更早年代（含「推事」時代）不在內
- **監察院彈劾**（mig 125）：`scripts/judge_impeachments.py`→`judge_impeachments`；
  CyBsBox GET 分頁（PageSize=200 全量 ~536 件），案由錨定「機關＋職稱＋姓名」＋
  已知司法官名單交叉驗證；**prosecutor_stats 名單含 mig 066 前殘留假名**
  （「提起公」「依通常」「期間」等），靠停用字＋人工覆核清單擋
- **法官評鑑委員會決議書＝死路**：lp-1700 可爬（1,817 筆，案號/主文/PDF 在列表），但
  決議書 PDF 一律遮名（受評鑑法官 呂○○），無法歸戶個別法官；成立案終會進職務法庭（具名）
  已被上面涵蓋，勿再嘗試

## 司法統計（前端「司法統計」區塊 + 官方案件統計管線）

- **前端**：第一層導覽「司法統計」4 分頁（總覽/各法院比較/案由細分/案件專題），從獨立站 judicial-stats 移植進 `public/index.html`。所有 id 加 `jstat_` / `tab-jstat-` 前綴、CSS scope 在 `.jstat` 下、深度分析文章固定白底紙張樣式。資料源是**靜態** `public/data/judicial_stats.json`（統計月報聚合，離婚原因/罪名/家事細項等專題表，年更、半自動——產生 script 不在 repo）
  - **2026-07 Phase 1 整併（8→4 tab）**：原「法院效率」3 圖併入「各法院比較」（`tabBuilders.organs` 同時呼叫 `buildOrganCharts`+`buildEfficiencyCharts`）；原「民事/家事/刑事/強制執行」4 個頂層 tab 收攏成單一「案件專題」（`tab-jstat-topics`），內部為 4 個 `jstat-subpanel`（`tab-jstat-civil/family/criminal/enforcement`，class 由 `tab-content` 改 `jstat-subpanel`，改由 `switchJstatTopic()` 控制顯示、首次啟用才建圖）。內容（含 4 篇 AI 深度文章＋離婚原因/罪名/家非等專題表）**完整保留、未刪任何圖表**。⚠️ **尚未做的**：(a) 總覽動態化（改讀 court_case_stats，待核官方口徑數字）；(b) 圖表層去重——案件專題內的 `*_by_year` 件數趨勢圖與「產業分析>訴訟市場趨勢」(market_year_trend 動態)、「案由細分」(closed_case_cause 動態) 仍重複，待人工核可後移除
- **官方案件統計管線**：`scripts/judicial_official_stats.py`（download/parse/upload/run）→ `court_case_stats` 表（migration 034/037）。來源：opendata datasetId 43994「各級法院各案類新收及終結件數統計」，**公開免會員**，單一 ODS（~18MB，content.xml ~600MB 要串流解析），民國 90 年起 月×法院×案類×程序別（保留至第 2 層），50 萬列聚合成 ~43 萬列。`judicial-official-stats.yml` 每月 5 日全量 upsert（冪等）
- **來源怪癖（查詢必讀）**：最高法院新收件數恆 0（只填終結）；**地院「民事」的 proc_l1 只分 民事/民執**，「民事訴訟 vs 民事非訟（支付命令等）」要看 **proc_l2**（114 年地院：民事訴訟 18.9 萬、民事非訟 83.7 萬、民執執行 204.6 萬=月報強制執行）；刑事訴訟在 l1='訴訟'；114 地院家事新收 183,028 可當解析驗證基準
- **終結案件微資料管線**：`scripts/closed_case_stats.py`（run/auto/backfill/backfill-criminal）→ `closed_case_month_stats`（migration 035/045）。月包每月 ~1MB 7z（搜「終結案件資料」，晚 1.5 個月），`!` 分隔 txt 每案一筆。解析**民事訴訟+家事訴訟**檔（每案一列）＋**地院刑事訴訟**檔（階層式：0!案件 1!被告 1.1!罪名。刑事列：defendant_rep=任一被告「選任律師辯護」含法扶的案件數、plaintiff_rep=自訴人有律師、defense jsonb=被告層辯護分布含公設/義務細分；高院/最高/智財刑事被告層辯護欄位置不同，不解析）→（月×法院×檔型）律師委任率/終結情形分布/標的金額，已回填 2021-01 起。`closed-case-stats-monthly.yml` 每月 20 日 auto 模式。**版式防呆**：民事欄 15-17／刑事欄 13-15 須為合理民國日期，不符跳過（最高法院民訴版式不同未納入）。**court_name 正規化**：202101~202506 月包資料夾名帶「民事/刑事」後綴，script 的 `norm_court()` 去後綴+去空格（migration 045 已清理歷史資料）。**202511 月包曾被官方重傳成殘缺版**（僅離島+簡易庭），2026-07-08 官方已修復、DB 已用完整包重跑補齊（月包可能事後重傳，回填異常月前先抽查檔數，正常 ~300 檔/22 地院）。法官名有值但尚未做 per-judge 聚合（合議庭歸屬待定義）
- **案由細分（migration 064）**：同一管線加聚合 `closed_case_cause_stats`（月×法院×檔型×種類）＋`closed_case_cause_national`（月×檔型×正規化原始案由，供鑽取/mapping 稽核）。mapping 在 `scripts/cause_map.py`（民訴對齊官方 13 類標籤、家非對齊官方細項標籤、刑事用罪名層(法名,條,條之N)→罪章幾乎零歧義；民非/家訴為本站務實分組）。已回填 2021-01~2026-05 全 65 月（202511 曾殘缺，官方 2026-07-08 修復後已補齊）。RPC：`cause_group_yearly`/`cause_raw_top`/`cause_court_matrix`/`closed_case_cause_months`。前端「司法統計＞案由細分」tab（`loadCausesOnce`，不走 jstat 靜態 JSON）。**案由×委任（mig 099）**：`closed_case_cause_rep_stats`（月×檔型×種類×委任四格：雙方/僅原告/僅被告/皆無；種類用 `map_judgment()` 對齊供給面、與 cagg 的 map_cause 家事分桶不同），僅民事訴訟＋家事訴訟檔（刑事辯護口徑不同未做），已回填 202101~202605 全 65 月（`backfill-rep` 模式）；RPC `cause_rep_yearly(p_file_type)` 供前端案由供需「委任率」欄＋modal 委任分布。run_month 另加殘缺月包防呆（民訴 <15 法院即中止上傳）。**覆蓋率實測（官方113 vs 本表2024）**：民訴 82%（主要類別佔比差±1.5pp）、刑事科刑 92%（傷害類 63%）、民非 39%、家非僅 16%（保護令等不在檔內）——家非/民非佔比僅供結構參考，footnote 已標注。案由字串偶含 \x00，`norm_cause()` 已清（Postgres text 不收）
- **整合呈現**：法院 tab 法院名可點 → `courtModal`（RPC `court_detail_stats`，migration 036/037：官方年度趨勢＋訴訟終結vs公開裁判書＋委任率＋終結情形）；司法統計>各法院比較有「律師供需比」圖（民事訴訟新收÷公會地區律師數，新北律師少時併台北），可切換「所有案件/有委任律師的案件」——後者=官方新收×地區委任率（closed_case_month_stats：民事任一造有律師、刑事任一被告選任律師含法扶），缺資料地區 fallback 全國率

## 爬蟲模式（moj-deep-backfill.yml）

- `licno-scan` — 證號遍歷（全年份）
- `licno-108-115` / `licno-recent` — 限定年份
- `deep-all` / `deep-targeted` / `deep-surnames` / `deep-triple` — 不同策略補掃
- `full` — 全量掃描

## 裁判書管線（judgment_stats.py）

- 產出三張月統計表：`judge_month_stats` / `lawyer_month_stats` / `prosecutor_month_stats`
  （法官署名、訴訟代理人/辯護人、檢察官，均含 cats 案類 jsonb）
- **律師抽取地雷**：一個「訴訟代理人/辯護人」標籤常帶多位律師（同行或續行縮排），
  舊 regex 只抓標籤後第一個 → 受僱律師全漏（喆律版圖只剩掛首位的主持律師）；
  現版 `extract_lawyers()` 用 block parser 抓續行＋`RE_BAD_NAME` 濾「法扶/義務辯護」等
  假名。**判別是否已用新邏輯跑過**：查 `lawyer_month_stats` 有無「法扶」等假名（有=舊）
- **全區重跑狀態（2026-07 完成）**：1996-01 ~ 2025-04 全 352 月律師抽取已用最新邏輯
  重跑，全區「法扶」假名 = 0、律師 mention 431 萬；早年（~2001）法院名 OCR 雜質由
  `normalize_court()` 正規化（與 migration 038 `fix_court_name()` 同構，改一邊要同步）
- **分類地雷**：家事裁判全文開頭一律寫「民事判決/裁定」（含少家法院），案類必須靠
  字別 JCASE 辨識（婚/家/繼/親/監宣…見 `FAM_JCASE_KEYS`）；改分類邏輯後要用
  `python judgment_stats.py reclassify <起> <迄>` 強制重跑（會刪 agg 快取、覆蓋上傳）
- 家事分析 RPC：`family_judge_stats()`、`family_cases_by_year()`（含 ok_months 回填偵測，
  月家事 >= 300 視為新分類已回填），法官年度趨勢：`judge_days_by_year()`
- **家事律師版圖走 cache 表**（migration 049）：前端讀 `family_lawyer_stats_cache` /
  `family_lawyer_by_court_cache`，勿再直呼 `family_lawyer_stats()`/`family_lawyer_by_court()`
  RPC 分頁（PostgREST 對 RPC 的 `.range()` 是每頁重跑整個函數，曾造成 tab 載入 30s+）；
  `refresh_family_lawyer_stats()` 由 `refresh_stats()` 月更一併呼叫
- 前端「家事分析」頁的回填橫幅依 ok_months 自動顯示/消失
- 每月增量：`judgment-stats-monthly.yml`（每月 17 日抓兩個月前月包）
- **Phase B 案由層（migration 069/070）**：parse 帶 JTITLE → `lawyer_month_stats.causes` /
  `judge_month_stats.causes` jsonb（鍵=「案類|正規化案由」複合鍵，存**原始案由**；
  mapping 改版只需重跑 `sync_cause_map` 相關 remap + `refresh_lawyer_cause_stats()`，
  不必重解析月包）。`cause_group_map`（ck→種類）由 upload 時自動同步，mapping 單一真實源
  = `cause_map.py` 的 `map_judgment()`。彙總表 `lawyer_cause_stats`（滾動 60 月，
  refresh 已掛進 `refresh_stats()`）；RPC：`firm_cause_ranking`（事務所×案由排名，全國口徑）、
  `cause_supply_stats`（案由×供給/集中度）、`cause_group_list`（下拉）。
  前端：律師 modal「案由組成」卡、事務所版圖「案由種類」下拉（選了會停用法院篩選）、
  產業分析「案由供需」tab（民事有 Phase A 市場對照欄，刑事/家事分組口徑不同不硬對；
  點列開 modal 看桶內原始案由明細——`cause_group_causes` 表，migration 080，同掛 refresh 月更）。
  回填：`python judgment_stats.py causefill 202105 202604`（冪等跳過已帶 causes 的月）。
  **年度下鑽（mig 098）**：`lawyer_cause_year_stats`（律師×年×種類，仿地區供需 mig 054 模式，
  `refresh_lawyer_cause_stats()` 尾端自動重建）；`cause_top_lawyers`/`firm_cause_ranking` 加
  `p_year` 參數（NULL=近5年滾動，簽名已變、舊 2 參數版已 DROP）＋`cause_year_list()`。
  案由供需 modal「領域下鑽」用（TOP 律師/事務所可切年度）。
- **律師官方統計（migration 046）**：`lawyer_judgment_stats`（按律師名彙總：cases_5yr
  滾動 60 月錨定資料最新月、cases_total、cats_5yr/cats_all、by_year、top_court_5yr），
  `refresh_lawyer_judgment_stats()` 全量重建（TRUNCATE+INSERT，`refresh_stats()` 月更一併呼叫）；
  前端律師列表/詳情 modal 改讀 `lawyers_with_stats` view（= lawyers_combined LEFT JOIN
  彙總表，含 `name_ambiguous` 同名旗標，同名官方數字是合併值、前端以 * 標註）。
  **Lawsnote `case_count_5yr` 已從 UI 下架**（欄位仍在 DB/view；expertise_areas 等照用）
- **事務所版圖（migration 047）**：`firm_court_ranking(p_cat, p_court)`（案類×法院→事務所
  近 5 年出庭排名，firm_name 截到第一個「事務所」合併分所、排除「未提供」、同名律師不計）＋
  `lms_court_list()` 法院下拉；前端「產業分析＞事務所版圖」tab（喆律綠色 highlight）；
  事務所 modal 另有「官方訴訟戰力」區塊（案類覆蓋/明星依賴度/法院版圖，client-side 讀
  lawyers_with_stats）。加了 `idx_lms_court` 索引。
  戰力區塊可切年份（migration 053 `firm_lawyer_year_stats(p_names)`，每年一列 jsonb 避開
  PostgREST max-rows），並顯示近期人員異動影響（moj_lawyer_changes，2026-07 起追蹤）；
  **口徑注意**：全部按「現任名冊」回溯——轉入律師帶入過往案量、已離所者不計，年份越早失真越大
  （裁判書不署事務所名，無法回溯當年在籍，此為資料天花板）
- **事務所 avg_cases 也已換官方口徑（migration 048）**：`moj_firm_statistics()` 分子改
  lawyer_judgment_stats.cases_5yr（MOJ 名冊姓名唯一者歸戶）÷ MOJ 人數，Lawsnote 案件數
  自此完全退出 UI 與統計鏈

## 訴訟客戶集中度（migration 071）

- `scripts/client_concentration.py` → `lawyer_client_concentration` 表（律師 modal「訴訟客戶集中度」卡）
- 口徑：近 12 個月裁判書當事人欄、法人（公司/組織/機關）per 案去重、top1_share 分母含個人當事人案件；
  分級 A（≥5 件且 Top1≥60%）/ B（≥3 件且 Top1≥50%）/ C 分散 / D（<3 件）
- **2026-07-17 起涵蓋全體有出庭律師**（首發僅人名事務所 1,609 位）；`collect` 逐月產 `{ym}_clients.jsonl.gz`
  快取（RAR 處理完即刪），`aggregate` 讀快取全量重建上傳——調法人判定/分級門檻只需重跑 aggregate
- 視窗滾動更新：手動跑 `python client_concentration.py run <START> <END>`（新月份 collect 快取即可，
  舊月快取還在就不會重下載）；無排程，資料月更後想更新再跑

## 律師×訴訟標的金額（migration 171，join 口徑）

- `scripts/lawyer_case_amount.py` → `lawyer_case_amount_stats`（ym×律師×金額桶案件數）：
  終結案件微資料月包（民訴＋家訴檔，**每列倒數第二欄自帶完整 JID**、官方登錄標的金額）
  × `{ym}_clients.jsonl.gz`（client_concentration collect 產物）按 JID 前 4 段
  （法院代碼,年,字別,號）join；clients 側**全 cat 收**（民訴檔含高院家事二審）。
  202503 試跑：有委任民訴案 join 率 97.8%（含家事 cat 99.1%）。已回填 202111~202606
  （clients 快取起點=202111，硬邊界）。上傳前 DELETE 該月再 INSERT，重跑冪等。
  ⚠️ **快取要按該案 JID 的裁判月查、不是終結月**——2025-08 起約 1/3 案件裁判月早於
  終結月（宣示後隔月才報結），只查終結月快取 join 率會從 ~99% 掉到 ~60%；
  join 邏輯改版後用 `refill` 模式全區重跑
- **金額欄版式陷阱**：高院系民訴檔金額在欄 27/28、地院在 28/29（差一欄）——本管線掃整列
  找「新台幣」欄通吃；**closed_case_stats.py 的 parse_line 仍是寫死 c[28]/c[29]，
  高院金額全漏**（closed_case_amount_rep/amount_sum 無高院，待修）。最高法院民訴版式
  仍不相容（date 檢查自然擋掉，appeal3 恆 0）
- 同趟另出 `lawyer_case_fee_stats`（mig 172，收費模型 v2 供 firm_dossier 批次分析）：
  律師×月的 cases_200plus／surcharge_base_sum=Σmax(0,金額−200萬)／appeal2_cases
  （JID 代碼 TPH/TCH/TNH/KSH/HLH/KMH 開頭）／appeal3_cases（TPS，恆 0）
- 取代 mig 170 `lawyer_amount_month_stats`（裁判書全文 regex 抽取：1-10萬桶高估 ~6 倍、
  月樣本量僅 join 口徑 1/5.6）的分析口徑；舊表暫留、**前端兩者皆未接**
- 無排程：新資料月的 clients collect 跑完後手動 `python lawyer_case_amount.py run <ym>`

## 司法人力：書記官（migration 104）

- 三表：`clerk_staff_stats`（審級×年 104–114）/ `clerk_court_snapshot`（114 年各法院 29 個）/
  `clerk_exam_stats`（司法特考四等書記官 104–114）；前端＝**第一層「書記官」區**（檢察官後）
  單一總覽 tab（KPI＋特考／審級趨勢／各法院三卡；2026-07-17 自供給預測尾端升級，無個人名冊）
- `scripts/clerk_staff_stats.py` 解析司法統計年報各機關「員工實有人數」ODS（年更：年報
  6–7 月出，換 `CLERK_STATS_LP`（114 年報=2475）重跑，輸出 INSERT 貼進新 migration）
- **解析陷阱**：欄位靠英文表頭分類（中文表頭跨列合併不可靠）——`Assist-ant Clerk`（錄事，
  印刷斷字）與 `Clerk of the Accounting Office`（會計課員）都不是書記官；寬表會橫向分頁成
  多張 sheet（地院機關別 4 張）；法院名藏在 `<text:s/>` 的 tail，要用 `itertext()`；
  個別地院只有男/女列（無計列）、高院表法院名在第 1–2 欄巢狀
- 特考數字＝公職王/高點彙整（108–114 兩源交叉一致；104–107 需用名額無公開資料留 NULL）；
  書記官異動不經人審會，**無**法官 `judge_transfers` 式結構資料；缺額（2026-03 全國 353 人）
  僅新聞/司法院說明，前端靜態引用

## B2B 霸凌線 → 已搬到獨立專案（2026-08-04）

職場霸凌業務線的網站與人才庫同步**不在本 repo**，見 `C:\projects\bullying-intel`
（private repo，Cloudflare Pages → https://bullying-intel.pages.dev）。

留在本 repo 的只有**已套用的 migration 檔**（`138_wbie_experts.sql`／
`139_b2b_competitor_rpc.sql`，套用歷史紀錄）。相關資料表 `wbie_experts` /
`wbie_sync_log` / `wbie_watchlist` / `b2b_kpi_entries` 仍在同一個 Supabase project，
後兩張是 admin-only。**migration 編號是跨兩個 repo 的單一序列——開新號前要同時看
兩邊的最大編號**。

## 010 合作律師 tab（migration 073）

- 律師區子頁 `law010`（喆律校友會旁）：法律010 平台合作律師 × MOJ 現職所 × 官方案量
- 資料源 `fact_010_monthly_lawyer`（lawyer-dashboard `sync_010.py` 每日重建，2023-11 起）→
  view `law010_lawyer_summary` 即時聚合（歸戶分所條目、排除喆律所內列、months jsonb 逐月明細），
  **無需另外 refresh**；只 grant authenticated（010 業績是內部資料，已 revoke anon）
- 前端 client-side JOIN `lawyers_with_stats`（同名者以 010 案件地區推定，推定不了標「同名 N 筆」）＋
  `moj_firm_stats_cache`（事務所規模）；「理湛」（理湛聯合）「安承」（Anherit 品牌）為非個人條目，
  走前端 `LAW010_FIRM_ALIAS` 對照
- **admin 限定（mig 075）**：本頁＋喆律校友會僅 admin 可見。資料鎖在 DB（zhelu_alumni
  admin-only SELECT policy；law010_lawyer_summary 的 admin gate 寫在 **view 內**——view owner
  繞底表 RLS、grant 分不出 admin；副作用：service key 查該 view 回空，測試要 set request.jwt.claims
  模擬）。UI 用 SECTIONS `adminOnly` 旗標＋profile 載入後重繪子頁列

## 前端導覽結構

- 兩層導覽：第一層 `showSection()`（律師/法官/資料來源/帳號管理），
  第二層子頁定義在 `SECTIONS` 常數（index.html），新增子頁要同時加 tab-content div
  和 `showTab()` 的 lazy load 分支
- **重要：tab-content div 全是同層 siblings，`showTab()` 只依 id 顯示對應 div、與所屬 section 無關**
  → 把子頁在 section 間搬移只需改 `SECTIONS`（div 不必實體移動）
- **2026-07 Phase 1 產業分析整併**：家事法官（`family`）從產業分析移到**法官區**（純 SECTIONS 改）；
  「家事律師/事務所版圖/案由供需」收攏成「**領域版圖**」（`tab-domain`，內部 3 個 `domain-subpanel`：
  `tab-fam-lawyers/firm-map/cause-supply`，class 由 `tab-content` 改 `domain-subpanel`，
  `switchDomainTab()` 控制顯示、各 builder lazy-load 一次不變）。產業分析 6→3 tab
  （訴訟市場趨勢/領域版圖/人才流動）。
- **2026-07-15 總覽拆分（律師區 6→7 子頁）**：`overview`=律師總覽（母體結構＋六張排行卡：
  近5年出庭TOP10=lawyer_judgment_stats 直查、訴訟領域律師TOP10=`cause_top_lawyers` RPC
  （mig 093，案類 chips＋案由種類下拉，種類清單借 cause_supply_stats 按件數排序、預設跳過
  「其他」剩餘桶）、活動量成長榜（lawyer_growth，自訴訟市場移入，`renderMarketGrowth` 沿用）、
  TIPO 代理人 TOP10、獨董席次榜=firm_indep_directorships client-side 聚合、政府標案榜=
  `gov_top_lawyers` RPC（mig 093））；新增 `firm-overview`=事務所總覽（KPI 群自名錄頁移入、
  規模分布+人數TOP10 自舊總覽移入、**事務所版圖整包自產業分析移入**（fm* ids/loader 不變，
  `loadFirmMapOnce` 改由本頁觸發）、人才流動快照=firm_flow_ranking 前5、TIPO 事務所、
  獨董/標案事務所榜）；`lawyers`/`offices` 改純名錄。訴訟市場剩 4 子分頁（市場趨勢已無
  律師活動量卡）。共用 helper：`rankListHtml()`／`initTipoCard()`／`gotoTab(sec,tab)`。
- **2026-07-15 人才流動併入異動追蹤**：原產業分析「人才流動」（`tab-firm-flow`，mig 083
  firm_flow_* RPC）4 區塊（累積 KPI／團隊出走矩陣／累積淨流排行／新血招募）整段搬進
  律師區「異動追蹤」（`tab-changes`）異動明細之後，內容完整保留、獨立 tab 已刪。
  `loadFirmFlowOnce()` 改由 `showTab('changes')` 觸發；累積口徑（分所歸戶、不受時間窗
  篩選）已在 UI 標注與頁尾說明。`buildSectionIndex()` 不再跳過含 `.ff-toggle` 的分頁，
  點索引 chip 會自動展開收合卡片。⚠️ **未做**：「地區市場」（公會 tab＋總覽地區分布圖＋
  訴訟市場趨勢內嵌 region_top 合併）——DB 驅動需登入才能驗渲染，待人工核；領域版圖內三面板的
  重複件數圖也待內容層去重

## Migration 注意

- **新增 migration 前先看目錄最大編號**（曾發生兩個 session 同時開 029 撞號）
- 套用方式：`supabase db query --linked -f supabase/migrations/xxx.sql`（CLI 已 link）

## 使用者偏好

- 溝通語言：中文
- 技術偏好：盡量簡單，不要過度工程化
- 爬蟲完成後記得 call `refresh_firm_stats_cache` 更新前端顯示

## 已知 Gotchas

- Supabase 是 **Micro compute (1GB RAM)**，爬蟲若一次載入太多資料會讓 DB 不穩
  - `fetch_existing_lics()` 已優化為按年份分批讀取
  - 上傳 batch size 50、每次上傳後 sleep 2s
- `moj_firm_stats_cache` 需手動 refresh（爬蟲 workflow 最後會 fire-and-forget 呼叫 RPC，server 端非同步跑完）
- 前端登入後若無資料可能是 RLS 設定問題（需 auth.uid() IS NOT NULL）

## DB Schema 關鍵欄位（避免查詢時踩坑）

### `lawyers_combined` view（三源合併：MOJ + 全聯會 + Lawsnote）
- 律師證號欄位叫 **`moj_lic_no`**（不是 `lic_no`）
- 年資用 **`lic_year`**（民國年，如 74 = 1985 取證）
- 性別欄位 **`moj_sex`**（值為「男」「女」）
- 事務所名 `firm_name`、地區 `region`、案件數 `case_count_5yr`
- 專長 `expertise_areas`（text[] array，來自 Lawsnote）

### `firm_profiles` 欄位型別
- **`practice_focus` 是 `text[]`**（array，不是 TEXT）— PATCH 時必須傳 JSON array
- `founded_year` INT、`ai_analysis` TEXT、`news_links` text[]
- upsert 用 `Prefer: resolution=merge-duplicates` header

## 分析事務所的標準流程（依序做，避免來回查詢）

1. 查 `moj_firm_stats_cache`（人數、地區、平均案件數、官網）
2. 查 `lawyers_combined` 完整律師清單（按 `lic_year` 排序，找資深 + 案件量大的 = 所長候選）
3. 查 `firm_profiles` 既有資料（避免蓋掉使用者筆記）
4. WebFetch 官網確認所長身分 + 事務所特色
5. **分析必查「前司法官」因子**（重要差異化指標）— 從官網、新聞、團隊介紹中找：
   - 前法官（地方法院／高等法院／最高法院）
   - 前檢察官（地檢署／高檢署／最高檢／特偵組）
   - 前司法官訓練所結業律師
   - 前大法官本人（不含助理）
   - **不算前司法官**：法官助理、檢察事務官、書記官、司法事務官、司法官考試及格但未任職
   - **驗證規則**：
     - WebSearch 結果必須與 DB 中該所實際律師**姓名核對**（同音字可能是不同人！我曾把「孫少輔（喆律）」誤認為「孫紹輔（昊鼎）」）
     - 用 `curl .../lawyers_combined?name=eq.{人名}&firm_name=eq.{所}` 驗證身份存在
     - ai_analysis 文字掃描+WebSearch 雙重驗證（原分析可能遺漏、WebSearch 可能張冠李戴）
6. 寫分析到本機暫存檔（避免 bash heredoc 踩 encoding）
7. Python PATCH `firm_profiles`：
   - `ai_analysis`, `ai_analyzed_at='now()'`
   - `practice_focus`(array), `founded_year`
   - **`ex_judicial_officers`(array)** — 格式：`['姓名｜職稱｜附註', ...]`，例如 `['陳樹村｜前高雄地方法院法官｜23 年法官資歷']`
8. 更新 `public/index.html` 的 `FIRM_LEADERS` + `FIRM_TAGLINES`
9. commit + push（GitHub Pages 自動部署）

## ⚠️ 所長判斷規則（嚴格防止 LLM hallucination）

寫入 `FIRM_LEADERS` 前**必須驗證**：
1. **所長姓名必須是該所 `lawyers_combined` 或 `moj_lawyers` 中真實存在的人**
2. **官網只有英文品牌名（如「Daniel Park Law Office」、「H&W LAW」、「WTW」）時不得自行音譯推測中文名**
   - ❌ 錯誤案例：看到「Daniel Park Law Office」就寫「朴大同」
   - ✅ 正確做法：英文品牌名就當作事務所名稱，不強行對應人名
3. **若真實所長不在 MOJ 名冊中**（已退休、外籍、轉職等），仍可加入 FIRM_LEADERS，但必須同時加入 `FIRM_LEADERS_NOT_IN_MOJ` Set，前端會顯示 ⚠️ 而非 👑
4. **分析寫入後應跑驗證 script**：
   ```python
   # 驗證所長存在於該所 DB 律師名單
   q(f'/rest/v1/lawyers_combined?firm_name=eq.{firm}&name=eq.{leader}&select=name&limit=1')
   ```
   若回傳空陣列 → 要麼刪除該所長，要麼加入 `FIRM_LEADERS_NOT_IN_MOJ`

### 一人所自動認定所長（mig 060，2026-07-08 雷皓明拍板）

- 名稱含「事務所」、分所合併（`firmKeyRe`）後全所僅 1 位、狀態「正常」的律師，**系統自動視同所長**（約 3,700 家）。這是 DB 事實推定，不經人工查證，屬使用者明確決策。
- 資料源：view `moj_solo_firm_lawyers`（firm_key/name/firm_name）；前端 `ensureSoloFirms()` 載一份 Map，`leaderInfo(name, firmName)` 是所有 👑 顯示點的統一入口（白名單優先）。
- 顯示上與人工查證的 `FIRM_LEADERS` **不做區別**（同樣 👑＋「所長」，僅 tooltip 註明一人所），涵蓋：律師列表、事務所列表、事務所 modal 律師清單、律師 modal、地區排行。
- 多人所仍走 `FIRM_LEADERS` 白名單＋上述驗證規則，不受此規則影響。

## Windows console encoding 注意

- Python print 中文到 stdout 會顯示亂碼（CP950），**不代表 DB 寫入失敗**
- 驗證時用 `PYTHONIOENCODING=utf-8 python -c ...` 才能看到正確中文
- 或用 HTTP status code（200/204）判斷成功即可，不要依賴 console 輸出

## Claude Code 相關

- Skill `/legal-research` — 法律產業深度研究助手（查 DB、分析事務所、討論產業趨勢）
- `ANTHROPIC_API_KEY` 僅用於 `generate-insights.yml` workflow（AI 市場分析，已改為前端 Edge Function 觸發）
