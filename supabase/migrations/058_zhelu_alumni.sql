-- 喆律校友會：離職律師名單與現職比對（來源：人事資料管理 xlsx + moj_lawyers + lawsnote）
create table if not exists zhelu_alumni (
  id bigint generated always as identity primary key,
  name text not null,
  last_title text,
  zhelu_office text,
  zhelu_dept text,
  join_date date,
  leave_date date,
  category text not null, -- cohort=轉合署 / own_firm=自行開業 / law_firm=他所執業 / inhouse=企業機構 / no_office=執業中未公開 / not_registered=未登錄 / recent=甫離職登錄未異動
  current_firm text,
  current_region text,
  practice_start date,
  lawsnote_cases int,
  lawsnote_expertise jsonb,
  lawsnote_url text,
  note text,
  updated_at timestamptz not null default now()
);

alter table zhelu_alumni enable row level security;

drop policy if exists zhelu_alumni_auth_read on zhelu_alumni;
create policy zhelu_alumni_auth_read on zhelu_alumni
  for select to authenticated using (true);
