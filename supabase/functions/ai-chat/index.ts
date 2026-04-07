// ============================================================
// ai-chat Edge Function (standalone, 可直接貼到 Supabase Dashboard)
// 多 session 對話 + web_search + 使用者知識庫 context
// ============================================================
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0';

// ========= CORS =========
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
const err = (m: string, s = 400) => json({ error: m }, s);

// ========= Anthropic =========
const ANTHROPIC_API = 'https://api.anthropic.com/v1/messages';
const MODEL = 'claude-sonnet-4-5';
const FAST_MODEL = 'claude-haiku-4-5';

interface Msg { role: 'user' | 'assistant'; content: string | Array<Record<string, unknown>>; }

async function callClaude(opts: {
  system: string; messages: Msg[]; maxTokens?: number;
  enableWebSearch?: boolean; enableWebFetch?: boolean; model?: string;
}) {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) throw new Error('ANTHROPIC_API_KEY not set');
  const tools: Array<Record<string, unknown>> = [];
  if (opts.enableWebSearch) tools.push({ type: 'web_search_20250305', name: 'web_search', max_uses: 5 });
  if (opts.enableWebFetch) tools.push({ type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 3 });
  const body: Record<string, unknown> = {
    model: opts.model ?? MODEL,
    max_tokens: opts.maxTokens ?? 4096,
    system: opts.system,
    messages: opts.messages,
  };
  if (tools.length) body.tools = tools;
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
  };
  if (opts.enableWebFetch) headers['anthropic-beta'] = 'web-fetch-2025-09-10';
  const resp = await fetch(ANTHROPIC_API, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!resp.ok) throw new Error(`Claude API ${resp.status}: ${await resp.text()}`);
  const data = await resp.json();
  let text = '';
  const toolUses: Array<{ tool: string; input: unknown; result?: unknown }> = [];
  for (const b of data.content || []) {
    if (b.type === 'text') text += b.text;
    else if (b.type === 'server_tool_use') toolUses.push({ tool: b.name, input: b.input });
    else if (b.type === 'web_search_tool_result' || b.type === 'web_fetch_tool_result') {
      if (toolUses.length) toolUses[toolUses.length - 1].result = b.content;
    }
  }
  return { text, inputTokens: data.usage?.input_tokens ?? 0, outputTokens: data.usage?.output_tokens ?? 0, toolUses };
}

async function callClaudeFast(prompt: string): Promise<string> {
  const r = await callClaude({
    system: '你是幫手，請用 15 字以內的簡短繁體中文回答，直接給結果不要解釋。',
    messages: [{ role: 'user', content: prompt }],
    maxTokens: 100,
    model: FAST_MODEL,
  });
  return r.text.trim();
}

