// ============================================================
// ai-import-paper Edge Function (standalone)
// 匯入學術論文：NDLTD / Scholar URL → metadata + 全文 chunks
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
const CHUNK_SIZE = 1500; // characters per chunk

const EXTRACT_PROMPT = `請使用 web_fetch 工具抓取以下網址的學術論文內容，抽取 metadata 與全文。

網址: {URL}

步驟：
1. 先 web_fetch 抓該網址（可能是 NDLTD 論文詳細頁或其他學術資料庫）
2. 從頁面中找到論文 metadata（標題、作者、年份、學位類型、機構、摘要、關鍵字）
3. 若頁面有「電子全文 PDF」或「下載全文」連結，再用 web_fetch 抓該 PDF（Claude tool 支援 PDF）
4. 從 PDF 或內文抽取章節內容

輸出格式（嚴格 JSON，不要有任何 markdown 或其他文字包裝）：
{
  "title": "論文標題",
  "authors": ["作者1", "作者2"],
  "year": 2023,
  "venue": "國立台灣大學法律學系碩士論文",
  "degree_type": "thesis_master",
  "abstract": "摘要內容（500-1500 字）",
  "keywords": ["律師", "法律市場"],
  "pdf_url": "https://xxx/fulltext.pdf",
  "sections": [
    {"title": "第一章 緒論", "content": "這一章的完整內文..."},
    {"title": "第二章 文獻回顧", "content": "..."},
    {"title": "結論與建議", "content": "..."}
  ]
}

重要：
- degree_type 必須是：thesis_master / thesis_phd / journal / conference / book / other 其中之一
- sections 若無法取得全文，可回傳空陣列 []
- 若 PDF 無法存取或頁面無全文，至少提供 metadata + abstract
- 不要編造內容；若不確定某欄位，設為 null 或省略
- authors 是陣列；若只有單一作者也要用陣列`;

interface Section { title?: string; content: string; }
interface ParsedPaper {
  title?: string;
  authors?: string[];
  year?: number;
  venue?: string;
  degree_type?: string;
  abstract?: string;
  keywords?: string[];
  pdf_url?: string;
  sections?: Section[];
}

function sliceIntoChunks(text: string, size: number): string[] {
  const chunks: string[] = [];
  for (let i = 0; i < text.length; i += size) {
    chunks.push(text.slice(i, i + size));
  }
  return chunks;
}

function detectSource(url: string): string {
  if (/ndltd\.ncl\.edu\.tw/i.test(url) || /hdl\.handle\.net/i.test(url)) return 'ndltd';
  if (/scholar\.google/i.test(url)) return 'scholar';
  if (/airiti/i.test(url)) return 'airiti';
  return 'manual';
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
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return err('Unauthorized', 401);

    const { url } = await req.json();
    if (!url || typeof url !== 'string') return err('url is required');
    try { new URL(url); } catch { return err('invalid URL'); }

    // 去重檢查
    const { data: existing } = await userClient
      .from('academic_papers')
      .select('id, title')
      .eq('source_url', url)
      .maybeSingle();
    if (existing) {
      return json({
        paper_id: existing.id,
        title: existing.title,
        message: 'already imported',
        duplicate: true,
      });
    }

    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) return err('ANTHROPIC_API_KEY not set', 500);

    // 呼叫 Claude with web_fetch
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
        max_tokens: 16000,
        system: '你是學術論文抽取助手。精準使用 web_fetch 工具，嚴格按 JSON 格式輸出，不要加 markdown 包裝。',
        messages: [{ role: 'user', content: EXTRACT_PROMPT.replace('{URL}', url) }],
        tools: [{ type: 'web_fetch_20250910', name: 'web_fetch', max_uses: 5 }],
      }),
    });
    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`Claude API ${resp.status}: ${errText}`);
    }
    const data = await resp.json();

    let text = '';
    for (const b of data.content || []) if (b.type === 'text') text += b.text;

    // 解析 JSON（容忍 ```json 包裝）
    let parsed: ParsedPaper = {};
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      try {
        parsed = JSON.parse(jsonMatch[0]);
      } catch (e) {
        console.warn('JSON parse failed:', e);
        return err(`解析 Claude 回應失敗: ${(e as Error).message}`, 500);
      }
    } else {
      return err('Claude 未回傳結構化資料，請確認 URL 可存取');
    }

    if (!parsed.title) return err('無法抽取論文標題，請確認 URL 是否為論文詳細頁');

    // 寫入 academic_papers
    const sections = parsed.sections || [];
    const fullText = sections.map((s) => s.content || '').join('\n\n');

    const { data: paper, error: insertError } = await userClient
      .from('academic_papers')
      .insert({
        user_id: user.id,
        title: parsed.title.slice(0, 500),
        authors: parsed.authors || null,
        year: parsed.year || null,
        venue: parsed.venue || null,
        degree_type: parsed.degree_type || null,
        abstract: parsed.abstract || null,
        keywords: parsed.keywords || null,
        source: detectSource(url),
        source_url: url,
        pdf_url: parsed.pdf_url || null,
        full_text_length: fullText.length || null,
        import_status: fullText.length > 0 ? 'fulltext_ready' : 'metadata_only',
      })
      .select('id')
      .single();

    if (insertError) throw insertError;
    const paperId = paper.id;

    // 切 chunks
    let chunkCount = 0;
    if (fullText.length > 0) {
      const chunkRecords: Array<Record<string, unknown>> = [];
      let idx = 0;
      for (const sec of sections) {
        if (!sec.content) continue;
        // 若章節 > CHUNK_SIZE 再切分
        if (sec.content.length <= CHUNK_SIZE) {
          chunkRecords.push({
            paper_id: paperId,
            chunk_index: idx++,
            section: sec.title || null,
            content: sec.content,
            char_count: sec.content.length,
          });
        } else {
          const subs = sliceIntoChunks(sec.content, CHUNK_SIZE);
          for (const sub of subs) {
            chunkRecords.push({
              paper_id: paperId,
              chunk_index: idx++,
              section: sec.title || null,
              content: sub,
              char_count: sub.length,
            });
          }
        }
      }

      if (chunkRecords.length > 0) {
        // batch insert (分批避免單次過大)
        const BATCH = 50;
        for (let i = 0; i < chunkRecords.length; i += BATCH) {
          const batch = chunkRecords.slice(i, i + BATCH);
          const { error: chunkErr } = await userClient
            .from('paper_chunks')
            .insert(batch);
          if (chunkErr) {
            console.warn('chunk insert error:', chunkErr);
            break;
          }
        }
        chunkCount = chunkRecords.length;

        // 更新 chunk_count
        await userClient
          .from('academic_papers')
          .update({ chunk_count: chunkCount })
          .eq('id', paperId);
      }
    }

    return json({
      paper_id: paperId,
      title: parsed.title,
      year: parsed.year,
      chunk_count: chunkCount,
      full_text_length: fullText.length,
      tokens: {
        input: data.usage?.input_tokens ?? 0,
        output: data.usage?.output_tokens ?? 0,
      },
    });
  } catch (e) {
    console.error('ai-import-paper error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
