"""
MOJ 詳細頁 404 待複查佇列的收尾判定（2026-11-16）

背景：每週 sweep 對已知雜湊 GET 詳細頁，404 → page_hash_missing_at（不等於除名）。
人工在官網查「所在區段的前綴」（收成頁「建議手動補跑」分頁，moj_query_plan.py 產）之後：
  - 人還在名冊 → 收成列帶新雜湊，moj_harvest_ingest.py 寫回並清 page_hash_missing_at（不歸本腳本管）
  - 人不在結果裡 → 本腳本判定「推定除名」，從複查佇列移除

判定推定除名要三個條件同時成立：
  1. 所在區段的前綴查詢，在 404 之後有一次成功的收成（received > 0，代表查法沒問題、查得到鄰號）
  2. 404 之後的收成列裡沒有這個證號
  3. 現在用舊雜湊再 GET 一次詳細頁仍是 404（0 byte）；連線問題或 200 都不標
成立 → deregistered_at=now、state_desc 改「名冊查無（推定除名）」（沿用 mig 079 慣例，
trigger 自動記 state_change 進 moj_lawyer_changes）。之後 sweep 或收成又查得到會自動解除。

用法:
  python moj_missing_resolve.py            # 判定並寫入
  python moj_missing_resolve.py --dry-run  # 只印判定
"""
import sys
from collections import defaultdict
from datetime import datetime, timezone

import requests

import moj_detail_page as mdp
import moj_query_plan as plan
from moj_licno_norm import lic_triple
from moj_office_refresh import patch_lawyer  # 變動由 trigger 記入 moj_lawyer_changes

DEREG_STATE = '名冊查無（推定除名）'


def sb_get(table, params):
    r = requests.get(f'{plan.SUPABASE_URL}/rest/v1/{table}', headers=plan.HEADERS_SB, params=params, timeout=60)
    r.raise_for_status()
    return r.json()


def main(dry_run=False):
    rows = plan.load_lawyers()
    queue = plan.missing_queue(rows)
    print(f'404 待複查佇列：{len(queue)} 位')
    if not queue:
        return
    queries, _ = plan.full_queries(rows)
    sess, throttle = mdp.new_session(), mdp.Throttle(1.0)
    now_iso = datetime.now(timezone.utc).isoformat()
    stat, marked = defaultdict(int), []

    for r in queue:
        lic, since = r['lic_no'], r['page_hash_missing_at']
        q = plan.covering_query(lic, queries)
        if not q:
            stat['證號格式異常，沒有對應區段（人工看）'] += 1
            continue
        ok_submit = sb_get('moj_harvest_queries', {
            'select': 'submitted_at,received', 'query': f'eq.{q}', 'submitted_at': f'gt.{since}',
            'received': 'gt.0', 'order': 'submitted_at.desc', 'limit': '1'})
        if not ok_submit:
            stat['區段還沒重查（等人工補跑）'] += 1
            continue
        got = sb_get('moj_search_harvest', {
            'select': 'lic_no', 'query': f'eq.{q}', 'harvested_at': f'gt.{since}', 'limit': '1000'})
        if any(lic_triple(g['lic_no']) == lic_triple(lic) for g in got):
            stat['區段重查有收到本人（等 ingest 寫回新雜湊）'] += 1
            continue
        st, _, note, _ = mdp.fetch_detail_retry(r['page_hash'], sess, throttle) if r.get('page_hash') \
            else ('missing', None, '', None)
        if st == 'ok':
            stat['詳細頁又查得到（下次 sweep 會清 404 記號）'] += 1
            continue
        if st != 'missing':
            stat['詳細頁連線問題，這次不判'] += 1
            continue
        if dry_run or patch_lawyer(lic, {'deregistered_at': now_iso, 'state_desc': DEREG_STATE}):
            stat['推定除名'] += 1
            marked.append(f'{lic}（區段「{q}」{ok_submit[0]["submitted_at"][:10]} 收 {ok_submit[0]["received"]} 筆，本人不在其中）')
        else:
            stat['寫入失敗'] += 1

    print('\n=== 判定結果 ===' + ('（--dry-run，未寫入）' if dry_run else ''))
    for k, v in sorted(stat.items(), key=lambda kv: -kv[1]):
        print(f'  {k}: {v}')
    if marked:
        print('\n推定除名（區段查得到鄰號、本人不在、詳細頁仍 404）：')
        for ln in marked:
            print(f'  {ln}')
    if stat['寫入失敗']:
        sys.exit(1)


if __name__ == '__main__':
    if sys.platform == 'win32':
        sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')
    main(dry_run='--dry-run' in sys.argv[1:])
