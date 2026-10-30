# 法務部律師查詢系統改版（2026-10-29）— 自動化可能性研究

## 事件

- 2026-10-28 晚 ～ 10-29 晚之間，`lawyerbc.moj.gov.tw` 由 Vue SPA＋JSON API 改為 ASP.NET 伺服器頁。
- 舊的 `/api/cert/*` 全部下架（回 IIS 404 HTML）。受影響腳本：`moj_office_refresh.py`（每日分片刷新）、
  `moj_alumni_refresh.py`、`moj_licno_scan.py`／`moj_licno_scan_early.py`（證號遍歷補掃）、
  `moj_lawyer_detail_fetch.py`、`moj_lawyer_scraper.py`（公會人數→`industry_stats`）。
- 舊碼把一切 4xx 當「查無此證號」，分片 4/7 誤記 1,910 筆除名候選（commit 34431ef 已修：4xx 非 JSON 判 flaky＋查無比例 >5% 中止）。
- 10/30 停用四條 workflow：`moj-office-refresh`、`alumni-refresh`、`moj-licno-scan`、`scrape-moj-lawyers`。

## 新站結構（2026-10-30 實測）

| 路徑 | 方法 | 驗證碼 | 內容 | 可自動化 |
|---|---|---|---|---|
| `/Home/search` | POST `{keyword,name,lic_no,sort,captcha}` | **每次查詢一組，用過即作廢** | 最多 100 筆：`name / now_lic_no / office / guild_name / id_no` | 否 |
| `/lawyer/{id_no}` | GET | 待驗證（id_no 只從查詢結果取得） | 律師基本資料頁 | 待驗證 |
| `/Home/VerifyLawyerHash` | POST `{hash}` | 否 | 以證書雜湊（0x＋64 hex）查驗 | 否（雜湊無法列舉） |
| `/Home/GuildCounter` | GET | 否 | 16 公會會員數（伺服器端渲染 HTML） | **是**，可取代 `sdlyguild/summary` |
| `/Guild/Info` | GET | 否 | 公會聯絡資訊 | **是**，可取代 `sdlyguild/info` |
| `/Home/LoadDisciplineSearch` | GET | 表單無驗證碼欄位 | 懲戒決議書查詢表單 | 待驗證 |

- 查詢結果換排序時後端以「Session 內已驗證的條件」放行，不需重打驗證碼；但條件一改就要新碼，無法擴張成批次。
- 無 `robots.txt`（404）。法務部網站「資料開放宣告」採政府資料開放授權條款第 1 版——這是**內容授權**，與網站的技術存取控制（驗證碼）是兩回事；驗證碼不繞。

## 既有替代資料源（DB 實測 2026-10-30）

| 來源 | 筆數 | 有證號 | 有事務所 | 與 moj_lawyers（執業中 13,505）可對上 |
|---|---|---|---|---|
| 全聯會名單 `lawyer_members`（nab.twba.org.tw，無驗證碼，每週爬） | 7,679 | 否 | 否 | 姓名 7,657；姓名＋公會 6,363（47%） |
| Lawsnote `lawsnote_lawyers`（每週爬） | 8,842 | 6,243 | 2,734 | 證號精確對上 3,437（25%） |

- `moj_lawyers` 執業中同名者 320 組 → 姓名比對必須配公會，仍有殘餘歧義，自動除名只能標「待確認」。
- 全聯會名單只覆蓋約一半執業律師（各地方公會加入全聯會名單的完整度不一），不能當「不在名單＝除名」的依據；
  只能當**正向訊號**（名單上「執業迄日」已過＝停止執業）。

## 結論

1. **全名冊自動刷新（事務所異動＋除名偵測）目前沒有不繞驗證碼的做法。**
2. 可立即恢復：公會人數統計（`GuildCounter`）→ `industry_stats`；公會聯絡資訊（`Guild/Info`）。
3. 可部分恢復：以全聯會「執業迄日」做停止執業偵測（覆蓋約 47%，同名需人工確認）；Lawsnote 事務所欄補事務所異動（覆蓋 20%）。
4. 半自動：人工過驗證碼、程式整理結果。每碼最多 100 筆，全名冊約 140 次，只適合小名單（校友 ~52 位、競品所）。
5. 正式途徑：依法務部資料開放宣告，向資訊處申請名冊資料集或 API（開放資料平臺 139256 目前只是系統說明 CSV）。

