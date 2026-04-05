// ============================================================
// ai-search-papers Edge Function (standalone)
// 搜尋學術論文 (NDLTD / Google Scholar)，回傳結果讓使用者選擇匯入
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

const SEARCH_PROMPT = `請使用 web_search 工具搜尋與「{QUERY}」相關的台灣學術論文，找出 10-15 篇最相關的論文。

搜尋範圍：
- 優先: 臺灣博碩士論文知識加值系統 (ndltd.ncl.edu.tw)
- 其次: Google Scholar scholar.google.com 上的繁中論文
- 其他: Airiti 華藝、月旦、法律期刊論文

搜尋建議:
- "{QUERY}" site:ndltd.ncl.edu.tw
- "{QUERY}" 碩士論文 OR 博士論文 台灣
- "{QUERY}" 律師 OR 法律事務所 論文

輸出格式（嚴格 JSON 陣列，不要有任何 markdown 或其他文字包裝）：
[
  {
    "title": "論文標題",
    "url": "論文詳細頁 URL",
    "year": 2023,
    "authors": ["作者1"],
    "venue": "大學系所/期刊名",
    "degree_type": "thesis_master",
    "snippet": "150 字摘要",
    "relevance": 0.85
  }
]

注意：
- 只回傳與「台灣法律產業」相關的論文
- url 必須是 web_search 實際找到的詳細頁連結
- degree_type 必須是 thesis_master / thesis_phd / journal / conference / other 之一
- 依相關性排序（relevance 高到低）`;

interface SearchResult {
  title: string;
  url: string;
  year?: number;
  authors?: string[];
  venue?: string;
  degree_type?: string;
  snippet?: string;
  relevance?: number;
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
        system: '你是學術論文搜尋助手。精準使用 web_search 工具，嚴格按 JSON 陣列格式輸出結果。',
        messages: [{ role: 'user', content: SEARCH_PROMPT.replaceAll('{QUERY}', query) }],
        tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }],
      }),
    });
    if (!resp.ok) throw new Error(`Claude API ${resp.status}: ${await resp.text()}`);
    const data = await resp.json();

    let text = '';
    for (const b of data.content || []) if (b.type === 'text') text += b.text;

    let results: SearchResult[] = [];
    const arrayMatch = text.match(/\[[\s\S]*\]/);
    if (arrayMatch) {
      try {
        results = JSON.parse(arrayMatch[0]);
      } catch (e) {
        console.warn('JSON parse failed:', e);
      }
    }

    // 過濾: 已匯入過的標記為 already_imported
    const urls = results.map((r) => r.url).filter(Boolean);
    const { data: existing } = await userClient
      .from('academic_papers')
      .select('source_url')
      .in('source_url', urls);
    const importedSet = new Set((existing || []).map((x) => x.source_url));

    const annotated = results.map((r) => ({
      ...r,
      already_imported: importedSet.has(r.url),
    }));

    return json({
      query,
      results: annotated,
      count: annotated.length,
      tokens: {
        input: data.usage?.input_tokens ?? 0,
        output: data.usage?.output_tokens ?? 0,
      },
    });
  } catch (e) {
    console.error('ai-search-papers error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
