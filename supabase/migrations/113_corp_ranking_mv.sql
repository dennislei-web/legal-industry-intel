-- 113: 企業客戶版圖 materialized view（112 的 2M 列 JOIN 直查會 statement timeout）
-- refresh_corp_ranking() 在每次 corp_party_stats.py upload 後手動呼叫（或年更時）。

create materialized view if not exists corp_firm_ranking_mv as
with pl as (
  select m.office as firm, p.company, sum(p.n) as n
  from corp_lawyer_pairs p
  join moj_lawyers m on m.name = p.lawyer and m.deregistered_at is null
  where m.office is not null and m.office <> ''
    and m.office not in ('律師未提供', '未提供')
  group by m.office, p.company
)
select firm,
       count(*)::bigint as n_companies,
       sum(n)::bigint as n_cases,
       (array_agg(company order by n desc))[1:8] as top_companies
from pl
group by firm;
create unique index if not exists idx_corp_firm_ranking_mv on corp_firm_ranking_mv (firm);

-- 律師個人版（modal 用）
create materialized view if not exists corp_lawyer_ranking_mv as
select lawyer,
       count(distinct company)::bigint as n_companies,
       sum(n)::bigint as n_cases,
       (array_agg(company order by n desc))[1:8] as top_companies
from corp_lawyer_pairs
group by lawyer;
create unique index if not exists idx_corp_lawyer_ranking_mv on corp_lawyer_ranking_mv (lawyer);

-- 無代理缺口榜（常訟低代理率公司）
create materialized view if not exists corp_unrepresented_mv as
select company, min(kind) as kind, sum(n)::bigint as n, sum(n_repr)::bigint as n_repr,
       round(100.0 * sum(n_repr) / nullif(sum(n), 0), 1) as repr_rate
from corp_litigants
group by company
having sum(n) >= 10;
create unique index if not exists idx_corp_unrep_mv on corp_unrepresented_mv (company);

create or replace function refresh_corp_ranking()
returns void language sql security definer as $$
  refresh materialized view corp_firm_ranking_mv;
  refresh materialized view corp_lawyer_ranking_mv;
  refresh materialized view corp_unrepresented_mv;
$$;

-- RPC 改讀 MV（維持原簽名，前端無感）
create or replace function corp_firm_ranking(p_limit int default 30)
returns table (firm text, n_companies bigint, n_cases bigint, top_companies text[])
language sql stable as $$
  select firm, n_companies, n_cases, top_companies
  from corp_firm_ranking_mv
  order by n_companies desc
  limit p_limit;
$$;

create or replace function corp_unrepresented_top(p_min_cases int default 10, p_limit int default 50)
returns table (company text, kind text, n bigint, n_repr bigint, repr_rate numeric)
language sql stable as $$
  select company, kind, n, n_repr, repr_rate
  from corp_unrepresented_mv
  where n >= p_min_cases
  order by (n - n_repr) desc
  limit p_limit;
$$;
