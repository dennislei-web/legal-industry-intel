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

## 待驗證（需人工在瀏覽器查一次）

- `/Home/search` 回應中 `id_no` 的形態（流水號？雜湊？）。
- `/lawyer/{id_no}` 是否免 Session 可直接開啟；若可且 id_no 可推算，詳細頁本身是公開資源，可逐頁抓。
- `lic_no` 條件是否支援前綴／部分比對（決定半自動工具每碼能帶回多少筆）。
