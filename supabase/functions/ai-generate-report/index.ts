// ============================================================
// ai-generate-report Edge Function (standalone)
// 以使用者 context 生成市場趨勢分析報告
// ============================================================
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0';

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

async function callClaude(opts: {
  system: string;
  messages: Array<{ role: 'user' | 'assistant'; content: string }>;
  maxTokens?: number; enableWebSearch?: boolean;
}) {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) throw new Error('ANTHROPIC_API_KEY not set');
  const tools: Array<Record<string, unknown>> = [];
  if (opts.enableWebSearch) tools.push({ type: 'web_search_20250305', name: 'web_search', max_uses: 5 });
  const body: Record<string, unknown> = {
    model: MODEL,
    max_tokens: opts.maxTokens ?? 6000,
    system: opts.system,
    messages: opts.messages,
  };
  if (tools.length) body.tools = tools;
  const resp = await fetch(ANTHROPIC_API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(`Claude API ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  let text = '';
  const toolUses: Array<{ tool: string; input: unknown }> = [];
  for (const b of data.content || []) {
    if (b.type === 'text') text += b.text;
    else if (b.type === 'server_tool_use') toolUses.push({ tool: b.name, input: b.input });
  }
  return { text, inputTokens: data.usage?.input_tokens ?? 0, outputTokens: data.usage?.output_tokens ?? 0, toolUses };
}

async function buildUserContext(userClient: SupabaseClient, serviceClient: SupabaseClient) {
  const sources: Array<{ type: string; id?: string; title: string }> = [];
  const parts: string[] = [];

  const { data: notes } = await userClient.from('manual_notes')
    .select('id, title, content, category, tags, source_type, source_url, created_at')
    .order('created_at', { ascending: false }).limit(50);
  if (notes?.length) {
    parts.push('## 使用者的研究筆記（時間由新到舊）');
    for (const n of notes) {
      const tagStr = n.tags?.length ? ` [${n.tags.join(', ')}]` : '';
      const srcType = n.source_type && n.source_type !== 'manual' ? ` (${n.source_type})` : '';
      parts.push(`### ${n.title}${tagStr}${srcType}`);
      parts.push(`_類別: ${n.category || 'general'}, 建立: ${String(n.created_at).slice(0, 10)}_`);
      if (n.content) parts.push(String(n.content).slice(0, 500));
      if (n.source_url) parts.push(`來源: ${n.source_url}`);
      parts.push('');
      sources.push({ type: 'note', id: n.id, title: n.title });
    }
  }

  const { data: news } = await userClient.from('news_articles')
    .select('id, title, summary, source_name, published_at')
    .order('published_at', { ascending: false }).limit(30);
  if (news?.length) {
    parts.push('## 最近的產業新聞');
    for (const a of news) {
      const date = String(a.published_at || '').slice(0, 10);
      parts.push(`- **${a.title}** (${a.source_name || '未知'}, ${date})`);
      if (a.summary) parts.push(`  ${String(a.summary).slice(0, 300)}`);
      sources.push({ type: 'news', id: a.id, title: a.title });
    }
    parts.push('');
  }

  // 學術論文 (最多 15 筆 metadata + abstract)
  const { data: papers } = await userClient.from('academic_papers')
    .select('id, title, authors, year, venue, degree_type, abstract, keywords')
    .order('year', { ascending: false, nullsFirst: false }).limit(15);

  if (papers?.length) {
    parts.push('## 知識庫中的學術論文（可引用）');
    const degreeMap: Record<string, string> = {
      thesis_master: '碩論', thesis_phd: '博論',
      journal: '期刊', conference: '研討會', book: '專書',
    };
    for (const p of papers) {
      const degree = degreeMap[p.degree_type || ''] || '';
      parts.push(`### ${p.title} (${p.year || 'N/A'}${degree ? ', ' + degree : ''})`);
      if (p.authors?.length) parts.push(`作者: ${p.authors.join(', ')}`);
      if (p.venue) parts.push(`機構/來源: ${p.venue}`);
      if (p.abstract) parts.push(`摘要: ${String(p.abstract).slice(0, 400)}`);
      if (p.keywords?.length) parts.push(`關鍵字: ${p.keywords.join(', ')}`);
      parts.push('');
      sources.push({ type: 'paper', id: p.id, title: p.title });
    }
  }

  try {
    const { count: lawyerCount } = await serviceClient.from('moj_lawyers').select('lic_no', { count: 'exact', head: true });
    const { count: firmCount } = await serviceClient.from('moj_firm_stats_cache').select('firm_name', { count: 'exact', head: true });
    const { data: topFirms } = await serviceClient.from('moj_firm_stats_cache').select('*').order('lawyer_count', { ascending: false }).limit(20);
    const { data: regions } = await serviceClient.rpc('moj_region_distribution');
    parts.push('## 台灣法律產業 DB 即時數據（來自法務部）');
    if (lawyerCount) parts.push(`- 登錄律師總數: ${lawyerCount.toLocaleString()} 位`);
    if (firmCount) parts.push(`- 事務所總數: ${firmCount.toLocaleString()} 間`);
    if (topFirms?.length) {
      parts.push('- Top 20 事務所:');
      for (const f of topFirms) parts.push(`  * ${f.firm_name}: ${f.lawyer_count} 位律師 (${f.main_region || '-'})`);
    }
    if (regions?.length) {
      parts.push('- 律師地區分布:');
      for (const r of regions.slice(0, 16)) parts.push(`  * ${r.region}: ${r.count} 位`);
    }
    sources.push({ type: 'db', title: 'MOJ 律師/事務所資料庫' });
  } catch (e) { console.warn('DB stats fetch failed:', e); }

  return { context: parts.join('\n'), sources };
}