// ========= User Context =========
async function buildUserContext(userClient: SupabaseClient, serviceClient: SupabaseClient, ctxOpts: Record<string, boolean> = {}) {
  const sources: Array<{ type: string; id?: string; title: string }> = [];
  const parts: string[] = [];

  const { data: notes } = ctxOpts.notes !== false ? await userClient.from('manual_notes')
    .select('id, title, content, category, tags, source_type, source_url, created_at')
    .order('created_at', { ascending: false }).limit(50) : { data: null };

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

  const { data: news } = ctxOpts.news !== false ? await userClient.from('news_articles')
    .select('id, title, summary, source_name, published_at, url, search_query')
    .order('published_at', { ascending: false }).limit(30) : { data: null };

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

  const { data: uploads } = ctxOpts.uploads !== false ? await userClient.from('user_uploads')
    .select('id, file_name, data_type, description, row_count, created_at')
    .order('created_at', { ascending: false }).limit(20) : { data: null };

  if (uploads?.length) {
    parts.push('## 使用者上傳的資料檔');
    for (const u of uploads) {
      parts.push(`- 📄 ${u.file_name} (${u.data_type}, ${u.row_count || '?'} 筆) - ${u.description || ''}`);
      sources.push({ type: 'upload', id: u.id, title: u.file_name });
    }
    parts.push('');
  }

  // ========= 學術論文 (最多 15 筆 metadata + abstract) =========
  const { data: papers } = ctxOpts.papers !== false ? await userClient.from('academic_papers')
    .select('id, title, authors, year, venue, degree_type, abstract, keywords')
    .order('year', { ascending: false, nullsFirst: false }).limit(15) : { data: null };

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

  if (ctxOpts.db !== false) try {
    const { count: lawyerCount } = await serviceClient.from('moj_lawyers').select('lic_no', { count: 'exact', head: true });
    const { count: firmCount } = await serviceClient.from('moj_firm_stats_cache').select('firm_name', { count: 'exact', head: true });
    const { data: topFirms } = await serviceClient.from('moj_firm_stats_cache').select('*').order('lawyer_count', { ascending: false }).limit(15);
    const { data: regions } = await serviceClient.rpc('moj_region_distribution');
    parts.push('## 台灣法律產業 DB 即時數據（來自法務部）');
    if (lawyerCount) parts.push(`- 登錄律師總數: ${lawyerCount.toLocaleString()} 位`);
    if (firmCount) parts.push(`- 事務所總數: ${firmCount.toLocaleString()} 間`);
    if (topFirms?.length) {
      parts.push('- Top 15 事務所:');
      for (const f of topFirms) parts.push(`  * ${f.firm_name}: ${f.lawyer_count} 位律師 (${f.main_region || '-'})`);
    }
    if (regions?.length) {
      parts.push('- 律師地區分布:');
      for (const r of regions.slice(0, 16)) parts.push(`  * ${r.region}: ${r.count} 位`);
    }
    sources.push({ type: 'db', title: 'MOJ 律師/事務所資料庫' });
  } catch (e) {
    console.warn('DB stats fetch failed:', e);
  }

  return { context: parts.join('\n'), sources };
}

const SYSTEM_PROMPT = `你是一位專業的台灣法律產業分析師，協助使用者深入理解法律市場動態、事務所競爭、律師職涯趨勢等議題。

你擁有使用者專屬的知識庫作為 context（包含他們的研究筆記、追蹤的新聞、上傳資料、以及即時的 MOJ 律師資料庫）。你的回答應該：

1. **優先引用使用者的筆記與資料** — 使用者累積的觀察是最重要的分析基礎
2. **善用 web_search 工具** — 當問題涉及最新動態、市場消息、併購、新政策時，主動線上搜尋
3. **結合 DB 數據佐證** — 事務所規模、律師地區分布等議題引用具體數字
4. **繁體中文回答** — 專業但易讀，適當使用 Markdown 格式（標題、列表、粗體）
5. **明確標註資料來源** — 讓使用者知道結論是來自他的筆記、新聞、還是網路搜尋

如果使用者的筆記中有相關內容，直接引用並加註「根據你之前記錄的...」。
如果筆記不足以回答，使用 web_search 工具搜尋最新資料。`;

