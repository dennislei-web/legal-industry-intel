// ============================================================
// ai-batch-seed-papers Edge Function
// 批次建立論文骨架 (metadata only)
// 使用者按一個按鈕 → AI 搜尋多個關鍵字 → 每個 topic 找 5-10 篇 →
// 全部存成 academic_papers placeholder (無 chunks)，讓使用者之後
// 逐篇下載 PDF 上傳升級
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

// 預設主題 (台灣律師產業相關)
const DEFAULT_TOPICS = [
  '律師職涯 勞動條件',
  '法律事務所 經營 管理',
  '台灣 法律市場 供需',
  '法律科技 LegalTech',
  '律師 專業倫理',
  '司法改革 律師',
  '律師 專業化 分工',
];

const SEARCH_PROMPT = `請使用 web_search 工具搜尋 ndltd.ncl.edu.tw（台灣博碩士論文知識加值系統）上與「{QUERY}」相關的台灣碩博士論文。

目標：找出 5-8 篇最相關、最有價值的論文。

搜尋策略：
- site:ndltd.ncl.edu.tw "{QUERY}"
- "{QUERY}" 碩士論文 OR 博士論文 台灣

輸出格式（嚴格 JSON 陣列，不要 markdown 包裝）：
[
  {
    "title": "論文中文標題",
    "url": "NDLTD 論文詳細頁 URL (必須是 ndltd.ncl.edu.tw 網域)",
    "year": 2022,
    "authors": ["作者姓名"],
    "venue": "大學系所",
    "degree_type": "thesis_master",
    "snippet": "100-200 字摘要",
    "keywords": ["關鍵字1", "關鍵字2"]
  }
]

要求：
- title 必須是中文原文
- degree_type 必須是 thesis_master / thesis_phd / journal / conference / other
- 優先選擇近 10 年（2015 之後）的論文
- 品質優先於數量`;

interface SearchResult {
  title: string;
  url: string;
  year?: number;
  authors?: string[];
  venue?: string;
  degree_type?: string;
  snippet?: string;
  keywords?: string[];
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

    const { topics: inputTopics, topic } = await req.json().catch(() => ({}));
    // 允許單一 topic 或多個 topics；預設用 DEFAULT_TOPICS
    const topics: string[] = Array.isArray(inputTopics) && inputTopics.length > 0
      ? inputTopics
      : (topic ? [topic] : DEFAULT_TOPICS);

    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) return err('ANTHROPIC_API_KEY not set', 500);

    const allPapers: Array<SearchResult & { topic: string }> = [];
    const topicResults: Array<{ topic: string; count: number; error?: string }> = [];

    // 逐個 topic 查詢（避免一次送太大 prompt）
    for (const t of topics) {
      try {
        const resp = await fetch(ANTHROPIC_API, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
          body: JSON.stringify({
            model: MODEL,
            max_tokens: 3000,
            system: '你是台灣法律產業學術論文搜尋助手。精準使用 web_search 工具，嚴格 JSON 陣列輸出。',
            messages: [{ role: 'user', content: SEARCH_PROMPT.replaceAll('{QUERY}', t) }],
            tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3 }],
          }),
        });
        if (!resp.ok) {
          const errText = await resp.text();
          topicResults.push({ topic: t, count: 0, error: `${resp.status}: ${errText.slice(0, 150)}` });
          continue;
        }
        const data = await resp.json();
        let text = '';
        for (const b of data.content || []) if (b.type === 'text') text += b.text;

        const arrayMatch = text.match(/\[[\s\S]*\]/);
        let results: SearchResult[] = [];
        if (arrayMatch) {
          try { results = JSON.parse(arrayMatch[0]); } catch (e) { console.warn('JSON parse failed for topic', t, e); }
        }
        for (const r of results) {
          if (r.title && r.url) allPapers.push({ ...r, topic: t });
        }
        topicResults.push({ topic: t, count: results.length });
      } catch (e) {
        topicResults.push({ topic: t, count: 0, error: String((e as Error).message).slice(0, 150) });
      }
    }

    // 去重 by URL
    const seen = new Set<string>();
    const unique = allPapers.filter(p => {
      if (seen.has(p.url)) return false;
      seen.add(p.url);
      return true;
    });

    // 檢查哪些已存在
    const urls = unique.map(p => p.url);
    const { data: existing } = await userClient
      .from('academic_papers')
      .select('source_url')
      .in('source_url', urls);
    const existingSet = new Set((existing || []).map(x => x.source_url));

    // 插入 placeholder papers
    const toInsert = unique
      .filter(p => !existingSet.has(p.url))
      .map(p => ({
        user_id: user!.id,
        title: p.title.slice(0, 500),
        authors: p.authors && p.authors.length > 0 ? p.authors : null,
        year: p.year || null,
        venue: p.venue || null,
        degree_type: p.degree_type || 'thesis_master',
        abstract: p.snippet || null,
        keywords: p.keywords && p.keywords.length > 0 ? p.keywords : [p.topic],
        source: 'ndltd',
        source_url: p.url,
        import_status: 'metadata_only',
        chunk_count: 0,
      }));

    let inserted = 0;
    if (toInsert.length > 0) {
      const { error: insErr } = await userClient.from('academic_papers').insert(toInsert);
      if (insErr) {
        return err(`insert failed: ${insErr.message}`, 500);
      }
      inserted = toInsert.length;
    }

    return json({
      topics_processed: topicResults.length,
      topic_results: topicResults,
      total_found: unique.length,
      already_existed: unique.length - toInsert.length,
      inserted,
    });
  } catch (e) {
    console.error('ai-batch-seed-papers error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
