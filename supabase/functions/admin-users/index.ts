import { corsHeaders, handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { getUserClient, getServiceClient, getUserId } from '../_shared/supabase.ts';

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  // 驗證使用者身份
  const userId = await getUserId(req);
  if (!userId) return errorResponse('Unauthorized', 401);

  // 驗證是否為 admin
  const userClient = getUserClient(req);
  const { data: profile } = await userClient
    .from('user_profiles')
    .select('role')
    .eq('id', userId)
    .single();

  if (!profile || profile.role !== 'admin') {
    return errorResponse('Permission denied: admin only', 403);
  }

  const url = new URL(req.url);
  const action = url.searchParams.get('action');

  const serviceClient = getServiceClient();

  try {
    // ========== 列出所有使用者 ==========
    if (action === 'list') {
      const { data, error } = await userClient
        .from('user_profiles')
        .select('*')
        .order('created_at', { ascending: false });

      if (error) return errorResponse(error.message);
      return jsonResponse({ users: data });
    }

    // ========== 新增使用者 ==========
    if (action === 'create' && req.method === 'POST') {
      const body = await req.json();
      const { email, password, display_name, role } = body;

      if (!email || !password) {
        return errorResponse('email and password are required');
      }

      // 用 service_role 建立 auth user
      const { data: authData, error: authError } = await serviceClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });

      if (authError) return errorResponse(authError.message);

      // 建立 user_profile
      const { error: profileError } = await serviceClient
        .from('user_profiles')
        .insert({
          id: authData.user.id,
          email,
          display_name: display_name || email.split('@')[0],
          role: role || 'user',
        });

      if (profileError) {
        // rollback: 刪除剛建立的 auth user
        await serviceClient.auth.admin.deleteUser(authData.user.id);
        return errorResponse('建立 profile 失敗：' + profileError.message);
      }

      return jsonResponse({ success: true, user_id: authData.user.id });
    }

    // ========== 更新使用者角色/狀態 ==========
    if (action === 'update' && req.method === 'POST') {
      const body = await req.json();
      const { user_id, role: newRole, is_active, display_name } = body;

      if (!user_id) return errorResponse('user_id is required');

      const updates: Record<string, unknown> = {};
      if (newRole !== undefined) updates.role = newRole;
      if (is_active !== undefined) updates.is_active = is_active;
      if (display_name !== undefined) updates.display_name = display_name;

      const { error } = await serviceClient
        .from('user_profiles')
        .update(updates)
        .eq('id', user_id);

      if (error) return errorResponse(error.message);
      return jsonResponse({ success: true });
    }

    // ========== 重設密碼 ==========
    if (action === 'reset_password' && req.method === 'POST') {
      const body = await req.json();
      const { user_id, new_password } = body;

      if (!user_id || !new_password) {
        return errorResponse('user_id and new_password are required');
      }

      const { error } = await serviceClient.auth.admin.updateUserById(user_id, {
        password: new_password,
      });

      if (error) return errorResponse(error.message);
      return jsonResponse({ success: true });
    }

    // ========== 刪除使用者 ==========
    if (action === 'delete' && req.method === 'POST') {
      const body = await req.json();
      const { user_id } = body;

      if (!user_id) return errorResponse('user_id is required');
      if (user_id === userId) return errorResponse('不能刪除自己的帳號');

      // 刪除 profile (cascade 會處理)
      const { error: profileErr } = await serviceClient
        .from('user_profiles')
        .delete()
        .eq('id', user_id);

      if (profileErr) return errorResponse(profileErr.message);

      // 刪除 auth user
      const { error: authErr } = await serviceClient.auth.admin.deleteUser(user_id);
      if (authErr) return errorResponse(authErr.message);

      return jsonResponse({ success: true });
    }

    // ========== 批次刪除沒有 profile 的 auth users ==========
    if (action === 'purge_unlinked' && req.method === 'POST') {
      // 列出所有 auth users
      const { data: authUsers, error: listErr } = await serviceClient.auth.admin.listUsers({ perPage: 1000 });
      if (listErr) return errorResponse(listErr.message);

      // 取得所有有 profile 的 user ids
      const { data: profiles } = await serviceClient.from('user_profiles').select('id');
      const profileIds = new Set((profiles || []).map((p: { id: string }) => p.id));

      // 刪除沒有 profile 的 users
      const deleted: string[] = [];
      const errors: string[] = [];
      for (const u of authUsers.users) {
        if (!profileIds.has(u.id)) {
          const { error } = await serviceClient.auth.admin.deleteUser(u.id);
          if (error) errors.push(`${u.email}: ${error.message}`);
          else deleted.push(u.email || u.id);
        }
      }

      return jsonResponse({ success: true, deleted, errors, kept: profileIds.size });
    }

    return errorResponse('Unknown action: ' + action);
  } catch (e) {
    return errorResponse(e.message || 'Internal error', 500);
  }
});
