-- 265：市場規模拆解——刑事業務線委任率改用 mig 264 實測值（2026-11-05）
-- 背景：mig 114 的 market_line_stats() 把 closed_case_cause_rep_stats 全部丟進 biz_line(ft, cause_group, cause_group)。
--   mig 264 新增的 file_type='刑事訴訟' 列 cause_group 是「供給面種類」（詐欺／毒品／洗錢防制法…41 組＋其他刑事），
--   biz_line() 刑事分支吃的是罪章／特別法名（詐欺罪／毒品危害防制條例…），兩套名字對不上：
--     * 「詐欺」落 ELSE → 其他刑事；「洗錢防制法」命中 → 詐欺與洗錢只剩洗錢；「毒品」regex 命中剛好對；其餘幾乎全落其他刑事
--     * rep_lawyer = n_total − n_none 在刑事列把公設／義務辯護也算進去（雷拍板口徑：主委任率只算選任律師含法扶）
--   → mig 264 上線後頁面已出現錯的「實測」badge（毒品 34%、詐欺與洗錢 26.7% 只算洗錢、其他刑事 15.4% 吞 17.5 萬人次）。
-- 作法：
--   1. biz_line_rep(ft, grp)：委任率專用對照。刑事訴訟 → 供給面種類對業務線（表如下，與 biz_line() 的罪章邏輯逐條對齊）；
--      民事／家事 → 沿用 biz_line(ft, grp, grp)。
--   2. market_line_stats()：rep_lawyer 一律 = n_both + n_p_only + n_d_only（民事＝任一造有律師含法扶；刑事＝選任律師自費＋法扶）；
--      另回 rep_public／rep_duty（刑事公設／義務人次，前端 tooltip 用；民事恆 0）。
--      前端 MS_REP_MIN=1000 的樣本門檻不變：刑事線與民／家事同一套規則，不足才退回 market_assumptions 可調假設並標「推估」。
--   3. market_assumptions：刑事 lit_rate_* 的 note 從「刑事無案由級實測，推估」改成「fallback（優先用實測）」。
--
-- 供給面種類 → 業務線對照（刑事訴訟；件數加權合併）：
--   交通刑事        ← 公共危險（不能安全駕駛／肇逃／放火失火；放火失火佔 <3%）、過失致死（§276 條號優先，同 biz_line）
--   詐欺與洗錢      ← 詐欺（含詐欺犯罪危害防制條例）、洗錢防制法、組織犯罪
--   毒品            ← 毒品
--   暴力與人身犯罪  ← 傷害、殺人、妨害自由、強盜搶奪、恐嚇取財擄人、妨害秩序、槍砲彈藥刀械、家庭暴力
--   性犯罪與跟騷    ← 妨害性自主、性剝削兒少、跟蹤騷擾
--   名譽個資與網路  ← 妨害名譽、妨害秘密、妨害電腦使用、個資
--   竊盜侵占與財產犯罪 ← 竊盜、侵占、贓物、毀棄損壞
--   白領與財經犯罪  ← 偽造文書、背信、重利、偽造有價證券、瀆職貪污、證券金融犯罪、稅捐
--   智慧財產        ← 智財刑事
--   其他刑事        ← 其他（妨害公務、賭博、妨害婚姻家庭、遺棄、偽證誣告、藥事、廢棄物、其他刑事…）
-- 已知近似（供給面種類粒度天生對不上 biz_line 的條號拆法）：
--   * §284 過失傷害在供給面落「傷害」→ 這裡算進暴力與人身犯罪的委任率；量體端 biz_line 把它算進交通刑事。
--     量化（2025）：§284 19,459 ＋ §277 11,156 人次，傷害種類 63% 其實是過失傷害，所以暴力與人身犯罪的分母（42,154）
--     比量體（22,695）大、交通刑事的分母（32,729）比量體（52,188）小；兩線委任率都偏低估。根治要在 ETL
--     （cause_map._CRIM_ARTICLE_OVERRIDES 加 '284' 獨立成「過失傷害」種類並回填），不在這支 migration 範圍。
--   * 妨害風化／性騷擾防治法／妨害性隱私在供給面落「其他刑事」（無對應關鍵字），量體端屬性犯罪與跟騷。
--   * 商業會計法／政府採購法／公司法／保險法同上落其他刑事或證券金融犯罪，量體端屬白領與財經犯罪。
--   這些都只影響「委任率」的分母組成，不影響年案件量。

CREATE OR REPLACE FUNCTION biz_line_rep(ft text, grp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN ft = '刑事訴訟' THEN CASE
    WHEN grp IN ('公共危險', '過失致死') THEN '交通刑事'
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

CREATE OR REPLACE FUNCTION market_line_stats()
RETURNS json LANGUAGE sql STABLE SECURITY DEFINER AS $$
WITH fy AS (
  SELECT max(y) AS y FROM (
    SELECT y FROM business_line_yearly GROUP BY y HAVING min(months) >= 12) t
), vol AS (
  SELECT b.line,
         COALESCE(sum(b.n) FILTER (WHERE b.file_type IN ('民事訴訟','家事訴訟')), 0)::bigint AS n_civ,
         COALESCE(sum(b.n) FILTER (WHERE b.file_type = '刑事訴訟'), 0)::bigint AS n_cri
  FROM business_line_yearly b, fy WHERE b.y = fy.y
  GROUP BY b.line
), repy AS (
  SELECT y FROM (
    SELECT left(yyyymm, 4) AS y, count(DISTINCT yyyymm) AS m
    FROM closed_case_cause_rep_stats GROUP BY 1) t
  WHERE m >= 12 ORDER BY y DESC LIMIT 1
), rep AS (
  SELECT biz_line_rep(r.file_type, r.cause_group) AS line,
         sum(r.n_total)::bigint AS rep_total,
         sum(r.n_both + r.n_p_only + r.n_d_only)::bigint AS rep_lawyer,   -- 民事：任一造有律師（含法扶）；刑事：選任律師（自費＋法扶）
         sum(r.n_public)::bigint AS rep_public,                            -- 刑事：公設辯護人（不計入委任率）
         sum(r.n_duty)::bigint AS rep_duty                                 -- 刑事：義務律師（不計入委任率）
  FROM closed_case_cause_rep_stats r, repy
  WHERE left(r.yyyymm, 4) = repy.y
    AND biz_line_rep(r.file_type, r.cause_group) IS NOT NULL
  GROUP BY 1
)
SELECT json_build_object(
  'year', (SELECT y FROM fy),
  'rep_year', (SELECT y FROM repy),
  'lines', COALESCE((SELECT json_agg(json_build_object(
      'line', v.line, 'n_civ', v.n_civ, 'n_cri', v.n_cri,
      'rep_total', r.rep_total, 'rep_lawyer', r.rep_lawyer,
      'rep_public', r.rep_public, 'rep_duty', r.rep_duty)
      ORDER BY v.n_civ + v.n_cri DESC)
    FROM vol v LEFT JOIN rep r ON r.line = v.line), '[]'::json));
$$;
ALTER FUNCTION market_line_stats() SET statement_timeout = '120s';
GRANT EXECUTE ON FUNCTION market_line_stats() TO anon, authenticated;

UPDATE market_assumptions
   SET note = 'fallback（優先用實測）'
 WHERE segment = 'lit' AND kind = 'rate' AND key LIKE 'lit_rate_%'
   AND note IN ('刑事無案由級實測，推估', '多法扶/指定辯護，推估');

NOTIFY pgrst, 'reload schema';
