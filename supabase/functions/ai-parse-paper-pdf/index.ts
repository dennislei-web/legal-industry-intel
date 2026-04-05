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
const MODEL = 'claude-haiku-4-5';
const CHUNK_SIZE = 1500;
const HEAD_CHARS = 10000;  // 前 10000 字（含封面）
const TAIL_CHARS = 2000;   // 後 2000 字（含參考文獻，有時會出現作者資訊）

const METADATA_PROMPT = `以下是一份台灣學術論文 PDF 抽出的純文字。請找出論文的**中文封面資訊**，不要被前段的目次或英文 Abstract 誤導。

重要指引（台灣碩博士論文結構）：
- 封面順序通常是：**大學名稱 → 系所 → 學位 → 論文中文標題 → 指導教授 → 研究生姓名 → 年份**
- 常見封面關鍵字：「國立XX大學」「XX系」「碩士論文」「博士論文」「指導教授：」「研究生：」「撰」「中華民國XX年X月」
- **請優先使用中文標題**（不要翻譯成英文，也不要用 Abstract 段落的英文標題）
- 作者通常寫在「研究生：XXX 撰」或「研究生 XXX」這樣的位置
- 指導教授不是作者
- 年份：若寫「中華民國 105 年」則 year = 2016 (ROC + 1911)

論文 PDF 文字（前段為封面 + 目次 + 摘要，後段為參考文獻）：
{TEXT}

輸出嚴格 JSON（不要 markdown 包裝）：
{
  "title": "論文中文標題（精確複製，不翻譯）",
  "authors": ["作者姓名"],
  "year": 2016,
  "venue": "國立XX大學 XX學系（碩士論文）",
  "degree_type": "thesis_master",
  "abstract": "中文摘要全文（非英文 Abstract）",
  "keywords": ["關鍵字1", "關鍵字2"],
  "section_markers": [
    {"title": "第一章 緒論", "marker": "第一章 緒論"},
    {"title": "第二章 文獻回顧", "marker": "第二章"},
    {"title": "結論與建議", "marker": "結論與建議"}
  ]
}

- degree_type 只能是：thesis_master / thesis_phd / journal / conference / book / other
- authors 必為陣列（單一作者也要用陣列）
- section_markers 是章節標題清單，marker 是論文中實際出現的字串，讓程式 indexOf 定位切章節
- 若某欄位無法確定，用 null 或 [] 而非猜測`;

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

// 計算兩個字串的相似度（簡單 2-gram Jaccard）
function similarity(a: string, b: string): number {
  if (!a || !b) return 0;
  if (a === b) return 1;
  const getBigrams = (s: string) => {
    const bigrams = new Set<string>();
    const cleaned = s.replace(/\s+/g, '').toLowerCase();
    for (let i = 0; i < cleaned.length - 1; i++) {
      bigrams.add(cleaned.slice(i, i + 2));
    }
    return bigrams;
  };
  const A = getBigrams(a);
  const B = getBigrams(b);
  if (A.size === 0 || B.size === 0) return 0;
  let intersect = 0;
  for (const g of A) if (B.has(g)) intersect++;
  return (2 * intersect) / (A.size + B.size);
}

// 在既有論文中找最佳 merge target（title similarity > 0.4 或作者完全一致且 title 含共同關鍵詞）
interface ExistingPaper {
  id: string;
  title: string;
  authors?: string[] | null;
  source?: string | null;
  chunk_count?: number | null;
}
function findBestMatch(
  newTitle: string,
  newAuthors: string[],
  existing: ExistingPaper[],
): ExistingPaper | null {
  let best: { paper: ExistingPaper; score: number } | null = null;
  for (const p of existing) {
    if (!p.title) continue;
    // 如果既有 paper 已有 full-text (chunk_count > 3)，不要覆蓋
    if ((p.chunk_count || 0) > 3) continue;
    const titleSim = similarity(p.title, newTitle);
    let authorMatch = 0;
    if (newAuthors.length > 0 && p.authors && p.authors.length > 0) {
      const newSet = new Set(newAuthors.map(a => a.replace(/\s+/g, '')));
      for (const a of p.authors) {
        if (newSet.has(a.replace(/\s+/g, ''))) authorMatch++;
      }
    }
    const score = titleSim + (authorMatch > 0 ? 0.3 : 0);
    // 閾值: titleSim > 0.4 或 (titleSim > 0.25 且有共同作者)
    if ((titleSim > 0.4 || (titleSim > 0.25 && authorMatch > 0)) &&
        (!best || score > best.score)) {
      best = { paper: p, score };
    }
  }
  return best?.paper || null;
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

    // 組合：前 10000 字 (含封面) + 後 2000 字 (含參考文獻)
    const head = full_text.slice(0, HEAD_CHARS);
    const tail = full_text.length > HEAD_CHARS + TAIL_CHARS
      ? '\n\n[...中間省略...]\n\n' + full_text.slice(-TAIL_CHARS)
      : '';
    const previewText = head + tail;
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

    // ========================================================
    // MERGE 邏輯：先用 title fuzzy match 既有 paper
    // 若找到既有骨架（來自 ndltd URL 匯入的摘要），就升級成含全文的版本
    // 否則才新建
    // ========================================================
    const { data: allPapers } = await userClient
      .from('academic_papers')
      .select('id, title, authors, source, chunk_count')
      .order('imported_at', { ascending: false });

    const mergeTarget = findBestMatch(title, parsed.authors || [], allPapers || []);

    // 按章節切分全文
    const sections = sliceBySections(full_text, parsed.section_markers || []);

    let paperId: string;
    let isMerge = false;

    if (mergeTarget) {
      // MERGE: 更新既有 paper (保留 ndltd 權威 metadata，補上全文 + chunks)
      isMerge = true;
      paperId = mergeTarget.id;

      // 先刪舊 chunks (若有)
      await userClient.from('paper_chunks').delete().eq('paper_id', paperId);

      // 更新 paper：保留舊 title/authors/year/venue 若 ndltd 來源；補全文欄位
      const updates: Record<string, unknown> = {
        full_text_length: full_text.length,
        import_status: 'fulltext_ready',
        source: mergeTarget.source === 'ndltd' ? 'ndltd+pdf' : (mergeTarget.source || 'pdf_upload'),
      };
      // 若既有欄位是空的，用新 parse 的補上
      if (parsed.abstract && parsed.abstract.length > 100) updates.abstract = parsed.abstract;
      if (parsed.keywords && parsed.keywords.length > 0) updates.keywords = parsed.keywords;

      const { error: updateErr } = await userClient
        .from('academic_papers')
        .update(updates)
        .eq('id', paperId);
      if (updateErr) throw updateErr;
    } else {
      // 新建 paper
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
      paperId = paper.id;
    }

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
      merged: isMerge,
      merge_target_title: isMerge ? mergeTarget?.title : undefined,
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