// ========= Main Handler =========
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

    const { session_id, message, attachments, context_options } = await req.json();
    if (!message || typeof message !== 'string') return err('message is required');
    const ctxOpts = context_options ?? { db: true, notes: true, news: true, uploads: true, papers: true, web_search: true };

    let sessionId = session_id;
    let isNewSession = false;
    if (!sessionId) {
      const { data: newSession, error } = await userClient
        .from('chat_sessions').insert({ user_id: user.id, title: '新對話' })
        .select('id').single();
      if (error) throw error;
      sessionId = newSession.id;
      isNewSession = true;
    }

    const { data: history } = await userClient.from('chat_messages')
      .select('role, content').eq('session_id', sessionId).order('created_at', { ascending: true });

    // 只保留最近 6 輪（12 條訊息），避免 token 過多
    const allHistory = (history ?? []).map((m) => ({
      role: m.role === 'assistant' ? 'assistant' : 'user',
      content: m.content,
    })) as Msg[];
    const messages: Msg[] = allHistory.length > 12 ? allHistory.slice(-12) : allHistory;

    // 建立使用者訊息（含附件）
    if (attachments && Array.isArray(attachments) && attachments.length > 0) {
      const contentBlocks: Array<Record<string, unknown>> = [];
      for (const att of attachments) {
        const mediaType = att.type || 'application/octet-stream';
        if (mediaType.startsWith('image/')) {
          contentBlocks.push({
            type: 'image',
            source: { type: 'base64', media_type: mediaType, data: att.base64 },
          });
        } else if (mediaType === 'application/pdf') {
          contentBlocks.push({
            type: 'document',
            source: { type: 'base64', media_type: 'application/pdf', data: att.base64 },
            title: att.name || 'document.pdf',
          });
        } else {
          // 文字類檔案（csv, txt, json, docx 等）：解碼 base64 為文字
          try {
            const decoded = atob(att.base64);
            contentBlocks.push({
              type: 'text',
              text: `📎 附件「${att.name}」內容：\n${decoded.slice(0, 50000)}`,
            });
          } catch {
            contentBlocks.push({
              type: 'text',
              text: `📎 附件「${att.name}」(${mediaType}, ${att.size} bytes) — 無法解碼為文字`,
            });
          }
        }
      }
      contentBlocks.push({ type: 'text', text: message });
      messages.push({ role: 'user', content: contentBlocks });
    } else {
      messages.push({ role: 'user', content: message });
    }

    const { context, sources } = await buildUserContext(userClient, serviceClient, ctxOpts);

    // 進階：用當前使用者訊息去 chunks 全文搜尋（僅在論文開啟時）
    let chunksSection = '';
    if (ctxOpts.papers !== false) try {
      const { data: relevantChunks } = await userClient.rpc('search_paper_chunks', {
        query_text: message,
        max_results: 5,
      });
      if (relevantChunks && relevantChunks.length > 0) {
        const parts: string[] = ['## 從論文全文中找到的相關段落（與此問題最相關）'];
        for (const c of relevantChunks) {
          parts.push(`### 【${c.paper_title}${c.paper_year ? ' (' + c.paper_year + ')' : ''}】${c.section ? ' - ' + c.section : ''}`);
          parts.push(String(c.content).slice(0, 800));
          parts.push('');
          sources.push({ type: 'paper_chunk', id: c.paper_id, title: `${c.paper_title}${c.section ? ' / ' + c.section : ''}` });
        }
        chunksSection = '\n\n' + parts.join('\n');
      }
    } catch (e) {
      console.warn('search_paper_chunks failed:', e);
    }

    const systemPrompt = `${SYSTEM_PROMPT}\n\n---\n\n# 使用者的知識庫\n\n${context}${chunksSection}`;

    const result = await callClaude({
      system: systemPrompt, messages,
      enableWebSearch: ctxOpts.web_search !== false, maxTokens: 4096,
    });

    await userClient.from('chat_messages').insert([
      { session_id: sessionId, role: 'user', content: message },
      {
        session_id: sessionId, role: 'assistant', content: result.text,
        sources, tool_uses: result.toolUses,
        tokens_used: result.inputTokens + result.outputTokens,
      },
    ]);

    await userClient.from('chat_sessions')
      .update({ last_message_at: new Date().toISOString() })
      .eq('id', sessionId);

    if (isNewSession) {
      try {
        const title = await callClaudeFast(
          `用 15 字以內的繁體中文幫這個問題取個標題："${message.slice(0, 200)}"`,
        );
        await userClient.from('chat_sessions').update({ title: title.slice(0, 50) }).eq('id', sessionId);
      } catch (e) { console.warn('title gen failed', e); }
    }

    return json({
      session_id: sessionId,
      assistant_message: result.text,
      sources, tool_uses: result.toolUses,
      tokens: { input: result.inputTokens, output: result.outputTokens },
    });
  } catch (e) {
    console.error('ai-chat error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
