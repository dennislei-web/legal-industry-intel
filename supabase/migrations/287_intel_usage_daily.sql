-- 287：帳號使用量（2026-11-19）
-- 帳號管理頁要看「誰有在用、用多少」。auth.sessions／last_sign_in_at 與喆律儀表板共用同一個 auth 池，分不出是哪一站，
-- 所以情報站自己記：前端累計「向資料庫發出的查詢次數」與「切到哪個分頁」，每分鐘（有新活動才送）回寫一次。
-- 一個帳號一天一列，量很小（17 個帳號 × 365 天）。
--   log_intel_usage(p_requests, p_tabs)  登入者寫自己的（只收有 user_profiles 的帳號；儀表板帳號呼叫會被靜默略過）
--   intel_usage_summary()                admin 讀每個帳號的彙總（帳號管理頁用）
-- 歷史回補（2026-11-19 一次性，不在本檔）：2026-08-21～11-19 上線前的請求數由 Supabase edge_logs 逐日回推寫入
--   （來源網域 dennislei-web.github.io、排除 OPTIONS、只算 /rest/v1 與 /functions/v1、依登入帳號分組；紀錄只留約三個月）。
--   回補的列 tab_views＝0、tabs 為空，「最常看」自 2026-11-19 起才有。
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.intel_usage_daily (
  user_id    uuid        NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  day        date        NOT NULL,                      -- 台北時間的日期
  requests   integer     NOT NULL DEFAULT 0,            -- 向資料庫發出的查詢次數（REST＋RPC＋Edge Function）
  tab_views  integer     NOT NULL DEFAULT 0,            -- 切換分頁次數
  tabs       jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- {分頁代號: 次數}
  first_seen timestamptz NOT NULL DEFAULT now(),
  last_seen  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, day)
);

ALTER TABLE public.intel_usage_daily ENABLE ROW LEVEL SECURITY;
-- 寫入只走 log_intel_usage（SECURITY DEFINER），不開 INSERT／UPDATE policy；讀取只給 admin
DROP POLICY IF EXISTS admin_read_intel_usage ON public.intel_usage_daily;
CREATE POLICY admin_read_intel_usage ON public.intel_usage_daily
  FOR SELECT TO authenticated USING (public.is_intel_admin());
REVOKE ALL ON public.intel_usage_daily FROM anon;

CREATE OR REPLACE FUNCTION public.log_intel_usage(p_requests integer, p_tabs jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_day   date := (now() AT TIME ZONE 'Asia/Taipei')::date;
  v_req   integer := least(greatest(coalesce(p_requests, 0), 0), 5000);   -- 單次回寫上限，防亂灌
  v_tabs  jsonb;
  v_views integer;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  -- 只記情報站的帳號（兩站共用 auth 池，儀表板帳號沒有 user_profiles）
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = v_uid AND is_active IS NOT FALSE) THEN RETURN; END IF;

  -- 分頁代號只收小寫英數與連字號、次數夾在 1～500、最多 60 個鍵
  SELECT coalesce(jsonb_object_agg(k, n), '{}'::jsonb), coalesce(sum(n), 0)::integer
    INTO v_tabs, v_views
  FROM (
    SELECT e.key AS k, least(greatest(e.value::integer, 1), 500) AS n
    FROM jsonb_each_text(CASE WHEN jsonb_typeof(p_tabs) = 'object' THEN p_tabs ELSE '{}'::jsonb END) e
    WHERE e.key ~ '^[a-z0-9-]{1,40}$' AND e.value ~ '^[0-9]{1,6}$'
    LIMIT 60
  ) t;

  IF v_req = 0 AND v_views = 0 THEN RETURN; END IF;

  INSERT INTO public.intel_usage_daily AS d (user_id, day, requests, tab_views, tabs)
  VALUES (v_uid, v_day, v_req, v_views, v_tabs)
  ON CONFLICT (user_id, day) DO UPDATE SET
    requests  = d.requests + EXCLUDED.requests,
    tab_views = d.tab_views + EXCLUDED.tab_views,
    tabs      = (
      SELECT coalesce(jsonb_object_agg(s.k, s.n), '{}'::jsonb)
      FROM (
        SELECT u.k, sum(u.n)::integer AS n
        FROM (
          SELECT key AS k, value::integer AS n FROM jsonb_each_text(d.tabs)
          UNION ALL
          SELECT key, value::integer FROM jsonb_each_text(EXCLUDED.tabs)
        ) u
        GROUP BY u.k
      ) s
    ),
    last_seen = now();
END;
$$;
REVOKE ALL ON FUNCTION public.log_intel_usage(integer, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.log_intel_usage(integer, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.intel_usage_summary()
RETURNS TABLE (
  user_id      uuid,
  last_seen    timestamptz,
  req_today    integer,
  req_7d       integer,
  req_30d      integer,
  req_total    bigint,
  days_30d     integer,
  views_30d    integer,
  top_tabs_30d jsonb,
  tracked_from date
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  IF NOT public.is_intel_admin() THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH tab30 AS (
    SELECT d.user_id, e.key AS tab, sum(e.value::integer)::integer AS n
    FROM public.intel_usage_daily d, jsonb_each_text(d.tabs) e
    WHERE d.day > v_today - 30
    GROUP BY d.user_id, e.key
  ),
  top3 AS (
    SELECT r.user_id, jsonb_agg(jsonb_build_object('tab', r.tab, 'n', r.n) ORDER BY r.n DESC, r.tab) AS top_tabs
    FROM (SELECT t.*, row_number() OVER (PARTITION BY t.user_id ORDER BY t.n DESC, t.tab) AS rn FROM tab30 t) r
    WHERE r.rn <= 3
    GROUP BY r.user_id
  )
  SELECT d.user_id,
         max(d.last_seen),
         coalesce(sum(d.requests) FILTER (WHERE d.day = v_today), 0)::integer,
         coalesce(sum(d.requests) FILTER (WHERE d.day > v_today - 7), 0)::integer,
         coalesce(sum(d.requests) FILTER (WHERE d.day > v_today - 30), 0)::integer,
         sum(d.requests)::bigint,
         (count(*) FILTER (WHERE d.day > v_today - 30))::integer,
         coalesce(sum(d.tab_views) FILTER (WHERE d.day > v_today - 30), 0)::integer,
         coalesce((SELECT t3.top_tabs FROM top3 t3 WHERE t3.user_id = d.user_id), '[]'::jsonb),
         min(d.day)
  FROM public.intel_usage_daily d
  GROUP BY d.user_id;
END;
$$;
REVOKE ALL ON FUNCTION public.intel_usage_summary() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.intel_usage_summary() TO authenticated;

COMMIT;
