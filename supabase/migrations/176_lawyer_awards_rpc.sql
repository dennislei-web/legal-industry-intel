-- 律師 modal 評鑑徽章（mig 176）：按中文名撈 firm_awards.ranked_lawyers 內的上榜紀錄
-- 只回「已歸戶中文名」的條目（lw->>'name'）；英文原名條目不對個人歸戶（防同名誤掛）

CREATE OR REPLACE FUNCTION lawyer_awards(p_name text)
RETURNS TABLE(source text, year int, practice_area text, band text,
              firm_name text, firm_name_en text, lawyer_band text)
LANGUAGE sql STABLE AS $$
  SELECT fa.source, fa.year, fa.practice_area, fa.band,
         fa.firm_name, fa.firm_name_en, lw->>'band'
  FROM firm_awards fa, jsonb_array_elements(fa.ranked_lawyers) lw
  WHERE lw->>'name' = p_name
  ORDER BY fa.year DESC, fa.source, fa.practice_area;
$$;
