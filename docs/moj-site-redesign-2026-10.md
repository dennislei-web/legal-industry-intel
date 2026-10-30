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

## 2026-10-30 下午人工驗證結果（雷本人在 Chrome 操作）

- **前綴查詢可行**：`115臺檢證字第193` 回 74 筆（19300～19399）。`115臺檢證字第19` 回「找不到或超過 100 筆」——
  這句錯誤訊息兩種情況共用，不能區分。
- **MOJ 事務所／公會資料每週四批次更新**（頁面明文；更新截止日 115/10/29）→ 刷新節奏每週一次即可，日分片已無意義。
- **`id_no` ＝ 資料雜湊值**（`0x`＋64 hex，詳細頁也印在「資料雜湊值」欄），不可推算。
- **詳細頁 `/lawyer/{hash}` 是公開資源**：無 cookie 的 curl 直接 200；假雜湊 404（0 byte）；HEAD 也可（0.1 s）。
  內容：執業狀態、姓名、英文姓名、性別、出生年、證號、公會、事務所、email、電話、地址、懲戒、備註、發布日期、更新日期、區塊鏈交易序號。
  全頁 1.4 MB 是大頭照 base64 內嵌（offset ≈ 19.9 KB 起）；**所有欄位都在前 20 KB**，串流讀到 32 KB 即可斷線。
  Range 不支援（回 200 全頁）。
- **雜湊穩定性**：才文淇舊 API ut_date 2026-07-09（有 1 筆異動），但區塊鏈發行日 2026-06-04、頁面更新日期 2026-10-29；
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

## 待做（新 session 接手）

- migration：`moj_lawyers` 加 `page_hash text`、`page_checked_at timestamptz`、`page_hash_missing_at timestamptz`；
  新表 `moj_search_harvest(id, name, lic_no, office, guild_name, id_no, query, harvested_at, ingested_at)`。
- `scripts/moj_query_plan.py`：由 DB 產 322 條查詢字串（＋之後的增量：最新年度已知最大號之後的區段）。
- 瀏覽器助手 `public/tools/moj-harvest-bookmarklet.js`（或 userscript）＋ ingest 腳本把 harvest → page_hash。
- `scripts/moj_detail_sweep.py` ＋ workflow `moj-detail-sweep.yml`（每週五 UTC 00:00）。
- `moj_lawyer_scraper.py` 改讀 `/Home/GuildCounter` HTML（16 公會人數）→ `industry_stats`，重新啟用 `scrape-moj-lawyers`。
- 舊的 `moj-office-refresh`／`moj-licno-scan`／`alumni-refresh` 由新掃描取代後移除或改寫。
