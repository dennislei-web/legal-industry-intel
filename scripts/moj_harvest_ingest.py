"""
人工查詢收成 → moj_lawyers.page_hash（MOJ 新站名冊管線第二步）

moj_search_harvest 由書籤助手寫入（同仁在官網自己打驗證碼查詢，助手只收頁面上已顯示的結果）。
本腳本把尚未 ingest 的列以證號對上 moj_lawyers：

  對上（證號三元組相同；臺檢證／臺證／補證另可用「類型＋編號」備援）且姓名相同
      → 寫 page_hash（已有不同雜湊＝雜湊重發，改寫新值並記錄）、清 page_hash_missing_at
  對不上 → 新律師：先 GET 該雜湊的詳細頁，頁面證號與收成資料一致才插入（以頁面內容為準，
      欄位轉換沿用 moj_licno_scan.to_lawyer_record；trigger 會記 new_lawyer 進異動追蹤）。
      收成表 anon 可寫，這一步擋掉假資料。
  同證號多筆／姓名不同／頁面驗證不過 → 不寫、留在佇列（ingested_at 維持空），印證號給人看

處理完的列標 ingested_at。證號比對用 moj_licno_norm（台→臺、去括號、補零）。

用法:
  python moj_harvest_ingest.py              # 正式跑
  python moj_harvest_ingest.py --dry-run    # 只比對、不寫
  python moj_harvest_ingest.py --no-new     # 不插入新律師（只寫已知律師的雜湊）
"""
import os
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

import moj_detail_page as mdp  # noqa: E402
from moj_licno_norm import lic_triple, num_key  # noqa: E402
from moj_licno_scan import to_lawyer_record, upload_batch  # noqa: E402
from moj_office_refresh import patch_lawyer  # noqa: E402

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}


def sb_get_all(path):
    out, offset = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        r = requests.get(f'{SUPABASE_URL}/rest/v1/{path}{sep}offset={offset}&limit=1000',
                         headers=HEADERS_SB, timeout=60)
        r.raise_for_status()
        rows = r.json()
        out.extend(rows)
        if len(rows) < 1000:
            return out
        offset += 1000


