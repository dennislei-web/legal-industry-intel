// ============================================================
// ai-search-news Edge Function (standalone)
// 用 Claude web_search 搜尋法律產業新聞
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0';

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

const SEARCH_PROMPT = `請使用 web_search 工具搜尋與「{QUERY}」相關的台灣法律產業最新新聞，找出 8-12 則最相關的新聞。

搜尋關鍵字建議：
- "{QUERY}" 台灣 法律
- "{QUERY}" 律師事務所
- "{QUERY}" 法律產業

輸出格式（嚴格 JSON，陣列，不要有任何其他文字或 markdown 包裝）：
[
  {
    "title": "新聞標題",
    "url": "原始網址",
    "source": "來源媒體名",
    "published_at": "YYYY-MM-DD",
    "summary": "150 字內的繁體中文摘要",
    "relevance": 0.0-1.0
  }
]

注意：
- 只回傳與台灣法律產業相關的新聞
- url 必須是 web_search 實際找到的原始網址
- 若找不到 8 則也沒關係，有多少回多少
- 依相關性排序（relevance 高到低）`;

interface Article {
  title: string; url: string; source?: string;
  published_at?: string; summary?: string; relevance?: number;
}

function parseDate(s?: string): string | null {
  if (!s) return null;
  const d = new Date(s);
  if (isNaN(d.getTime())) return null;
  return d.toISOString();
}

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
    let user: { id: string } | null = null;
    try {
      const parts = token.split('.');
      if (parts.length === 3) {
        const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
        if (payload.sub && payload.role === 'authenticated') {
          user = { id: payload.sub };
        }
      }
    } catch (e) { console.warn('JWT decode failed:', e); }
    if (!user) return err('Unauthorized', 401);

    const { query } = await req.json();
    if (!query || typeof query !== 'string') return err('query is required');

    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) return err('ANTHROPIC_API_KEY not set', 500);

    const resp = await fetch(ANTHROPIC_API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 4000,
        system: '你是一個專業的新聞搜尋助手，請精準使用 web_search 工具並以嚴格 JSON 陣列格式輸出結果。',
        messages: [{ role: 'user', content: SEARCH_PROMPT.replaceAll('{QUERY}', query) }],
        tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }],
      }),
    });
    if (!resp.ok) throw new Error(`Claude API ${resp.status}: ${await resp.text()}`);
    const data = await resp.json();

    let text = '';
    for (const b of data.content || []) if (b.type === 'text') text += b.text;

    let articles: Article[] = [];
    const arrayMatch = text.match(/\[[\s\S]*\]/);
    if (arrayMatch) {
      try { articles = JSON.parse(arrayMatch[0]); } catch (e) { console.warn('JSON parse failed:', e); }
    }

    if (!Array.isArray(articles) || articles.length === 0) {
      return json({ articles: [], raw: text, note: 'No structured results' });
    }

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } },
    );

    const records = articles
      .filter((a) => a.title && a.url)
      .map((a) => ({
        title: a.title.slice(0, 500),
        url: a.url,
        source_name: a.source || 'Claude Web Search',
        published_at: parseDate(a.published_at),
        summary: a.summary || null,
        tags: [query],
        relevance_score: a.relevance || null,
        search_query: query,
        ai_fetched: true,
      }));

    if (records.length > 0) {
      await serviceClient.from('news_articles').upsert(records, { onConflict: 'url' });
    }

    return json({
      articles: records, count: records.length,
      tokens: { input: data.usage?.input_tokens ?? 0, output: data.usage?.output_tokens ?? 0 },
    });
  } catch (e) {
    console.error('ai-search-news error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
