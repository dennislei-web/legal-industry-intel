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
- `firm_websites` — 爬蟲找到的官網
- `judges` / `courts` / `judges_combined` — 法官/法院
- `lawyer_members` — 律師公會會員（按地區公會）
- `user_profiles` — 使用者角色 (admin/user)

## 爬蟲模式（moj-deep-backfill.yml）

- `licno-scan` — 證號遍歷（全年份）
- `licno-108-115` / `licno-recent` — 限定年份
- `deep-all` / `deep-targeted` / `deep-surnames` / `deep-triple` — 不同策略補掃
- `full` — 全量掃描

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

## Windows console encoding 注意

- Python print 中文到 stdout 會顯示亂碼（CP950），**不代表 DB 寫入失敗**
- 驗證時用 `PYTHONIOENCODING=utf-8 python -c ...` 才能看到正確中文
- 或用 HTTP status code（200/204）判斷成功即可，不要依賴 console 輸出

## Claude Code 相關

- Skill `/legal-research` — 法律產業深度研究助手（查 DB、分析事務所、討論產業趨勢）
- `ANTHROPIC_API_KEY` 僅用於 `generate-insights.yml` workflow（AI 市場分析，已改為前端 Edge Function 觸發）
