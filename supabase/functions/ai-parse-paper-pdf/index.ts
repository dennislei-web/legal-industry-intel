// ============================================================
// ai-parse-paper-pdf Edge Function (v4 - 強制 merge 模式)
// ============================================================
// 新流程：
//   1. 前端指定 target_paper_id（哪篇骨架要升級）
//   2. 前端用 pdfjs 抽全文 full_text 送來
//   3. 本 function 不呼叫 Claude，純用 regex 切章節
//   4. 刪除舊 chunks，插新 chunks，更新 academic_papers
// 好處：100% 準確、零 AI 費用、速度快
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

const CHUNK_SIZE = 1500;
const SECTION_MAX = 4500;  // 章節若短於這個值，整段當一個 chunk；長於則細切

// 用 regex 找台灣論文常見章節標題
// e.g., "第一章 緒論", "第二章", "摘要", "Abstract", "參考文獻"
function detectSections(fullText: string): Array<{ title: string; start: number }> {
  const markers: Array<{ title: string; start: number }> = [];
  // 中文章節
  const chapterRe = /(?:^|\n)\s*(第[一二三四五六七八九十]{1,2}章[^\n]{0,40})/g;
  let m;
  while ((m = chapterRe.exec(fullText)) !== null) {
    markers.push({ title: m[1].trim(), start: m.index + (m[0].length - m[1].length) });
  }
  // 常見特殊區塊
  const specialRe = /(?:^|\n)\s*(摘\s*要|Abstract|ABSTRACT|參考文獻|References|結\s*論|致\s*謝|誌\s*謝)(?=\s*\n|\s*$)/g;
  while ((m = specialRe.exec(fullText)) !== null) {
    markers.push({ title: m[1].replace(/\s+/g, '').trim(), start: m.index });
  }
  // 按位置排序 + 去重 (同位置保留第一個)
  markers.sort((a, b) => a.start - b.start);
  const dedup: Array<{ title: string; start: number }> = [];
  for (const mk of markers) {
    if (dedup.length === 0 || mk.start - dedup[dedup.length - 1].start > 100) {
      dedup.push(mk);
    }
  }
  return dedup;
}

function sliceFullText(fullText: string): Array<{ title: string; content: string }> {
  const markers = detectSections(fullText);
  if (markers.length === 0) {
    // Fallback: 按固定長度切
    const sections: Array<{ title: string; content: string }> = [];
    for (let i = 0; i < fullText.length; i += SECTION_MAX) {
      sections.push({
        title: `段落 ${sections.length + 1}`,
        content: fullText.slice(i, i + SECTION_MAX),
      });
    }
    return sections;
  }

  const sections: Array<{ title: string; content: string }> = [];
  // 若第一個章節前有內容（封面 + 目次），也加進去
  if (markers[0].start > 200) {
    sections.push({
      title: '封面與前置',
      content: fullText.slice(0, markers[0].start).trim(),
    });
  }
  for (let i = 0; i < markers.length; i++) {
    const start = markers[i].start;
    const end = i + 1 < markers.length ? markers[i + 1].start : fullText.length;
    const content = fullText.slice(start, end).trim();
    if (content.length >= 50) {
      sections.push({ title: markers[i].title, content });
    }
  }
  return sections;
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
    // JWT decode
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

    const { target_paper_id, full_text, pages_count, file_name } = await req.json();
    if (!target_paper_id) return err('target_paper_id is required');
    if (!full_text || typeof full_text !== 'string') return err('full_text is required');
    if (full_text.length < 200) return err('full_text too short (< 200 chars)');

    // 檢查 target paper 存在且屬於當前使用者
    const { data: target, error: targetErr } = await userClient
      .from('academic_papers')
      .select('id, title')
      .eq('id', target_paper_id)
      .maybeSingle();
    if (targetErr || !target) return err('target paper not found', 404);

    // 1. 刪除舊 chunks
    await userClient.from('paper_chunks').delete().eq('paper_id', target_paper_id);

    // 2. 切章節
    const sections = sliceFullText(full_text);

    // 3. 轉成 chunks
    const chunkRecords: Array<Record<string, unknown>> = [];
    let idx = 0;
    for (const sec of sections) {
      if (!sec.content || sec.content.length < 50) continue;
      if (sec.content.length <= CHUNK_SIZE) {
        chunkRecords.push({
          paper_id: target_paper_id,
          chunk_index: idx++,
          section: sec.title,
          content: sec.content,
          char_count: sec.content.length,
        });
      } else {
        const subs = sliceIntoChunks(sec.content, CHUNK_SIZE);
        for (let si = 0; si < subs.length; si++) {
          chunkRecords.push({
            paper_id: target_paper_id,
            chunk_index: idx++,
            section: `${sec.title} (${si + 1}/${subs.length})`,
            content: subs[si],
            char_count: subs[si].length,
          });
        }
      }
    }

    // 4. Batch insert chunks
    if (chunkRecords.length > 0) {
      const BATCH = 50;
      for (let i = 0; i < chunkRecords.length; i += BATCH) {
        const batch = chunkRecords.slice(i, i + BATCH);
        const { error: chunkErr } = await userClient.from('paper_chunks').insert(batch);
        if (chunkErr) {
          console.warn('chunk insert error:', chunkErr);
          return err(`chunk insert failed: ${chunkErr.message}`, 500);
        }
      }
    }

    // 5. 更新 paper metadata
    await userClient
      .from('academic_papers')
      .update({
        chunk_count: chunkRecords.length,
        full_text_length: full_text.length,
        import_status: 'fulltext_ready',
      })
      .eq('id', target_paper_id);

    return json({
      paper_id: target_paper_id,
      title: target.title,
      chunk_count: chunkRecords.length,
      full_text_length: full_text.length,
      pages_count,
      sections_detected: sections.length,
      merged: true,
    });
  } catch (e) {
    console.error('ai-parse-paper-pdf error:', e);
    return err(String((e as Error)?.message ?? e), 500);
  }
});