## 2026-10-30 下午人工驗證結果（人工在 Chrome 操作）

- **前綴查詢可行**：`115臺檢證字第193` 回 74 筆（19300～19399）。`115臺檢證字第19` 回「找不到或超過 100 筆」——
  這句錯誤訊息兩種情況共用，不能區分。
- **MOJ 事務所／公會資料每週四批次更新**（頁面明文；更新截止日 115/10/29）→ 刷新節奏每週一次即可，日分片已無意義。
- **`id_no` ＝ 資料雜湊值**（`0x`＋64 hex，詳細頁也印在「資料雜湊值」欄），不可推算。
- **詳細頁 `/lawyer/{hash}` 是公開資源**：無 cookie 的 curl 直接 200；假雜湊 404（0 byte）；HEAD 也可（0.1 s）。
  內容：執業狀態、姓名、英文姓名、性別、出生年、證號、公會、事務所、email、電話、地址、懲戒、備註、發布日期、更新日期、區塊鏈交易序號。
  全頁 1.4 MB 是大頭照 base64 內嵌（offset ≈ 19.9 KB 起）；**所有欄位都在前 20 KB**，串流讀到 32 KB 即可斷線。
  Range 不支援（回 200 全頁）。
- **雜湊穩定性**：抽查一位 115 年新科律師，舊 API ut_date 2026-07-09（有 1 筆異動），但區塊鏈發行日 2026-06-04、頁面更新日期 2026-10-29；
  雜湊未隨 7/9 異動重發 → 偏向穩定。下週四更新後以 404 率再確認。
- 查詢次數（用現有名冊算）：一律三位數區段 383 次；小系列（≤100 人，105 個）整系列一次查＋大年度切三位數 **322 次**（最大區段 93 人、0 個破百）；
  若多條件一次查成立（`A B` 半形空格）可壓到約 135 次（**未測**）。39 筆 lic_no 格式異常（無「第」或無「號」）另列人工。

## 決定的架構：兩層

1. **每週自動掃描（免驗證碼）** `moj_detail_sweep.py`：每週五對已知 `page_hash` 逐頁 GET、讀前 32 KB、解析欄位、
   比對 `moj_lawyers`（office_normalized / guild_names / state_desc / 懲戒），異動經既有 trigger 進 `moj_lawyer_changes`；
   404 → `page_hash_missing_at`，進人工複查佇列。速率 ≤1 req/s（全量約 4 小時，可分片）。
2. **人工過碼（小量）**：瀏覽器端助手（書籤小程式）——同仁在法務部網頁自己打驗證碼搜尋，助手讀
   `$('#table_QueryResults').bootstrapTable('getData')`（含 `id_no`）POST 到 `moj_search_harvest`，並顯示下一條查詢字串。
   一次性建表 322 次（約 1 小時，可分天）；之後每週補最新年度新區段 1～3 次＋404 佇列。
3. 不做的事：任何形式的驗證碼自動化（OCR、語音念碼端點、Session 重用）。

## 實作狀態（2026-10-30 晚，分支 `feat/moj-detail-sweep`，尚未合併）

