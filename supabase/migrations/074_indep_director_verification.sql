-- 獨立董監事簡歷（MOPS t187ap30 獨立董監事兼任情形彙總表）+ 律師身分覆核結果
-- 來源：TWSE t187ap30_L / TPEx mopsfin_t187ap30_O（含主要現職/主要經歷，獨董揭露義務全數有填）
-- 抓取與覆核：scripts/listed_directors.py（verify 指令）

-- 獨董簡歷快照（僅職稱含「獨立」列，依 公司+姓名 去重）
create table if not exists indep_director_profiles (
  company_code text not null,
  company_name text,
  person_name text not null,
  person_name_norm text not null,
  market text not null,                     -- listed / otc
  title text not null,                      -- 獨立董事 / 獨立監察人
  appointed_date text,                      -- 就任日期（民國 yyymmdd）
  current_position text,                    -- 主要現職
  experience text,                          -- 主要經歷
  fetched_at timestamptz not null default now(),
  primary key (company_code, person_name)
);

create index if not exists idx_idp_name_norm on indep_director_profiles(person_name_norm);

alter table indep_director_profiles enable row level security;
drop policy if exists idp_auth_read on indep_director_profiles;
create policy idp_auth_read on indep_director_profiles
  for select to authenticated using (true);

-- 律師×獨董席次覆核結果（Python 端比對後 materialize，前端直接讀這張）
-- verify_status:
--   office_matched  簡歷提到名冊登記的事務所 → 釘到特定律師(lic_no)
--   lawyer_confirmed 簡歷含「律師」字樣（同名唯一時 lic_no 也會帶入）
--   legal_related   簡歷含 法律/法學/法務 但無「律師」
--   no_signal       簡歷無法律相關字樣（很可能是同名非律師）
create table if not exists lawyer_indep_directorships (
  id bigint generated always as identity primary key,
  lic_no text,                              -- 釘到的律師證號（可 null=無法確定是哪位）
  person_name text not null,
  company_code text not null,
  company_name text not null,
  market text not null,
  title text not null,
  appointed_date text,
  same_name_lawyers int not null,
  verify_status text not null,
  matched_office text,                      -- office_matched 時：命中的事務所名
  current_position text,
  experience text,
  fetched_at timestamptz not null default now()
);

create index if not exists idx_lid_lic_no on lawyer_indep_directorships(lic_no);
create index if not exists idx_lid_name on lawyer_indep_directorships(person_name);

-- 事務所頁用：已確認律師的獨董席次 + 名冊事務所（供 office_normalized 前綴查詢）
create or replace view firm_indep_directorships as
select d.id, d.lic_no, d.person_name, d.company_code, d.company_name, d.market,
       d.title, d.appointed_date, d.verify_status,
       m.office_normalized
from lawyer_indep_directorships d
join moj_lawyers m on m.lic_no = d.lic_no
where d.verify_status in ('office_matched', 'lawyer_confirmed');

alter table lawyer_indep_directorships enable row level security;
drop policy if exists lid_auth_read on lawyer_indep_directorships;
create policy lid_auth_read on lawyer_indep_directorships
  for select to authenticated using (true);
