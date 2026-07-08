// 前端「校友單人重爬」按鈕 → 驗證 admin → dispatch alumni-refresh.yml workflow
// body: { name?: string }  有 name = 只重爬該位校友；無 = 全量 52 位
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { getUserClient, getUserId } from '../_shared/supabase.ts';

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  // 驗證使用者身份 + admin 角色
  const userId = await getUserId(req);
  if (!userId) return errorResponse('Unauthorized', 401);

  const userClient = getUserClient(req);
  const { data: profile } = await userClient
    .from('user_profiles')
    .select('role')
    .eq('id', userId)
    .single();
  if (!profile || profile.role !== 'admin') {
    return errorResponse('Permission denied: admin only', 403);
  }

  try {
    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
    const name = (body.name || '').trim();

    const repo = Deno.env.get('GITHUB_REPO');
    const token = Deno.env.get('GITHUB_TOKEN');
    if (!repo || !token) return errorResponse('GITHUB_REPO / GITHUB_TOKEN secret 未設定', 500);

    const res = await fetch(
      `https://api.github.com/repos/${repo}/actions/workflows/alumni-refresh.yml/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
          'User-Agent': 'legal-industry-intel-edge',
        },
        body: JSON.stringify({ ref: 'main', inputs: name ? { only_name: name } : {} }),
      },
    );

    if (res.status !== 204) {
      const detail = await res.text();
      return errorResponse(`GitHub dispatch 失敗 (${res.status}): ${detail.slice(0, 200)}`, 502);
    }
    return jsonResponse({ success: true, name: name || null });
  } catch (e) {
    return errorResponse(e.message || 'Internal error', 500);
  }
});
