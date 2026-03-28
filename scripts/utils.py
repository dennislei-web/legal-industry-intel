"""
共用工具模組 - Supabase client、爬蟲日誌、批次寫入
"""
import os
import sys
import time
from datetime import datetime, timezone
from dotenv import load_dotenv
from supabase import create_client

# Windows UTF-8 stdout
if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

load_dotenv()

SUPABASE_URL = os.environ['SUPABASE_URL']
SUPABASE_SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY']


def get_supabase():
    """取得 Supabase client (service role, 繞過 RLS)"""
    return create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)


def log(msg):
    """印出帶時間戳的訊息"""
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{ts}] {msg}")


def scrape_start(sb, scraper_name):
    """建立爬蟲日誌，回傳 log_id"""
    result = sb.table('scrape_logs').insert({
        'scraper_name': scraper_name,
        'status': 'running'
    }).execute()
    log_id = result.data[0]['id']
    log(f"爬蟲 {scraper_name} 開始 (log_id={log_id})")

    # 更新 data_sources 的 last_scraped_at
    sb.table('data_sources').update({
        'last_scraped_at': datetime.now(timezone.utc).isoformat()
    }).eq('scraper_name', scraper_name).execute()

    return log_id


def scrape_end(sb, log_id, status='success', records_found=0,
               records_inserted=0, records_updated=0, error_message=None):
    """更新爬蟲日誌"""
    sb.table('scrape_logs').update({
        'finished_at': datetime.now(timezone.utc).isoformat(),
        'status': status,
        'records_found': records_found,
        'records_inserted': records_inserted,
        'records_updated': records_updated,
        'error_message': error_message
    }).eq('id', log_id).execute()
    log(f"爬蟲結束: status={status}, found={records_found}, "
        f"inserted={records_inserted}, updated={records_updated}")


def upsert_batch(sb, table, records, conflict_column, batch_size=100):
    """批次 upsert，回傳 (inserted, updated) 計數"""
    inserted = 0
    updated = 0

    for i in range(0, len(records), batch_size):
        batch = records[i:i + batch_size]

        # 先查詢已存在的記錄
        existing_values = [r[conflict_column] for r in batch if r.get(conflict_column)]
        existing_ids = set()
        if existing_values:
            result = sb.table(table).select(conflict_column).in_(conflict_column, existing_values).execute()
            existing_ids = {r[conflict_column] for r in result.data}

        # 計算新增和更新
        for r in batch:
            if r.get(conflict_column) in existing_ids:
                updated += 1
            else:
                inserted += 1

        # Upsert
        sb.table(table).upsert(batch, on_conflict=conflict_column).execute()

        if i + batch_size < len(records):
            time.sleep(0.5)  # 避免 rate limit

    return inserted, updated


def polite_delay(seconds=1.5):
    """禮貌延遲，避免過度請求"""
    time.sleep(seconds)