const SYSTEM_PROMPT = `你是一位專業的台灣法律產業分析師，擅長從碎片化的觀察與數據中提煉洞察。請務必：
- 優先引用使用者筆記的觀察（並明確說「根據你的筆記...」）
- 結合 DB 實際數字佐證
- 必要時使用 web_search 補充最新動態
- 繁體中文、使用 Markdown 格式`;

const REPORT_PROMPT = `請基於我的知識庫，產出一份「台灣法律產業現況分析報告」。

報告結構（使用 Markdown）：

## 一、產業關鍵數據速覽
(引用 DB 即時數據：律師總數、事務所分布、Top 事務所等)

## 二、近期重要動態
(從我的筆記和新聞中歸納)

## 三、趨勢觀察
(結合我的觀察筆記與產業數據，點出值得關注的現象)

## 四、對事務所經營的啟示
(給實務上的建議或戰略方向)

## 五、延伸追蹤建議
(建議接下來要關注的議題或資訊源)

要求：
- 優先引用「我的筆記」的觀察，並明確標註「根據你的筆記 XXX」
- 若筆記不足以支撐某段結論，使用 web_search 補充最新資訊
- 繁體中文，專業但易讀
- 可以引用具體數字和事務所名稱
- 控制在 1500 字以內`;

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

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } },
    );

    const body = await req.json().catch(() => ({}));
    const focus = body?.focus;

    const { context, sources } = await buildUserContext(userClient, serviceClient);
    const systemPrompt = `${SYSTEM_PROMPT}\n\n---\n\n# 使用者的知識庫\n\n${context}`;

    const userMessage = focus ? `${REPORT_PROMPT}\n\n特別聚焦：${focus}` : REPORT_PROMPT;
    const result = await callClaude({
      system: systemPrompt,
      messages: [{ role: 'user', content: userMessage }],
      enableWebSearch: true,
      maxTokens: 6000,
    });

    const { data: insight } = await serviceClient.from('ai_insights').insert({
      insight_type: 'trend_analysis',
      title: `產業分析報告 - ${new Date().toLocaleDateString('zh-TW')}`,
      content: result.text,
      data_range_start: new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10),
      data_range_end: new Date().toISOString().slice(0, 10),
      model_used: 'claude-sonnet-4-5',
    }).select('id').single();

    return json({
      insight_id: insight?.id,
      content: result.text,
      sources,
      tokens: { input: result.inputTokens, output: result.outputTokens },
    });
  } catch (e) {
    console.error('ai-generate-report error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
