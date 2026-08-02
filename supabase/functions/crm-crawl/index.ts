// 前端「CRM 內部紀錄爬蟲更新」按鈕 → 驗證擁有者 uid → dispatch crm-officer-crawl.yml workflow
// 資料機密（喆律內部評論），僅限單一 uid 觸發（比 admin 更窄，與 crm_officer_reviews RLS 一致）
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { getUserId } from '../_shared/supabase.ts';

const OWNER_UID = 'e654c31f-a101-4fca-9dfb-97ddbb012cbe';

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const userId = await getUserId(req);
  if (!userId) return errorResponse('Unauthorized', 401);
  if (userId !== OWNER_UID) return errorResponse('Permission denied', 403);

  try {
    // GITHUB_REPO/GITHUB_TOKEN 被 lawyer-dashboard 佔用，本 project 一律用 INTEL_ 前綴 secret
    const repo = Deno.env.get('INTEL_GITHUB_REPO') || 'dennislei-web/legal-industry-intel';
    const token = Deno.env.get('INTEL_GITHUB_TOKEN') || Deno.env.get('GITHUB_TOKEN');
    if (!token) return errorResponse('INTEL_GITHUB_TOKEN secret 未設定', 500);

    const res = await fetch(
      `https://api.github.com/repos/${repo}/actions/workflows/crm-officer-crawl.yml/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
          'User-Agent': 'legal-industry-intel-edge',
        },
        body: JSON.stringify({ ref: 'main', inputs: {} }),
      },
    );

    if (res.status !== 204) {
      const detail = await res.text();
      return errorResponse(`GitHub dispatch 失敗 (${res.status}): ${detail.slice(0, 200)}`, 502);
    }
    return jsonResponse({ success: true });
  } catch (e) {
    return errorResponse(e.message || 'Internal error', 500);
  }
});
