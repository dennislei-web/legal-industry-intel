# 事務所 AI 分析規格 v3（source of truth）

> 2026-11-03 v3 拍板：型態改案源×業務雙軸、案源判讀四級證據、營收人均產能門檻與消債換算、民間機構批量 carve-out、具名負面紀錄不入正文。

本資料夾是事務所 `ai_analysis` 評估方式的**唯一真實源**（2026-08-29 拍板）。
`/legal-research` skill（`.claude/commands/legal-research.md`，local-only 不進 git）的產出格式一律以此處為準。

| 檔案 | 內容 |
|---|---|
| `FORMAT.md` | ai_analysis 產出格式 v3：七節＋30 秒速讀（含案源判讀）、雙軸標籤、可讀性鐵則、6,000 字硬上限 |
| `REVENUE_RULES.md` | 訴訟側營收推估：v3 委任口徑件數＋人均 40 件門檻＋消債換算＋民間批量 carve-out，其餘沿用 v2（capped 標的加費、審級、身分係數、掛名排除） |
| `MARKET.md` | 行情假設表（78 項，案由行情 low/high 區間）——第六節一律用此表，不得自行假設價格 |
| `GUIDE_BIG.md` | 大所（11 人以上）批次重跑 agent 指南：dossier 讀法、front-matter、upload 流程 |
| `GUIDE.md` | 中小所批次 agent 指南 |

## 修改規則

- 評估方式有變更（公式、格式、係數）→ **先改這裡**，再同步 skill 的摘要段。
- 批次跑批用的工作資料夾（如 `scripts/_batch408/v2/`）內的規格副本是**跑批當下的快照**，
  開新批次前從本資料夾複製過去，勿反向同步。

## 資料依賴

- `lawyer_case_fee_stats`（mig 172/173）：`surcharge_capped_sum`＝Σ max(0, min(標的金額, 1億) − 200萬)，
  加費公式一律用 capped 欄；`surcharge_base_sum`（未 cap）僅供離群值點名。
- dossier 產生：`scripts/firm_dossier.py`＋批次夾內 `slim_dossier.py`／`gen_dossiers.py`。
