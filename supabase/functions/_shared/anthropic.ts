/**
 * 共用的 Anthropic Claude 呼叫 wrapper，支援 web_search tool 迭代。
 */

const ANTHROPIC_API = 'https://api.anthropic.com/v1/messages';
const MODEL = 'claude-sonnet-4-5';  // Claude Sonnet 4.5
const FAST_MODEL = 'claude-haiku-4-5';  // 用於生成 session title 等輕量任務

export interface Message {
  role: 'user' | 'assistant';
  content: string | Array<Record<string, unknown>>;
}

export interface ClaudeCallOptions {
  system: string;
  messages: Message[];
  maxTokens?: number;
  enableWebSearch?: boolean;
  enableWebFetch?: boolean;
  model?: string;
}

export interface ClaudeResult {
  text: string;
  inputTokens: number;
  outputTokens: number;
  toolUses: Array<{ tool: string; input: unknown; result?: unknown }>;
}

/**
 * 呼叫 Claude API 並處理 tool_use loop（web_search / web_fetch）。
 * Claude 的 server-side tools（web_search、web_fetch）會由 Anthropic 自行執行，
 * 我們只需要一次呼叫就能拿到最終結果。
 */
export async function callClaude(opts: ClaudeCallOptions): Promise<ClaudeResult> {
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) throw new Error('ANTHROPIC_API_KEY not set');

  const tools: Array<Record<string, unknown>> = [];
  if (opts.enableWebSearch) {
    tools.push({
      type: 'web_search_20250305',
      name: 'web_search',
      max_uses: 5,
    });
  }
  if (opts.enableWebFetch) {
    tools.push({
      type: 'web_fetch_20250910',
      name: 'web_fetch',
      max_uses: 3,
    });
  }

  const body: Record<string, unknown> = {
    model: opts.model ?? MODEL,
    max_tokens: opts.maxTokens ?? 4096,
    system: opts.system,
    messages: opts.messages,
  };
  if (tools.length > 0) {
    body.tools = tools;
    // web_fetch 需要 beta header
    if (opts.enableWebFetch) {
      body.betas = ['web-fetch-2025-09-10'];
    }
  }

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
  };
  if (opts.enableWebFetch) {
    headers['anthropic-beta'] = 'web-fetch-2025-09-10';
  }

  const resp = await fetch(ANTHROPIC_API, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Claude API ${resp.status}: ${errText}`);
  }

  const data = await resp.json();

  // 組最終文字：合併所有 text 區塊
  let text = '';
  const toolUses: ClaudeResult['toolUses'] = [];
  for (const block of data.content || []) {
    if (block.type === 'text') {
      text += block.text;
    } else if (block.type === 'server_tool_use') {
      toolUses.push({ tool: block.name, input: block.input });
    } else if (block.type === 'web_search_tool_result' || block.type === 'web_fetch_tool_result') {
      // Attach result to latest tool use
      if (toolUses.length > 0) {
        toolUses[toolUses.length - 1].result = block.content;
      }
    }
  }

  return {
    text,
    inputTokens: data.usage?.input_tokens ?? 0,
    outputTokens: data.usage?.output_tokens ?? 0,
    toolUses,
  };
}

/**
 * 快速呼叫 Haiku 做 session title 生成等輕量任務。
 */
export async function callClaudeFast(prompt: string): Promise<string> {
  const result = await callClaude({
    system: '你是幫手，請用 15 字以內的簡短繁體中文回答，直接給結果不要解釋。',
    messages: [{ role: 'user', content: prompt }],
    maxTokens: 100,
    model: FAST_MODEL,
  });
  return result.text.trim();
}
