-- 267：市場規模拆解——§284 過失傷害自「傷害」拆出成供給面種類，委任率對照歸交通刑事（2026-11-05）
-- 背景：mig 265 的已知近似——§284 過失傷害（多為車禍）在供給面種類落「傷害」，biz_line_rep() 把整組「傷害」
--   對到暴力與人身犯罪；量體端 biz_line()（mig 095）卻是條號優先，把 §284 算進交通刑事。
--   量化（2025）：§284 19,459 人次 vs 普通傷害 §277 11,156，「傷害」種類 63% 其實是過失傷害
--   → 暴力與人身犯罪的委任率分母 42,154 比量體 22,695 大、交通刑事的分母 32,729 比量體 52,188 小，兩線委任率都低估。
-- 作法（規則單一真實源在 Python，本 migration 只補業務線對照）：
--   1. scripts/cause_map.py：_CRIM_ARTICLE_OVERRIDES 加 '284': '過失傷害'（條號級覆寫，與 §276 過失致死／§344 重利同機制）；
--      CRIME_TITLE_RULES 在「傷害」之前插入 ('過失傷害', ('過失傷害',))（_match 先中先贏），裁判書標題含「過失傷害」者
--      改判到新種類，供給面（lawyer_cause_stats）與需求面（closed_case_cause_rep_stats）同一把尺。種類 41 組 → 42 組。
--   2. python closed_case_stats.py rerun 202101 202608：68 個月整月重跑（upsert 冪等）→ closed_case_cause_rep_stats 刑事列
--      多「過失傷害」種類、「傷害」列只剩 §277／§278 等；crime_supply_map 的 刑法§284 → supply_group 過失傷害
--      （cause_group_yearly_crim() 市場欄跟著變）。
--   3. python judgment_stats.py causemap-resync：cause_group_map 刑事「…過失傷害…」鍵改判過失傷害（「家庭暴力…之過失傷害」
--      仍歸家庭暴力，規則順序不變）＋ refresh_lawyer_cause_stats 鏈 → 案由供需刑事頁多一列「過失傷害」。
--      cause_group_map.sub_group（mig 259 generated column）沒有「過失傷害」分支 → 該種類子類為空，傷害種類的
--      「過失傷害」子類只剩「過失致重傷」等殘件；要細分再開 migration 重建 generated column。
--   4. 本 migration：biz_line_rep() 刑事分支把 '過失傷害' 對到交通刑事，與 biz_line() 的 §284 條號邏輯一致。
-- 預期（2025）：交通刑事 rep_total ≈ 公共危險 31,415 ＋ 過失致死 1,314 ＋ 過失傷害 ≈19,459 ≈ 量體 52,188；
--   暴力與人身犯罪 rep_total ≈ 42,154 − 19,459 ≈ 量體 22,695。實際數字與兩線委任率前後差異見 commit 訊息。
-- mig 265 其餘已知近似（妨害風化／性騷擾防治法／妨害性隱私落其他刑事而非性犯罪與跟騷；商業會計法／政府採購法／
--   公司法／保險法落其他刑事或證券金融犯罪）不在本次範圍，仍只影響委任率分母、不影響年案件量。

CREATE OR REPLACE FUNCTION biz_line_rep(ft text, grp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN ft = '刑事訴訟' THEN CASE
    WHEN grp IN ('公共危險', '過失致死', '過失傷害') THEN '交通刑事'   -- 過失傷害：mig 267 自「傷害」拆出（§284）
    WHEN grp IN ('詐欺', '洗錢防制法', '組織犯罪') THEN '詐欺與洗錢'
    WHEN grp = '毒品' THEN '毒品'
    WHEN grp IN ('傷害', '殺人', '妨害自由', '強盜搶奪', '恐嚇取財擄人', '妨害秩序', '槍砲彈藥刀械', '家庭暴力') THEN '暴力與人身犯罪'
    WHEN grp IN ('妨害性自主', '性剝削兒少', '跟蹤騷擾') THEN '性犯罪與跟騷'
    WHEN grp IN ('妨害名譽', '妨害秘密', '妨害電腦使用', '個資') THEN '名譽個資與網路'
    WHEN grp IN ('竊盜', '侵占', '贓物', '毀棄損壞') THEN '竊盜侵占與財產犯罪'
    WHEN grp IN ('偽造文書', '背信', '重利', '偽造有價證券', '瀆職貪污', '證券金融犯罪', '稅捐') THEN '白領與財經犯罪'
    WHEN grp = '智財刑事' THEN '智慧財產'
    ELSE '其他刑事'
  END
  ELSE biz_line(ft, grp, grp)
END $$;

NOTIFY pgrst, 'reload schema';
