-- 290: firm_collab_groups — 全台同業協作集團（2026-11-20）
-- 產業深度報告「主案源八類全景」點同業協作時，列出全台符合條件的協作集團。
--
-- 定義（一對律師同時符合才算一條邊；視窗＝共同列名表最末月往前 60 個月）：
--   1. 共同列名（lawyer_pair_month_stats，同一方共同署名）60 個月合計 50 件以上、
--      跨 3 個曆年、近 12 個月仍有 10 件以上
--   2. 佔其中一方同期案量 30% 以上，且佔另一方 10% 以上（低於 10% 是單向依附，不算）
--   3. 兩人登記在不同事務所。以下視為同所排除：所名核心相同（分所、所名異寫）、
--      同址且所名核心互相包含或前兩字相同、alias 清單
--   4. 排除剛轉所：名冊異動紀錄（moj_lawyer_changes，2026-07 起）或首次抓取時的登記所
--      （moj_lawyers.raw_data.office）顯示一方的舊所就是對方的所，或兩人舊所相同
--   5. 排除同名律師（現役名冊同名 2 人以上，案量無法歸戶）、所名不明、登記在非事務所者
-- 邊的連通分量＝一個集團。
--   tier 確立＝集團內至少一對在視窗前 24 個月就有 5 件以上同列（合作 3 年以上）；
--        待確認＝全部配對都是後 36 個月才出現，可能是更早離所的尾案（轉所紀錄只從 2026-07 起，無法排除）
--   kind 同址＝全部配對名冊同一門牌；同電話＝不同門牌但同一支電話；部分同址；異址
-- 案量：nominal＝成員各自件數加總；dedup＝判決層去重（lawyer_group_month_stats，
--   同一份裁判書有集團內 2 人以上只算 1 件）；co＝集團內 2 人以上同列的裁判書件數。
-- 全量重建約 35 秒，超過 PostgREST 的 8 秒上限，只能用 supabase db query 或 Management API 跑：
--   select refresh_firm_collab_groups();
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.firm_collab_groups (
  gid          text PRIMARY KEY,           -- 連通分量內姓名排序最小者
  kind         text NOT NULL,
  tier         text NOT NULL,
  cities       text[],
  lawyer_n     int  NOT NULL,
  firm_n       int  NOT NULL,
  nominal      int  NOT NULL,
  dedup        int  NOT NULL,
  co           int  NOT NULL,
  dedup12      int  NOT NULL,
  dedup_p12    int  NOT NULL,
  co12         int  NOT NULL,
  co_p12       int  NOT NULL,
  first_ym     text,
  by_year      jsonb,
  members      jsonb,
  firms        jsonb,
  pairs        jsonb,
  window_start text,
  window_end   text,
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.firm_collab_groups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_read_firm_collab_groups" ON public.firm_collab_groups;
CREATE POLICY "admin_read_firm_collab_groups" ON public.firm_collab_groups
  FOR SELECT USING (public.is_intel_admin());
-- default privileges 會把整組權限給 authenticated；這張表只讀
REVOKE ALL ON public.firm_collab_groups FROM anon, public, authenticated;
GRANT SELECT ON public.firm_collab_groups TO authenticated;
GRANT ALL ON public.firm_collab_groups TO service_role;

CREATE OR REPLACE FUNCTION public.refresh_firm_collab_groups()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $fn$
DECLARE v_n int;
BEGIN
  DELETE FROM firm_collab_groups;
  INSERT INTO firm_collab_groups (gid, kind, tier, cities, lawyer_n, firm_n, nominal, dedup, co,
    dedup12, dedup_p12, co12, co_p12, first_ym, by_year, members, firms, pairs, window_start, window_end, refreshed_at)
with recursive prm as (
  select mx,
         to_char(to_date(mx,'YYYYMM') - interval '59 months','YYYYMM') w0,
         to_char(to_date(mx,'YYYYMM') - interval '36 months','YYYYMM') e1,   -- 視窗前 24 個月的最後一個月
         to_char(to_date(mx,'YYYYMM') - interval '23 months','YYYYMM') q0,
         to_char(to_date(mx,'YYYYMM') - interval '11 months','YYYYMM') r0
  from (select max(ym) mx from lawyer_pair_month_stats) t
),
alias(a, b) as (values ('群已聯合律師事務所','群己聯合律師事務所'), ('廣和(騰)國際專利法律事務所','廣騰國際法律事務所')),
mj0 as (
  select m.name,
         nullif(nullif(nullif(coalesce(m.office_normalized, m.office, ''), ''), '律師未顯示'), '律師未提供') off,
         regexp_replace(replace(translate(coalesce(m.address,''),'０１２３４５６７８９之','0123456789-'),'臺','台'),'\s','','g') addr,
         regexp_replace(coalesce(m.tel,''),'[^0-9]','','g') tel,
         nullif(nullif(m.raw_data->>'office','律師未提供'),'律師未顯示') raw_off, (m.deregistered_at is null) act
  from moj_lawyers m
),
mj as (
  select name, count(*) filter (where act) k_act,
         (array_agg(off order by act desc))[1] off,
         (array_agg(addr order by act desc))[1] addr,
         (array_agg(tel order by act desc))[1] tel,
         (array_agg(raw_off order by act desc))[1] raw_off
  from mj0 group by 1
),
roster as (
  select regexp_replace(off,'^(.+?(?:法律|律師)事務所).*$','\1') fk, count(*) n
  from mj0 where act and off is not null group by 1
),
pt as (
  select l.name_a, l.name_b, sum(l.cases) c, count(distinct left(l.ym,4)) yrs,
         coalesce(sum(l.cases) filter (where l.ym >= p.r0),0) c12,
         coalesce(sum(l.cases) filter (where l.ym >= p.q0 and l.ym < p.r0),0) p12,
         coalesce(sum(l.cases) filter (where l.ym <= p.e1),0) early,
         min(l.ym) f
  from lawyer_pair_month_stats l cross join prm p
  where l.ym >= p.w0
  group by 1,2
  having sum(l.cases) >= 50 and count(distinct left(l.ym,4)) >= 3
     and coalesce(sum(l.cases) filter (where l.ym >= (select r0 from prm)),0) >= 10
),
names as (select name_a name from pt union select name_b from pt),
tot as (
  select s.name, sum(s.case_count) n,
         coalesce(sum(s.case_count) filter (where s.yyyymm >= p.r0),0) n12
  from lawyer_month_stats s join names x on x.name = s.name cross join prm p
  where s.yyyymm >= p.w0 group by 1
),
ch as (
  select c.name, array_agg(distinct c.old_office) filter (where c.old_office is not null and c.old_office not in ('','律師未顯示','律師未提供')) olds
  from moj_lawyer_changes c join names x on x.name=c.name where c.change_type='firm_change' group by 1
),
j0 as (
  select p.name_a, p.name_b, p.c, p.c12, p.p12, p.early, p.f, ta.n na, tb.n nb, a.off oa, b.off ob, a.k_act kaa, b.k_act kba,
         a.tel tela, b.tel telb,
         substring(regexp_replace(a.addr,'^\d+','') from '^[^號]*號') ba, substring(regexp_replace(b.addr,'^\d+','') from '^[^號]*號') bb,
         array_remove(coalesce(ca.olds,'{}') || a.raw_off, null) olda, array_remove(coalesce(cb.olds,'{}') || b.raw_off, null) oldb
  from pt p join mj a on a.name=p.name_a join mj b on b.name=p.name_b
  left join tot ta on ta.name=p.name_a left join tot tb on tb.name=p.name_b
  left join ch ca on ca.name=p.name_a left join ch cb on cb.name=p.name_b
  where p.c >= 0.30 * least(coalesce(ta.n,1000000), coalesce(tb.n,1000000))
),
j as (
  select j0.*,
    regexp_replace(regexp_replace(oa,'^(.+?(?:法律|律師)事務所).*$','\1'),'(國際|聯合|法律|律師|侓師|法侓|地政士|事務所|/)','','g') ca,
    regexp_replace(regexp_replace(ob,'^(.+?(?:法律|律師)事務所).*$','\1'),'(國際|聯合|法律|律師|侓師|法侓|地政士|事務所|/)','','g') cb,
    (select array_agg(regexp_replace(regexp_replace(o,'^(.+?(?:法律|律師)事務所).*$','\1'),'(國際|聯合|法律|律師|侓師|法侓|地政士|事務所|/)','','g')) from unnest(olda) o) cola,
    (select array_agg(regexp_replace(regexp_replace(o,'^(.+?(?:法律|律師)事務所).*$','\1'),'(國際|聯合|法律|律師|侓師|法侓|地政士|事務所|/)','','g')) from unnest(oldb) o) colb
  from j0
),
f as (
  select j.*,
    case when oa is null or ob is null then '所名不明'
         when oa !~ '事務所' or ob !~ '事務所' then '非事務所'
         when ca = cb
           or (ba is not null and ba = bb and (position(ca in cb) > 0 or position(cb in ca) > 0 or left(ca,2) = left(cb,2)))
           or exists (select 1 from alias x where (x.a = oa and x.b = ob) or (x.a = ob and x.b = oa)) then '同所'
         when cb = any(coalesce(cola,'{}')) or ca = any(coalesce(colb,'{}')) or (coalesce(cola,'{}') && coalesce(colb,'{}')) then '剛轉所'
         when kaa <> 1 or kba <> 1 then '同名'
         when c < 0.10 * greatest(na, nb) then '單向'
         else '留' end verdict,
    case when ba is not null and ba = bb then '同址' when tela <> '' and tela = telb then '同電話' else '異址' end loc
  from j
),
e as (select * from f where verdict = '留'),
eb as (select name_a a, name_b b from e union all select name_b, name_a from e),
reach(n, m) as (
  select a, a from eb
  union
  select r.n, x.b from reach r join eb x on x.a = r.m
),
gm as (select n as name, min(m) gid from reach group by 1),
-- 判決層去重：同一份裁判書有集團內 2 人以上者只算 1 件
gl as (
  select t.gid, t.ym, sum((t.k - 1) * t.cases) dup, sum(t.cases) co
  from (
    select g.ym, g.lawyers, g.cases, m.gid, count(*) k
    from lawyer_group_month_stats g
    cross join lateral unnest(g.lawyers) ln(name)
    join gm m on m.name = ln.name
    where g.ym >= (select w0 from prm) and g.lawyers && (select array_agg(name) from gm)
    group by g.ym, g.lawyers, g.cases, m.gid
    having count(*) >= 2
  ) t group by 1,2
),
gmco as (  -- 每位成員與集團其他成員同列的裁判書件數
  select m.name, sum(g.cases) co
  from lawyer_group_month_stats g
  cross join lateral unnest(g.lawyers) ln(name)
  join gm m on m.name = ln.name
  where g.ym >= (select w0 from prm) and g.lawyers && (select array_agg(name) from gm)
    and (select count(*) from unnest(g.lawyers) x(name) join gm m2 on m2.name = x.name and m2.gid = m.gid) >= 2
  group by 1
),
nom as (
  select m.gid, s.yyyymm ym, sum(s.case_count) n
  from lawyer_month_stats s join gm m on m.name = s.name
  where s.yyyymm >= (select w0 from prm) group by 1,2
),
gy as (
  select n.gid, left(n.ym,4) y, sum(n.n) nominal, sum(n.n - coalesce(l.dup,0)) dedup, sum(coalesce(l.co,0)) co
  from nom n left join gl l on l.gid = n.gid and l.ym = n.ym group by 1,2
),
gt as (
  select n.gid, sum(n.n) nominal, sum(n.n - coalesce(l.dup,0)) dedup, sum(coalesce(l.co,0)) co,
         sum(n.n - coalesce(l.dup,0)) filter (where n.ym >= p.r0) dedup12,
         sum(n.n - coalesce(l.dup,0)) filter (where n.ym >= p.q0 and n.ym < p.r0) dedup_p12,
         sum(coalesce(l.co,0)) filter (where n.ym >= p.r0) co12,
         sum(coalesce(l.co,0)) filter (where n.ym >= p.q0 and n.ym < p.r0) co_p12
  from nom n cross join prm p left join gl l on l.gid = n.gid and l.ym = n.ym group by 1
),
mem as (
  select m.gid, m.name, j.off, regexp_replace(j.off,'^(.+?(?:法律|律師)事務所).*$','\1') fk,
         regexp_replace(j.addr,'^\d+','') addr, substring(regexp_replace(j.addr,'^\d+','') from '^[^號]*號') bldg, j.tel,
         t.n, t.n12, coalesce(c.co,0) co
  from gm m join mj j on j.name = m.name left join tot t on t.name = m.name left join gmco c on c.name = m.name
),
gmem as (
  select gid, count(*) lawyer_n, count(distinct fk) firm_n,
         count(distinct bldg) bldg_n, count(distinct nullif(tel,'')) tel_n, bool_or(bldg is null) bldg_null,
         jsonb_agg(jsonb_build_object('name', name, 'office', off, 'firm', fk, 'addr', addr, 'cases', n, 'cases12', n12, 'co', co) order by n desc) members,
         (array_agg(name order by n desc))[1] lead
  from mem group by 1
),
gfirm as (
  select gid, jsonb_agg(jsonb_build_object('firm', fk, 'roster', rn, 'members', k, 'city', city) order by k desc, rn desc) firms,
         array_agg(distinct city) cities
  from (
    select m.gid, m.fk, coalesce(r.n, 0) rn, count(*) k, (array_agg(substring(m.addr from '^(.{2}[市縣])')))[1] city
    from mem m left join roster r on r.fk = m.fk group by 1,2,3
  ) t group by 1
),
ge as (
  select m.gid, bool_or(e.early >= 5) established, bool_or(e.loc <> '異址') any_same, bool_and(e.loc <> '異址') all_same, bool_and(e.loc = '同址') all_addr,
         min(e.f) first_ym,
         jsonb_agg(jsonb_build_object('a', e.name_a, 'b', e.name_b, 'c', e.c, 'c12', e.c12, 'p12', e.p12,
                                      'pa', round(100.0*e.c/nullif(e.na,0)), 'pb', round(100.0*e.c/nullif(e.nb,0)), 'loc', e.loc, 'first', e.f) order by e.c desc) pairs
  from e join gm m on m.name = e.name_a group by 1
)
  select gm.gid,
         case when ge.all_addr then '同址' when ge.all_same then '同電話' when ge.any_same then '部分同址' else '異址' end,
         case when ge.established then '確立' else '待確認' end,
         gf.cities, gm.lawyer_n, gm.firm_n,
         gt.nominal, gt.dedup, gt.co, coalesce(gt.dedup12,0), coalesce(gt.dedup_p12,0), coalesce(gt.co12,0), coalesce(gt.co_p12,0),
         ge.first_ym,
         (select jsonb_object_agg(y.y, jsonb_build_object('dedup', y.dedup, 'co', y.co)) from gy y where y.gid = gm.gid),
         gm.members, gf.firms, ge.pairs,
         (select w0 from prm), (select mx from prm), now()
  from gmem gm join gfirm gf using (gid) join ge using (gid) join gt using (gid)
  ;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

ALTER FUNCTION public.refresh_firm_collab_groups() SET statement_timeout = '300s';
REVOKE EXECUTE ON FUNCTION public.refresh_firm_collab_groups() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_firm_collab_groups() TO service_role;

COMMIT;
