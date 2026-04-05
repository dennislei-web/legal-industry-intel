// ============================================================
// ai-url-extract Edge Function (standalone)
// 貼 URL → AI 抓內容 → 摘要存成筆記
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
const err = (m: string, s = 400) => json({ error: m }, s);

const ANTHROPIC_API = 'https://api.anthropic.com/v1/messages';
const MODEL = 'claude-sonnet-4-5';

const EXTRACT_PROMPT = `請使用 web_fetch 工具抓取以下網址的內容，並用繁體中文輸出結構化摘要。

網址: {URL}

輸出格式（嚴格 JSON，不要有任何其他文字或 markdown）：
{
  "title": "40 字內的簡短標題",
  "summary": "300-600 字的重點摘要，保留關鍵數字與事實",
  "tags": ["標籤1", "標籤2", "標籤3"]
}`;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const token = authHeader.replace(/^Bearer\s+/i, '');
    const { data: { user } } = await userClient.auth.getUser(token);
    if (!user) return err('Unauthorized', 401);

    const { url, category } = await req.json();
    if (!url || typeof url !== 'string') return err('url is required');
    try { new URL(url); } catch { return err('invalid URL'); }

    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) return err('ANTHROPIC_API_KEY not set', 500);

    const resp = await fetch(ANTHROPIC_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'web-fetch-2025-09-10',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 2000,
        system: '你是一個網頁內容摘要助手，請精準使用 web_fetch 工具並以 JSON 格式輸出。',
        messages: [{ role: 'user', content: EXTRACT_PROMPT.replace('{URL}', url) }],
        tools: [{ type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 }],
      }),
    });
    if (!resp.ok) throw new Error(`Claude API ${resp.status}: ${await resp.text()}`);
    const data = await resp.json();

    let text = '';
    for (const b of data.content || []) if (b.type === 'text') text += b.text;

    let parsed: { title?: string; summary?: string; tags?: string[] } = {};
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      try { parsed = JSON.parse(jsonMatch[0]); } catch (e) { console.warn('JSON parse failed:', e); }
    }

    const title = parsed.title || '來自 URL 的筆記';
    const summary = parsed.summary || text;
    const tags = parsed.tags || [];

    const { data: note, error } = await userClient.from('manual_notes').insert({
      user_id: user.id,
      title: title.slice(0, 100),
      content: summary,
      category: category || 'general',
      tags,
      source_type: 'url',
      source_url: url,
    }).select('id').single();
    if (error) throw error;

    return json({
      note_id: note.id, title, summary, tags,
      tokens: { input: data.usage?.input_tokens ?? 0, output: data.usage?.output_tokens ?? 0 },
    });
  } catch (e) {
    console.error('ai-url-extract error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
