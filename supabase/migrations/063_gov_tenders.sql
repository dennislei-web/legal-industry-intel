-- 政府標案：法律服務類決標資料
-- 來源：pcc-api.openfun.app（g0v 政府電子採購網鏡像），scripts/gov_tenders.py 抓取
-- 口徑：只收「有決標結果」的案件（無法決標公告不入表）；10 萬以下小額採購來源本身不公告

create table if not exists gov_tenders (
  tender_key text primary key,              -- unit_id|job_number
  unit_id text not null,
  unit_name text,
  job_number text not null,
  title text,
  category text,                            -- 標的分類，如 <勞務類>861法律服務
  procurement_method text,                  -- 招標方式
  award_method text,                        -- 決標方式
  budget_amount bigint,                     -- 預算金額（不公開者為 null）
  award_date date,                          -- 決標日期（非公告/彙送日）
  award_year int,                           -- 西元年，由 award_date 取
  total_amount bigint,                      -- 總決標金額（不公開者為 null）
  award_type text,                          -- 決標公告 / 定期彙送 / 更正公告等
  source_filename text,
  source_date int,                          -- 來源公告日 yyyymmdd（彙送日可能晚於決標日）
  fetched_at timestamptz not null default now()
);

create table if not exists gov_tender_firms (
  tender_key text not null references gov_tenders(tender_key) on delete cascade,
  firm_seq int not null,                    -- 投標廠商序號
  firm_uid text,                            -- 廠商代碼（統編）
  firm_name text not null,
  is_winner boolean not null default false,
  award_amount bigint,                      -- 該廠商決標金額
  primary key (tender_key, firm_seq)
);

create index if not exists idx_gov_tenders_year on gov_tenders(award_year);
create index if not exists idx_gov_tenders_unit on gov_tenders(unit_name);
create index if not exists idx_gov_tender_firms_name on gov_tender_firms(firm_name);
create index if not exists idx_gov_tender_firms_uid on gov_tender_firms(firm_uid);

alter table gov_tenders enable row level security;
alter table gov_tender_firms enable row level security;

drop policy if exists gov_tenders_auth_read on gov_tenders;
create policy gov_tenders_auth_read on gov_tenders
  for select to authenticated using (true);

drop policy if exists gov_tender_firms_auth_read on gov_tender_firms;
create policy gov_tender_firms_auth_read on gov_tender_firms
  for select to authenticated using (true);
