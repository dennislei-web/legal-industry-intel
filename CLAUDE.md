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
- `moj_firm_stats_cache` — 事務所統計快取表（materialized），由 `refresh_firm_stats_cache` RPC 更新
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
- `moj_firm_stats_cache` 需手動 refresh（爬蟲 workflow 最後會呼叫）
- 前端登入後若無資料可能是 RLS 設定問題（需 auth.uid() IS NOT NULL）

## Claude Code 相關

- Skill `/legal-research` — 法律產業深度研究助手（查 DB、分析事務所、討論產業趨勢）
- `ANTHROPIC_API_KEY` 僅用於 `generate-insights.yml` workflow（AI 市場分析，已改為前端 Edge Function 觸發）
