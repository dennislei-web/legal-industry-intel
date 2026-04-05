// ============================================================
// ai-parse-paper-pdf Edge Function
// 輸入: { file_name, full_text, pages_count }
// 前端用 pdfjs 抽文字後送來，這個 function 用 Claude 分析 metadata + 切 chunks
// 不用 web_fetch / web_search，成本極低
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
const CHUNK_SIZE = 1500;

const METADATA_PROMPT = `以下是一份學術論文 PDF 抽出的純文字開頭部分（前 8000 字）。請抽取 metadata 並識別章節結構。

論文前 8000 字：
{TEXT}

輸出嚴格 JSON（不要 markdown 包裝）：
{
  "title": "論文標題",
  "authors": ["作者"],
  "year": 2023,
  "venue": "大學系所 / 期刊名",
  "degree_type": "thesis_master" | "thesis_phd" | "journal" | "conference" | "other",
  "abstract": "摘要內容（通常在目次之後或「摘要」「Abstract」段落）",
  "keywords": ["關鍵字1", "關鍵字2"],
  "section_markers": [
    {"title": "第一章 緒論", "marker": "第一章 緒論"},
    {"title": "第二章 文獻回顧", "marker": "第二章"},
    {"title": "結論", "marker": "結論與建議"}
  ]
}

section_markers 是章節標題清單，用來後續切分 full_text。每個 marker 是論文中實際出現的章節開頭字串（越精準越好），讓程式能用 indexOf 定位。`;

interface SectionMarker { title: string; marker: string; }
interface ParsedMeta {
  title?: string;
  authors?: string[];
  year?: number;
  venue?: string;
  degree_type?: string;
  abstract?: string;
  keywords?: string[];
  section_markers?: SectionMarker[];
}

function sliceBySections(fullText: string, markers: SectionMarker[]): Array<{ title: string; content: string }> {
  if (!markers || markers.length === 0) {
    // Fallback: 按固定長度切
    const sections: Array<{ title: string; content: string }> = [];
    for (let i = 0; i < fullText.length; i += CHUNK_SIZE * 3) {
      sections.push({
        title: `段落 ${sections.length + 1}`,
        content: fullText.slice(i, i + CHUNK_SIZE * 3),
      });
    }
    return sections;
  }

  // 找每個 marker 在 fullText 中的位置
  const positions: Array<{ title: string; pos: number }> = [];
  for (const m of markers) {
    const pos = fullText.indexOf(m.marker);
    if (pos >= 0) positions.push({ title: m.title, pos });
  }
  positions.sort((a, b) => a.pos - b.pos);

  // 切成章節
  const sections: Array<{ title: string; content: string }> = [];
  for (let i = 0; i < positions.length; i++) {
    const start = positions[i].pos;
    const end = i + 1 < positions.length ? positions[i + 1].pos : fullText.length;
    sections.push({
      title: positions[i].title,
      content: fullText.slice(start, end).trim(),
    });
  }

  // 若第一個章節前還有內容（通常是封面 + 目次 + 摘要），也加進去
  if (positions[0]?.pos > 200) {
    sections.unshift({
      title: '封面與摘要',
      content: fullText.slice(0, positions[0].pos).trim(),
    });
  }

  return sections.filter(s => s.content.length > 50);
}

function sliceIntoChunks(text: string, size: number): string[] {
  const chunks: string[] = [];
  for (let i = 0; i < text.length; i += size) {
    chunks.push(text.slice(i, i + size));
  }
  return chunks;
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
    // JWT decode (Supabase gateway 已驗證)
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

    const { file_name, full_text, pages_count } = await req.json();
    if (!full_text || typeof full_text !== 'string') return err('full_text is required');
    if (full_text.length < 200) return err('full_text too short (< 200 chars)');

    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) return err('ANTHROPIC_API_KEY not set', 500);

    // Claude 分析前 8000 字抽 metadata
    const previewText = full_text.slice(0, 8000);
    const resp = await fetch(ANTHROPIC_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 2000,
        system: '你是學術論文 metadata 抽取助手。嚴格按 JSON 格式輸出。',
        messages: [{ role: 'user', content: METADATA_PROMPT.replace('{TEXT}', previewText) }],
      }),
    });
    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`Claude API ${resp.status}: ${errText}`);
    }
    const data = await resp.json();

    let text = '';
    for (const b of data.content || []) if (b.type === 'text') text += b.text;

    let parsed: ParsedMeta = {};
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      try {
        parsed = JSON.parse(jsonMatch[0]);
      } catch (e) {
        console.warn('JSON parse failed:', e);
        return err(`Metadata 解析失敗: ${(e as Error).message}`, 500);
      }
    }

    const title = parsed.title || file_name || '未命名論文';

    // 檢查是否已匯入 (by title + year)
    const { data: existing } = await userClient
      .from('academic_papers')
      .select('id, title')
      .eq('title', title)
      .maybeSingle();
    if (existing) {
      return json({
        paper_id: existing.id,
        title: existing.title,
        message: 'already imported',
        duplicate: true,
      });
    }

    // 按章節切分全文
    const sections = sliceBySections(full_text, parsed.section_markers || []);

    // 寫入 academic_papers
    const { data: paper, error: insertError } = await userClient
      .from('academic_papers')
      .insert({
        user_id: user.id,
        title: title.slice(0, 500),
        authors: parsed.authors || null,
        year: parsed.year || null,
        venue: parsed.venue || null,
        degree_type: parsed.degree_type || null,
        abstract: parsed.abstract || null,
        keywords: parsed.keywords || null,
        source: 'pdf_upload',
        source_url: file_name || 'uploaded.pdf',
        full_text_length: full_text.length,
        import_status: 'fulltext_ready',
      })
      .select('id')
      .single();

    if (insertError) throw insertError;
    const paperId = paper.id;

    // Insert chunks
    const chunkRecords: Array<Record<string, unknown>> = [];
    let idx = 0;
    for (const sec of sections) {
      if (!sec.content || sec.content.length < 50) continue;
      if (sec.content.length <= CHUNK_SIZE) {
        chunkRecords.push({
          paper_id: paperId,
          chunk_index: idx++,
          section: sec.title,
          content: sec.content,
          char_count: sec.content.length,
        });
      } else {
        const subs = sliceIntoChunks(sec.content, CHUNK_SIZE);
        for (let si = 0; si < subs.length; si++) {
          chunkRecords.push({
            paper_id: paperId,
            chunk_index: idx++,
            section: `${sec.title} (${si + 1}/${subs.length})`,
            content: subs[si],
            char_count: subs[si].length,
          });
        }
      }
    }

    // Batch insert
    if (chunkRecords.length > 0) {
      const BATCH = 50;
      for (let i = 0; i < chunkRecords.length; i += BATCH) {
        const batch = chunkRecords.slice(i, i + BATCH);
        const { error: chunkErr } = await userClient.from('paper_chunks').insert(batch);
        if (chunkErr) {
          console.warn('chunk insert error:', chunkErr);
          break;
        }
      }
      await userClient
        .from('academic_papers')
        .update({ chunk_count: chunkRecords.length })
        .eq('id', paperId);
    }

    return json({
      paper_id: paperId,
      title,
      year: parsed.year,
      chunk_count: chunkRecords.length,
      full_text_length: full_text.length,
      pages_count,
      tokens: {
        input: data.usage?.input_tokens ?? 0,
        output: data.usage?.output_tokens ?? 0,
      },
    });
  } catch (e) {
    console.error('ai-parse-paper-pdf error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
