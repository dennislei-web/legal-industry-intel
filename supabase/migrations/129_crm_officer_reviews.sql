-- 127: 喆律 CRM 法官/檢察官內部紀錄（交手案件 + 內部評論）
-- 來源：crm.lawyer 法官/檢察官搜尋頁（crm_officer_crawl.py 爬取，GitHub Actions 跑）
-- 機密性：評論含內部評價與當事人資訊，RLS 綁定單一 uid（僅雷皓明帳號可讀），
--         絕不進任何 public view / MV / 前端硬編碼（比照 ip_watchlist admin-only 模式再收窄）。

create table if not exists crm_officer_reviews (
  id bigint generated always as identity primary key,
  name text not null,
  officer_type text not null,          -- 'Judge' | 'Prosecutor'（CRM type 參數）
  agencies jsonb not null default '[]'::jsonb,  -- [{agency, sub_agency, division, note}] 該人出現過的機關列
  case_count int not null default 0,            -- distinct 案件編號數（= 與喆律交手案件數）
  cases jsonb not null default '[]'::jsonb,     -- [{case_no, branch, cause}] 案件明細
  comments jsonb not null default '[]'::jsonb,  -- [{agency, division, officer_type, comment, created_at}] 內部評論
  crawled_at timestamptz not null default now(),
  unique (name, officer_type)
);

create index if not exists idx_crm_officer_reviews_name on crm_officer_reviews (name);

alter table crm_officer_reviews enable row level security;

-- 僅限指定帳號（uid 綁定，不用 email 以免公開 repo 洩漏個資）；service_role 繞過 RLS 供爬蟲寫入
drop policy if exists crm_officer_reviews_owner_select on crm_officer_reviews;
create policy crm_officer_reviews_owner_select on crm_officer_reviews
  for select using (auth.uid() = 'e654c31f-a101-4fca-9dfb-97ddbb012cbe'::uuid);

-- 爬蟲狀態列（前端「爬蟲更新」按鈕輪詢用；一列 singleton）
create table if not exists crm_crawl_status (
  id int primary key default 1 check (id = 1),
  status text not null default 'idle',   -- idle | running | done | error
  detail text,
  started_at timestamptz,
  finished_at timestamptz
);
insert into crm_crawl_status (id) values (1) on conflict do nothing;

alter table crm_crawl_status enable row level security;
drop policy if exists crm_crawl_status_owner_select on crm_crawl_status;
create policy crm_crawl_status_owner_select on crm_crawl_status
  for select using (auth.uid() = 'e654c31f-a101-4fca-9dfb-97ddbb012cbe'::uuid);
