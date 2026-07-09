-- 上市櫃公司內部人（董監事/經理人）持股明細快照
-- 來源：TWSE OpenAPI t187ap11_L（上市）+ TPEx OpenAPI mopsfin_t187ap11_O（上櫃）
-- 抓取：scripts/listed_directors.py（每次全量覆蓋，只留最新月份快照）
-- 用途：與 moj_lawyers 名冊比對，找出掛任獨立董事/董監事的律師

create table if not exists listed_company_insiders (
  id bigint generated always as identity primary key,
  market text not null,                     -- listed(上市) / otc(上櫃)
  company_code text not null,
  company_name text not null,
  title text not null,                      -- 職稱原文，如 獨立董事本人 / 董事之法人代表人
  person_name text not null,                -- 姓名原文（可能含空白、英文名）
  person_name_norm text not null,           -- 去半形/全形空白，供名冊比對
  data_month text,                          -- 資料年月（民國 yyymm）
  current_shares bigint,                    -- 目前持股
  fetched_at timestamptz not null default now()
);

create index if not exists idx_lci_name_norm on listed_company_insiders(person_name_norm);
create index if not exists idx_lci_title on listed_company_insiders(title);
create index if not exists idx_lci_company on listed_company_insiders(company_code);

alter table listed_company_insiders enable row level security;

drop policy if exists lci_auth_read on listed_company_insiders;
create policy lci_auth_read on listed_company_insiders
  for select to authenticated using (true);

-- 獨立董事 × 律師名冊比對 view
-- same_name_lawyers = 名冊中同名律師數；=1 視為高信心命中、>=2 需人工覆核
create or replace view indep_director_lawyer_matches as
with roster as (
  select
    replace(replace(name, ' ', ''), '　', '') as name_norm,
    count(*) as same_name_lawyers,
    array_agg(distinct office_normalized) filter (where office_normalized is not null) as lawyer_offices,
    array_agg(distinct main_region) filter (where main_region is not null) as lawyer_regions
  from moj_lawyers
  group by 1
)
select
  i.market,
  i.company_code,
  i.company_name,
  i.title,
  i.person_name,
  i.data_month,
  r.same_name_lawyers,
  r.lawyer_offices,
  r.lawyer_regions
from listed_company_insiders i
join roster r on i.person_name_norm = r.name_norm
where i.title like '獨立董事%';