| 項目 | 檔案 | 狀態 |
|---|---|---|
| migration 253 | `supabase/migrations/253_moj_page_hash_and_harvest.sql` | **已套用正式庫**。`moj_lawyers` 加 `page_hash`（部分唯一索引）、`page_checked_at`、`page_hash_missing_at`；新表 `moj_search_harvest`（id_no＋lic_no 唯一、CHECK 雜湊格式與長度）、`moj_harvest_queries`（每次送出一列，含 0 筆）；寫入入口 RPC `moj_harvest_submit(p_query, p_rows)`（SECURITY DEFINER，anon 可呼叫，單次 ≤200 列，去重插入、只回筆數）；anon 可讀的聚合 view `moj_harvest_progress`（不含姓名／證號）。收成原表只有 admin 能讀。anon 實測：格式錯 400、讀原表回空、RPC 去重正確 |
| 查詢清單 | `scripts/moj_query_plan.py` | 完成、已實跑。全量 **327 條**（研究估 322，差在前綴計入已除名者），單條預期最多 95 筆、0 條破百；校友試跑 36 條（54 位校友：對上 47、名冊查無 6、同名非本人 1）；每週增量 5 條。格式異常 39 筆另列 CSV 附建議寫法。`--publish` 寫 `public/tools/moj-harvest-plan.json`（只放前綴型查詢與預期筆數）；完整證號的 404 複查佇列只進本機 CSV（`scripts/.moj_harvest_work/`，已 gitignore） |
| 書籤助手＋進度頁 | `public/tools/moj-harvest.js`、`moj-harvest.html` | 完成。**官網 CSP 的 connect-src 只允許 'self' 與 etherscan，書籤在官網頁內直接 POST 到 Supabase 會被瀏覽器擋** → 改成書籤讀頁面上已顯示的結果表、開收成頁並把資料放網址 # 片段（不送任何伺服器），由收成頁呼叫 RPC 寫入後立刻清掉網址。查詢字串以官網全域 `lastSearch`（最近一次通過驗證碼的條件）為準，最近一次按搜尋失敗時改問「要不要記成 0 筆」，避免把殘留的舊結果記到新字串下。收成頁由自己的網址組書籤，本機起靜態伺服器即可在合併前實測。本機預覽已驗證：寫入、0 筆標黃、下一條自動前進。官網實測一條已通過（見「首次實測」節） |
| ingest | `scripts/moj_harvest_ingest.py` | 完成、dry-run 通過（佇列 0 筆）。三元組比對＋（臺檢證／臺證／補證）類型＋編號備援、姓名需一致；名冊沒有的新律師先 GET 詳細頁核對證號才插入（收成入口是公開的，擋假資料）；雜湊已掛別人、同證號多筆、姓名不同都留在佇列給人看 |
| 詳細頁解析 | `scripts/moj_detail_page.py` | 完成。DOM 依實抓頁面寫（標籤 el-col＋值 el-col），存檔與線上各測一頁，15 個欄位全取到；讀到 32 KB 或 `data:image` 即斷線，不下載大頭照；404 且 0 byte 才算「查無」，404 帶錯誤頁算連線問題 |
| 每週掃描 | `scripts/moj_detail_sweep.py`、`.github/workflows/moj-detail-sweep.yml` | 完成、dry-run 通過（目前 0 位有雜湊）。≤1 req/s、三片依序跑（`max-parallel: 1`）、每週五 UTC 00:00；404 → `page_hash_missing_at`（**非除名**），404 率 >5%（看過 ≥100 頁）中止；頁面證號與 DB 不符不寫入；查得到者自動清除除名候選／旗標（10/29 事故的誤標會隨掃描自癒）；懲戒欄舊表是 HTML 連結、新站是純文字，只把「有／無」翻轉算異動。結尾印「異動摘要 BEGIN/END」 |
| 公會人數 | `scripts/moj_lawyer_scraper.py` | 改讀 `/Home/GuildCounter`、`/Guild/Info`、首頁更新截止日（伺服器端 HTML、免驗證碼），三份存檔解析通過（16 公會 13,603 人、17 列公會資訊全部對上既有 ID）。公會 ID 依 DB 修正（宜蘭 ELBA、台東 TDBA）。**`scrape-moj-lawyers` 尚未重新啟用**——workflow 跑的是 main，合併前啟用會跑到舊碼 |

### 首次實測（2026-10-30 晚，本機測試版收成頁）

- 書籤在官網可執行（Chrome 未對書籤套用頁面 CSP）；官網查 `103臺檢證字第117` 回 75 筆＝清單預期 75。
- 整條鏈跑通：收成 75 筆 → ingest 寫入雜湊 75（對上率 100%）→ sweep 75 頁全部 200、0 個 404、0 個雜湊不符、1.4 分鐘；
  記到 1 筆真實事務所異動（trigger 正常寫入 moj_lawyer_changes），並清掉這段 14 筆 10/29 事故誤記的除名候選。
- 立即重跑 sweep：0 異動、0 同步（冪等）。
- 修過的 bug：書籤產生時佔位字串只換第一個（換到註解），書籤退回正式站網址 → 改全部替換；sweep 把「清除除名候選」算進異動數 → 另計。

### 合併後要做

