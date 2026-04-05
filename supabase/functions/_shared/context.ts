import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

/**
 * 組出使用者「個人知識庫」的 context 字串，給 Claude 當作 system prompt 的一部分。
 * 包含：最近筆記、最近搜尋過的新聞、上傳檔案摘要、DB 統計。
 *
 * 回傳 context 字串 + sources 清單（給前端顯示來源標記用）。
 */
export interface ContextPayload {
  context: string;
  sources: Array<{ type: 'note' | 'news' | 'upload' | 'db'; id?: string; title: string }>;
}

export async function buildUserContext(
  userClient: SupabaseClient,
  serviceClient: SupabaseClient,
): Promise<ContextPayload> {
  const sources: ContextPayload['sources'] = [];
  const parts: string[] = [];

  // ========= 1. 使用者筆記（最多 50 筆） =========
  const { data: notes } = await userClient
    .from('manual_notes')
    .select('id, title, content, category, tags, source_type, source_url, created_at')
    .order('created_at', { ascending: false })
    .limit(50);

  if (notes && notes.length > 0) {
    parts.push('## 使用者的研究筆記（時間由新到舊）');
    for (const n of notes) {
      const tagStr = n.tags?.length ? ` [${n.tags.join(', ')}]` : '';
      const srcType = n.source_type && n.source_type !== 'manual' ? ` (${n.source_type})` : '';
      const content = (n.content || '').slice(0, 500);
      parts.push(`### ${n.title}${tagStr}${srcType}`);
      parts.push(`_類別: ${n.category || 'general'}, 建立: ${n.created_at?.slice(0, 10)}_`);
      if (content) parts.push(content);
      if (n.source_url) parts.push(`來源: ${n.source_url}`);
      parts.push('');
      sources.push({ type: 'note', id: n.id, title: n.title });
    }
  }

  // ========= 2. 最近搜尋過的新聞（最多 30 筆） =========
  const { data: news } = await userClient
    .from('news_articles')
    .select('id, title, summary, source_name, published_at, url, search_query')
    .order('published_at', { ascending: false })
    .limit(30);

  if (news && news.length > 0) {
    parts.push('## 最近的產業新聞');
    for (const a of news) {
      const date = a.published_at?.slice(0, 10) || '';
      parts.push(`- **${a.title}** (${a.source_name || '未知來源'}, ${date})`);
      if (a.summary) parts.push(`  ${a.summary.slice(0, 300)}`);
      sources.push({ type: 'news', id: a.id, title: a.title });
    }
    parts.push('');
  }

  // ========= 3. 上傳檔案摘要（最多 20 筆） =========
  const { data: uploads } = await userClient
    .from('user_uploads')
    .select('id, file_name, data_type, description, row_count, created_at')
    .order('created_at', { ascending: false })
    .limit(20);

  if (uploads && uploads.length > 0) {
    parts.push('## 使用者上傳的資料檔');
    for (const u of uploads) {
      parts.push(`- 📄 ${u.file_name} (${u.data_type}, ${u.row_count || '?'} 筆) - ${u.description || ''}`);
      sources.push({ type: 'upload', id: u.id, title: u.file_name });
    }
    parts.push('');
  }

  // ========= 4. DB 統計（service client，跨使用者可讀） =========
  try {
    const { count: lawyerCount } = await serviceClient
      .from('moj_lawyers')
      .select('lic_no', { count: 'exact', head: true });

    const { data: topFirms } = await serviceClient.rpc('moj_firm_statistics');
    const { data: regions } = await serviceClient.rpc('moj_region_distribution');

    parts.push('## 台灣法律產業 DB 即時數據（來自法務部）');
    if (lawyerCount) parts.push(`- 登錄律師總數: ${lawyerCount.toLocaleString()} 位`);
    if (topFirms && topFirms.length > 0) {
      parts.push(`- 事務所總數: ${topFirms.length} 間`);
      parts.push('- Top 10 事務所:');
      for (const f of topFirms.slice(0, 10)) {
        parts.push(`  * ${f.firm_name}: ${f.lawyer_count} 位律師 (${f.main_region || '-'})`);
      }
    }
    if (regions && regions.length > 0) {
      parts.push('- 律師地區分布:');
      for (const r of regions.slice(0, 10)) {
        parts.push(`  * ${r.region}: ${r.count} 位`);
      }
    }
    sources.push({ type: 'db', title: 'MOJ 律師/事務所資料庫' });
  } catch (e) {
    console.warn('DB stats fetch failed:', e);
  }

  return {
    context: parts.join('\n'),
    sources,
  };
}

export const SYSTEM_PROMPT = `你是一位專業的台灣法律產業分析師，協助使用者深入理解法律市場動態、事務所競爭、律師職涯趨勢等議題。

你擁有使用者專屬的知識庫作為 context（包含他們的研究筆記、追蹤的新聞、上傳資料、以及即時的 MOJ 律師資料庫）。你的回答應該：

1. **優先引用使用者的筆記與資料** — 使用者累積的觀察是最重要的分析基礎
2. **善用 web_search 工具** — 當問題涉及最新動態、市場消息、併購、新政策時，主動線上搜尋
3. **結合 DB 數據佐證** — 事務所規模、律師地區分布等議題引用具體數字
4. **繁體中文回答** — 專業但易讀，適當使用 Markdown 格式（標題、列表、粗體）
5. **明確標註資料來源** — 讓使用者知道結論是來自他的筆記、新聞、還是網路搜尋

如果使用者的筆記中有相關內容，直接引用並加註「根據你之前記錄的...」。
如果筆記不足以回答，使用 web_search 工具搜尋最新資料。`;
