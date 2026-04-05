import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

/**
 * 取得使用者 JWT 認證過的 Supabase client（受 RLS 限制）。
 * 用於查詢使用者自己的資料（notes、chat_sessions 等）。
 */
export function getUserClient(req: Request): SupabaseClient {
  const authHeader = req.headers.get('Authorization') ?? '';
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
}

/**
 * 取得 service role client（繞過 RLS）。
 * 用於跨使用者查詢 DB stats、或寫入需要 bypass RLS 的操作。
 */
export function getServiceClient(): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );
}

/**
 * 從 Authorization header 解析使用者 ID。
 */
export async function getUserId(req: Request): Promise<string | null> {
  const client = getUserClient(req);
  const { data: { user } } = await client.auth.getUser();
  return user?.id ?? null;
}