1. `gh workflow enable scrape-moj-lawyers.yml`，手動 `gh workflow run scrape-moj-lawyers.yml` 驗一次 `industry_stats`。
2. 舊的 `moj-office-refresh.yml`／`moj-licno-scan.yml`／`alumni-refresh.yml` 維持 disabled：**由 sweep＋人工收成取代，待一次性建表完成、sweep 跑過一輪後刪除**（含 `moj_office_refresh.py` 的除名兩段確認：新站沒有「確定查無」訊號，404 只進複查佇列）。
3. 校友試跑整條鏈：收成頁「校友試跑」36 條 → `python moj_harvest_ingest.py` → `python moj_detail_sweep.py --limit 50`（或 dispatch workflow 帶 limit）。
4. 一次性建表 327 條分天做；每週增量用「每週增量」清單（`python moj_query_plan.py --incremental --publish` 重產）。
5. 第一次整輪 sweep 後看 404 率：>5% 會自動中止——代表雜湊會重發，要改成「每週重收成」而不是掃已知雜湊。

### 未解／待觀察

- 雜湊是否會隨週四更新重發：下週五第一輪 sweep 的 404 率就是答案。
- 書籤小程式在官網（CSP 嚴格）能否執行：Chrome 一般不對書籤套用頁面 CSP；若被擋，改用「複製程式碼」貼到 DevTools Console。
- 官網查詢字串對「台／臺」與括號是否寬鬆比對：清單照名冊原字串切（`89台檢證字第` 與 `89臺檢證字第` 各一條），實際查詢若互通，少數條會重複收到同一批，ingest 會去重。
- 39 筆格式異常證號的建議寫法沿用舊 API 怪癖（`(80)臺檢證字第…`、92 年後補證補零），以官網實際顯示為準。

## 合併後狀態（2026-10-30 晚）

- PR #1 已 squash 合併進 main；正式站收成頁 `https://dennislei-web.github.io/legal-industry-intel/tools/moj-harvest.html` 上線（書籤要在正式站頁重新拖一次）。
- `scrape-moj-lawyers` 已重新啟用並手動實跑成功：16 公會合計 13,603 人、寫入 17 筆 `industry_stats`、快取刷新 OK。
- **每週掃描改本機排程**：GitHub runner 打官網，75 頁有 26 頁重試兩次仍失敗（200＋805 bytes「Error」頁，或整個 runner 連線被切；常是同一批頁面），本機（台灣 IP）兩輪 75/75。
  → Windows 排程 `moj-detail-sweep-weekly`（每週五 09:30，pythonw 跑 `scripts/moj_detail_sweep_weekly.py`：ingest → sweep → 三支 refresh RPC），
  log 追加到 `scripts/moj_detail_sweep_weekly.log`（含姓名，已 gitignore），最後一行 `[launcher] ingest_rc=… sweep_rc=… refresh_ok=N/3`。
  `moj-detail-sweep.yml` 只留手動觸發；`fetch_detail_retry` 對暫時性失敗退避重試（5s、15s）。
- 舊 `moj-office-refresh`／`moj-licno-scan`／`alumni-refresh` 仍 disabled，一次性建表完成、本機 sweep 跑過一輪後刪除。

## 校友試跑結果（2026-10-30 晚，本機排程手動觸發）

- 收成 36 條：預期 2,630、收到 2,586（差額≈已除名者）、不重複雜湊 2,579。
- ingest：2,504 筆待處理 → 寫入雜湊 2,490、新律師 6（核對詳細頁後入庫）、留佇列 8（全是「姓名不同」）。
- sweep：2,571 頁全 200、0 個 404、0 雜湊不符、0 連線失敗，44 分鐘；真實異動＝事務所 8 筆＋懲戒 1 筆（異動追蹤表實寫 firm_change 8、new_lawyer 6）；清除 10/29 誤標除名候選 356 筆。
- **姓名不同 8 筆全是同一人**：異體字（勲／勳、姸／妍、澐／芸）或官網查詢結果少一個字（罕用字／造字顯示不出）→ ingest 放寬為「證號唯一對上＋姓氏相同＋只差一字」即採證號對應，名冊姓名不改（身分由 sweep 核對詳細頁證號把關）。
- 計數修正：懲戒欄舊 HTML 換新站純文字（這批 13 位）不再算進「異動」。
