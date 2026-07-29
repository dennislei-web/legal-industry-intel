-- 116: 企業客戶版圖搜尋 RPC（2026-07-29）
-- 事務所→全部法人客戶清單／法人→最常合作事務所。
-- 口徑同 corp_firm_ranking_mv：律師以現職事務所（moj_lawyers.office）歸戶，同名混同為已知限制。

create or replace function corp_firm_clients(p_firm text)
returns table (company text, n bigint, n_lawyers bigint, n_p bigint, n_d bigint, y_min text, y_max text)
language sql stable as $$
  select p.company,
         sum(p.n)::bigint as n,
         count(distinct p.lawyer)::bigint as n_lawyers,
         coalesce(sum(p.n) filter (where p.camp = 'P'), 0)::bigint as n_p,
         coalesce(sum(p.n) filter (where p.camp = 'D'), 0)::bigint as n_d,
         min(p.period) as y_min,
         max(p.period) as y_max
  from corp_lawyer_pairs p
  join moj_lawyers m on m.name = p.lawyer and m.deregistered_at is null
  where m.office = p_firm
  group by p.company
  order by n desc;
$$;

create or replace function corp_company_firms(p_company text)
returns table (firm text, n bigint, n_lawyers bigint, n_p bigint, n_d bigint, y_min text, y_max text)
language sql stable as $$
  select m.office as firm,
         sum(p.n)::bigint as n,
         count(distinct p.lawyer)::bigint as n_lawyers,
         coalesce(sum(p.n) filter (where p.camp = 'P'), 0)::bigint as n_p,
         coalesce(sum(p.n) filter (where p.camp = 'D'), 0)::bigint as n_d,
         min(p.period) as y_min,
         max(p.period) as y_max
  from corp_lawyer_pairs p
  join moj_lawyers m on m.name = p.lawyer and m.deregistered_at is null
  where p.company = p_company
    and m.office is not null and m.office <> ''
    and m.office not in ('律師未提供', '未提供')
  group by m.office
  order by n desc;
$$;
