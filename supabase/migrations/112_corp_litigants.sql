-- 112: 企業當事人歸戶（裁判書民事/行政 公司當事人 × 代理律師）
-- 來源：scripts/corp_party_stats.py（月包解析，period 可為 YYYYMM 或年聚合 YYYY）
-- 回答「哪些事務所手上有最多企業客戶」的訴訟端 proxy；
-- n_repr < n 的缺口 = 企業無律師代理出庭 → 法顧/委任滲透率缺口訊號。

create table if not exists corp_litigants (
  period text not null,                 -- 'YYYYMM' 或年聚合 'YYYY'
  company text not null,               -- 正規化名稱（去空白/括號註記，臺→台）
  kind text not null default 'corp',   -- corp=營利企業 / org=非營利法人
  n int not null,                      -- 該期案件數（民事+行政，同案去重）
  n_repr int not null default 0,       -- 其中該公司一方有律師代理的案件數
  primary key (period, company)
);
create index if not exists idx_corp_litigants_company on corp_litigants (company);

create table if not exists corp_lawyer_pairs (
  period text not null,
  company text not null,
  lawyer text not null,
  camp text not null default 'X',      -- P=攻方 D=守方（公司所在造）
  n int not null,
  primary key (period, company, lawyer, camp)
);
create index if not exists idx_corp_pairs_lawyer on corp_lawyer_pairs (lawyer);
create index if not exists idx_corp_pairs_company on corp_lawyer_pairs (company);

alter table corp_litigants enable row level security;
alter table corp_lawyer_pairs enable row level security;
drop policy if exists "corp_litigants_read" on corp_litigants;
create policy "corp_litigants_read" on corp_litigants for select to authenticated using (true);
drop policy if exists "corp_lawyer_pairs_read" on corp_lawyer_pairs;
create policy "corp_lawyer_pairs_read" on corp_lawyer_pairs for select to authenticated using (true);

-- 事務所層排行：pair → 現職事務所歸戶（同名律師混同為已知限制，前端標注）
create or replace function corp_firm_ranking(p_limit int default 30)
returns table (firm text, n_companies bigint, n_cases bigint, top_companies text[])
language sql stable as $$
  with pl as (
    select m.office as firm, p.company, sum(p.n) as n
    from corp_lawyer_pairs p
    join moj_lawyers m on m.name = p.lawyer and coalesce(m.deregistered_at::text,'') = ''
    where m.office is not null and m.office <> ''
    group by m.office, p.company
  )
  select firm,
         count(distinct company) as n_companies,
         sum(n)::bigint as n_cases,
         (array_agg(company order by n desc))[1:8] as top_companies
  from pl
  group by firm
  order by n_companies desc
  limit p_limit;
$$;

-- 無代理缺口榜：常訟但低代理率的公司（business development 訊號）
create or replace function corp_unrepresented_top(p_min_cases int default 10, p_limit int default 50)
returns table (company text, kind text, n bigint, n_repr bigint, repr_rate numeric)
language sql stable as $$
  select company, min(kind) as kind, sum(n)::bigint as n, sum(n_repr)::bigint as n_repr,
         round(100.0 * sum(n_repr) / nullif(sum(n),0), 1) as repr_rate
  from corp_litigants
  group by company
  having sum(n) >= p_min_cases
  order by (sum(n) - sum(n_repr)) desc
  limit p_limit;
$$;
