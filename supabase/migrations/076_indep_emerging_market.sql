-- 獨董資料線納入興櫃（TPEx mopsfin_t187ap11_R 持股明細；興櫃無 t187ap30 簡歷資料集）
-- 覆核方式：交叉確認 — 同名（正規化）者若已在上市/上櫃有簡歷覆核確認席次
-- （office_matched / lawyer_confirmed），興櫃席次繼承該身分與 lic_no，
-- verify_status = 'cross_confirmed'；否則 'name_match_only'（僅名單、不上前端頁面）。
-- market 值新增 'emerging'。

-- 事務所 view 納入 cross_confirmed
create or replace view firm_indep_directorships as
select d.id, d.lic_no, d.person_name, d.company_code, d.company_name, d.market,
       d.title, d.appointed_date, d.verify_status,
       m.office_normalized
from lawyer_indep_directorships d
join moj_lawyers m on m.lic_no = d.lic_no
where d.verify_status in ('office_matched', 'lawyer_confirmed', 'cross_confirmed');
