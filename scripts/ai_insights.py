"""
AI 市場洞察產出器
使用 Claude API 分析產業資料，產出週報和趨勢分析
"""
import os
from datetime import datetime, timedelta
import anthropic
from utils import get_supabase, log, scrape_start, scrape_end

ANTHROPIC_API_KEY = os.environ.get('ANTHROPIC_API_KEY', '')


def get_recent_data(sb):
    """取得最近一週的資料摘要"""
    one_week_ago = (datetime.now() - timedelta(days=7)).isoformat()

    # 最新公會統計
    stats = sb.table('industry_stats').select('*').order(
        'created_at', desc=True
    ).limit(20).execute()

    # 最近新聞
    news = sb.table('news_articles').select(
        'title, source_name, published_at'
    ).gte('published_at', one_week_ago).order(
        'published_at', desc=True
    ).limit(30).execute()

    # 律師總數
    lawyer_count = sb.table('industry_lawyers').select(
        '*', count='exact', head=True
    ).eq('status', 'active').execute()

    # 事務所數
    firm_count = sb.table('law_firms').select(
        '*', count='exact', head=True
    ).eq('status', 'active').execute()

    return {
        'stats': stats.data or [],
        'news': news.data or [],
        'lawyer_count': lawyer_count.count or 0,
        'firm_count': firm_count.count or 0,
    }


def generate_weekly_summary(data):
    """使用 Claude 產出週報"""
    if not ANTHROPIC_API_KEY:
        log('ANTHROPIC_API_KEY 未設定，跳過 AI 分析')
        return None

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    # 組合資料摘要
    stats_text = ''
    for s in data['stats'][:10]:
        stats_text += f"- {s.get('stat_type')}: {s.get('value')} {s.get('unit', '')} ({s.get('region', '全國')}, {s.get('year')}年)\n"

    news_text = ''
    for n in data['news'][:15]:
        news_text += f"- {n['title']} ({n.get('source_name', '未知')})\n"

    prompt = f"""你是一位台灣法律產業分析師。請根據以下最新資料，撰寫一份簡潔的台灣法律產業週報。

## 產業數據
- 執業律師總數: {data['lawyer_count']} 人
- 事務所總數: {data['firm_count']} 家
{stats_text}

## 本週法律產業新聞
{news_text if news_text else '（本週暫無新聞）'}

## 請撰寫週報，包含：
1. 本週產業重點摘要 (3-5 句話)
2. 值得關注的趨勢或變化
3. 對法律事務所經營者的建議

請用繁體中文撰寫，語氣專業但易讀。不需要標題，直接開始內容。限制在 500 字以內。"""

    log('呼叫 Claude API 產出週報...')
    response = client.messages.create(
        model='claude-sonnet-4-20250514',
        max_tokens=1000,
        messages=[{'role': 'user', 'content': prompt}]
    )

    content = response.content[0].text
    log(f'AI 回應完成 ({response.usage.input_tokens} input, {response.usage.output_tokens} output tokens)')

    return {
        'insight_type': 'weekly_summary',
        'title': f'台灣法律產業週報 - {datetime.now().strftime("%Y/%m/%d")}',
        'content': content,
        'data_range_start': (datetime.now() - timedelta(days=7)).date().isoformat(),
        'data_range_end': datetime.now().date().isoformat(),
        'model_used': 'claude-sonnet-4-20250514',
    }


def save_insight(sb, insight):
    """儲存 AI 分析到 Supabase"""
    if not insight:
        return 0

    sb.table('ai_insights').insert(insight).execute()
    log(f'已儲存分析: {insight["title"]}')
    return 1


def main():
    sb = get_supabase()
    log_id = scrape_start(sb, 'ai_insights')

    try:
        # 取得最近資料
        data = get_recent_data(sb)
        log(f'資料摘要: {data["lawyer_count"]} 位律師, '
            f'{data["firm_count"]} 家事務所, '
            f'{len(data["news"])} 則新聞')

        # 產出週報
        insight = generate_weekly_summary(data)
        count = save_insight(sb, insight)

        scrape_end(sb, log_id, status='success',
                   records_found=1,
                   records_inserted=count)

        log('=== AI 分析完成 ===')

    except Exception as e:
        log(f'AI 分析錯誤: {e}')
        scrape_end(sb, log_id, status='error', error_message=str(e)[:500])
        raise


if __name__ == '__main__':
    main()