def mark_ingested(ids, now_iso):
    ok = True
    for i in range(0, len(ids), 100):
        part = ids[i:i + 100]
        r = requests.patch(f'{SUPABASE_URL}/rest/v1/moj_search_harvest?id=in.({",".join(map(str, part))})',
                           json={'ingested_at': now_iso},
                           headers={**HEADERS_SB, 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                           timeout=30)
        if r.status_code not in (200, 204):
            print(f'  ! 標記 ingested_at 失敗 {r.status_code}: {r.text[:200]}', flush=True)
            ok = False
    return ok


def build_index(lawyers):
    by_triple, by_num, by_hash = defaultdict(list), defaultdict(list), {}
    for r in lawyers:
        t = lic_triple(r['lic_no'])
        if t:
            by_triple[t].append(r)
            k = num_key(t)
            if k:
                by_num[k].append(r)
        if r.get('page_hash'):
            by_hash[r['page_hash'].lower()] = r
    return by_triple, by_num, by_hash


def match(h, by_triple, by_num):
    """回傳 (row 或 None, reason)"""
    t = lic_triple(h.get('lic_no'))
    if not t:
        return None, 'bad_lic'
    cands = by_triple.get(t) or []
    if not cands:
        k = num_key(t)
        cands = by_num.get(k, []) if k else []
    if not cands:
        return None, 'new'
    if len(cands) > 1:
        named = [c for c in cands if c.get('name') == h.get('name')]
        if len(named) != 1:
            return None, 'ambiguous'
        cands = named
    if h.get('name') and cands[0].get('name') != h['name']:
        return None, 'name_mismatch'
    return cands[0], 'ok'


def record_from_page(h, f):
    """詳細頁欄位 → moj_lawyers 新列（轉換沿用 to_lawyer_record 的舊 API 欄位名）"""
    data = {
        'name': mdp.clean_text(f.get('name')) or h.get('name') or '',
        'sex': mdp.clean_text(f.get('sex')),
        'office': mdp.page_office(f),
        'guild_name': mdp.page_guilds(f),
        'birthsday': mdp.page_birth_year(f),
        'statedesc': mdp.clean_text(f.get('state_desc')),
        'email': mdp.clean_text(f.get('email')),
        'tel': mdp.clean_text(f.get('tel')),
        'addr': mdp.clean_text(f.get('address')),
        'discipline': mdp.clean_text(f.get('discipline')),
    }
    rec = to_lawyer_record(f['lic_no'], data)
    rec.pop('raw_data', None)  # 新站沒有舊 API 的原始 JSON；不把頁面解析結果（含聯絡方式）重複存一份
    now_iso = datetime.now(timezone.utc).isoformat()
    rec.update({
        'english_name': mdp.clean_text(f.get('english_name')),
        'moj_mk_date': mdp.page_date(f, 'mk_date'),
        'moj_ut_date': mdp.page_date(f, 'ut_date'),
        'page_hash': h['id_no'],
        'page_checked_at': now_iso,
        'detail_fetched_at': now_iso,
    })
    return rec


def main(dry_run=False, allow_new=True):
    print('[1/3] 載入待處理收成列與名冊...')
    pending = sb_get_all('moj_search_harvest?select=id,name,lic_no,office,guild_name,id_no,query'
                         '&ingested_at=is.null&order=id')
    print(f'  待處理收成列 {len(pending):,} 筆')
    if not pending:
        print('沒有待處理的收成列。')
        return
    lawyers = sb_get_all('moj_lawyers?select=lic_no,name,page_hash,page_hash_missing_at&order=lic_no')
    by_triple, by_num, by_hash = build_index(lawyers)
    print(f'  名冊 {len(lawyers):,} 位（已有雜湊 {len(by_hash):,}）')

    print('[2/3] 比對...')
    now_iso = datetime.now(timezone.utc).isoformat()
    done_ids, stat, review = [], defaultdict(int), []
    new_recs, sess, throttle = [], mdp.new_session(), mdp.Throttle(1.0)
    seen_hash = {}

    for h in pending:
        hid = h['id_no'].lower()
        if hid in seen_hash:  # 同一雜湊同批出現多次（不同查詢都查到）
            stat['同批重複'] += 1
            done_ids.append(h['id'])
            continue
        seen_hash[hid] = h
        row, reason = match(h, by_triple, by_num)

        if reason == 'ok':
            holder = by_hash.get(hid)
            if holder and holder['lic_no'] != row['lic_no']:
                stat['雜湊已掛在別人身上'] += 1
                review.append((h['lic_no'], f'雜湊已屬 {holder["lic_no"]}'))
                continue
            if (row.get('page_hash') or '').lower() == hid and not row.get('page_hash_missing_at'):
                stat['已有相同雜湊'] += 1
                done_ids.append(h['id'])
                continue
            changed = bool(row.get('page_hash')) and row['page_hash'].lower() != hid
            if dry_run or patch_lawyer(row['lic_no'], {'page_hash': h['id_no'], 'page_hash_missing_at': None}):
                stat['雜湊重發（改寫新值）' if changed else '寫入雜湊'] += 1
                if changed:
                    review.append((row['lic_no'], '雜湊重發：舊值已覆蓋'))
                by_hash[hid] = row
                done_ids.append(h['id'])
            else:
                stat['寫入失敗'] += 1
        elif reason == 'new':
            if not allow_new:
                stat['新律師（--no-new 略過）'] += 1
                continue
            throttle.wait()
            st, f, note = mdp.fetch_detail(h['id_no'], sess)
            if st != 'ok':
                stat['新律師：詳細頁讀不到'] += 1
                review.append((h['lic_no'], f'新律師，詳細頁 {st} {note}'.strip()))
                continue
            if lic_triple(f.get('lic_no')) != lic_triple(h['lic_no']):
                stat['新律師：頁面證號不符'] += 1
                review.append((h['lic_no'], '新律師，詳細頁證號與收成資料不符（疑似假資料）'))
                continue
            new_recs.append((h['id'], record_from_page(h, f)))
        else:
            label = {'ambiguous': '同證號多筆', 'name_mismatch': '姓名不同', 'bad_lic': '證號無法解析'}[reason]
            stat[label] += 1
            review.append((h.get('lic_no') or '(空)', label))

    print('[3/3] 寫入...')
    if new_recs:
        recs = [r for _, r in new_recs]
        if dry_run:
            stat['新律師插入'] += len(recs)
            done_ids.extend(i for i, _ in new_recs)
        else:
            ok_lics = set()
            for i in range(0, len(recs), 50):
                ok_lics |= upload_batch(recs[i:i + 50])
                time.sleep(2)
            for hid_, rec in new_recs:
                if rec['lic_no'] in ok_lics:
                    stat['新律師插入'] += 1
                    done_ids.append(hid_)
                else:
                    stat['新律師插入失敗'] += 1
    if done_ids and not dry_run:
        mark_ingested(done_ids, now_iso)

    print('\n=== 完成 ===' + ('（--dry-run，未寫入）' if dry_run else ''))
    for k, v in sorted(stat.items(), key=lambda kv: -kv[1]):
        print(f'  {k}: {v}')
    print(f'  標記已處理: {len(done_ids)} 筆；留在佇列: {len(pending) - len(done_ids)} 筆')
    if review:
        print('\n需人工確認（證號）：')
        for lic, why in review[:50]:
            print(f'  - {lic}：{why}')
        if len(review) > 50:
            print(f'  …另 {len(review) - 50} 筆')
    if stat.get('新律師插入'):
        print('\n提醒：有新律師入庫，可呼叫 refresh_firm_stats_cache RPC 更新事務所人數快取')


if __name__ == '__main__':
    a = sys.argv[1:]
    main(dry_run='--dry-run' in a, allow_new='--no-new' not in a)
