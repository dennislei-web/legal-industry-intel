"""職安署「職場霸凌調查專業人士資料庫」每日同步 → wbie_experts / wbie_sync_log

資料源：https://etms.osha.gov.tw/wbie/ExpertSearch/GetQualifiedExperts
（單一 GET 回傳全量 JSON；篩選全在前端做，無分頁、無 token。先 GET 查詢頁拿
 session cookie 再打 API，比照瀏覽器行為。）

流程：抓全量 → 筆數防呆（異常縮水 exit 2，不動 DB）→ upsert ＋ diff
（新入庫/移除/資料異動）→ 喆律/競品旗標（名單讀 DB 的 wbie_watchlist，
 repo 是 public 不可硬編碼）→ is_lawyer（MOJ 名冊姓名比對）→ 寫 wbie_sync_log。

用法：
  python wbie_sync.py         # 完整同步
  python wbie_sync.py --dry   # 只抓取＋diff，不寫 DB
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))

# .env fallback（本機執行用；CI 直接給環境變數）
if 'SUPABASE_URL' not in os.environ:
    env_path = os.path.join(HERE, '.env')
    if os.path.exists(env_path):
        for line in open(env_path, encoding='utf-8-sig'):
            line = line.strip().lstrip('﻿')
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                os.environ.setdefault(k.strip(), v.strip())

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SUPABASE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()

WBIE_BASE = 'https://etms.osha.gov.tw/wbie/ExpertSearch'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

MIN_TOTAL = 500        # 全量低於此數視為抓取異常（2026-08 實測 1,040 筆）
MAX_DROP_PCT = 10      # 相比上次成功同步縮水超過 10% → exit 2

# 追蹤的異動欄位（diff 用）
DIFF_FIELDS = ['name', 'gender', 'identity', 'email', 'unit', 'title', 'phone', 'is_discount', 'areas']


def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


# ---------- PostgREST helpers（直打，避開 supabase-py 對 sb_secret key 的相容問題） ----------

def sb_req(method, path, body=None, headers=None):
    h = {'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {SUPABASE_KEY}',
         'Content-Type': 'application/json'}
    if headers:
        h.update(headers)
    data = json.dumps(body, ensure_ascii=False).encode('utf-8') if body is not None else None
    req = urllib.request.Request(f'{SUPABASE_URL}/rest/v1/{path}', data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        # 診斷只印 HTTP 狀態與回應 shape，不印 key/value 內容
        detail = e.read()[:300].decode('utf-8', 'replace')
        raise RuntimeError(f'PostgREST {method} {path.split("?")[0]} -> HTTP {e.code}: {detail}') from e


def sb_get_all(path_base, page_size=1000):
    """逐頁抓全量（PostgREST 單次上限 1000 列）"""
    out = []
    offset = 0
    sep = '&' if '?' in path_base else '?'
    while True:
        rows = sb_req('GET', f'{path_base}{sep}limit={page_size}&offset={offset}')
        out.extend(rows)
        if len(rows) < page_size:
            return out
        offset += page_size


# ---------- 抓官方名冊 ----------

def fetch_roster():
    """GET 查詢頁拿 cookie → GET GetQualifiedExperts 全量 JSON"""
    import http.cookiejar
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [('User-Agent', UA), ('Accept-Language', 'zh-TW,zh;q=0.9')]
    with opener.open(f'{WBIE_BASE}/SearchIndex', timeout=60):
        pass
    with opener.open(f'{WBIE_BASE}/GetQualifiedExperts', timeout=120) as resp:
        data = json.loads(resp.read().decode('utf-8-sig'))
    if not isinstance(data, list):
        raise RuntimeError(f'GetQualifiedExperts 回傳非陣列（type={type(data).__name__}）')
    return data


def to_row(e, today):
    return {
        'id': e['id'],
        'name': (e.get('name') or '').strip(),
        'gender': e.get('gender'),
        'identity': e.get('identity'),
        'email': e.get('email'),
        'unit': (e.get('unit') or '').strip() or None,
        'title': e.get('title'),
        'phone': e.get('phone'),
        'is_discount': e.get('isDiscount'),
        'areas': e.get('areas') or [],
        'last_seen': today,
        'removed_at': None,
        'raw': e,
    }


# ---------- 加值旗標 ----------

def load_watchlist():
    rows = sb_get_all('wbie_watchlist?select=category,name,firm_keyword,firm_label')
    zhelu_names = {r['name'] for r in rows if r['category'] == 'zhelu' and r.get('name')}
    comp = [(r['firm_keyword'], r.get('firm_label') or r['firm_keyword'])
            for r in rows if r['category'] == 'competitor' and r.get('firm_keyword')]
    return zhelu_names, comp


def apply_flags(rows, zhelu_names, comp):
    for r in rows:
        unit = r.get('unit') or ''
        r['is_zhelu'] = ('喆律' in unit) or (r['name'] in zhelu_names)
        r['is_competitor'] = False
        r['competitor_firm'] = None
        for kw, label in comp:
            if kw and kw in unit:
                r['is_competitor'] = True
                r['competitor_firm'] = label
                break


def mark_lawyers(rows):
    """與 MOJ 名冊姓名比對（同名視為律師，估計值）"""
    names = sorted({r['name'] for r in rows if r['name']})
    found = set()
    for i in range(0, len(names), 100):
        batch = names[i:i + 100]
        in_list = ','.join(f'"{n}"' for n in batch)
        q = urllib.parse.quote(f'({in_list})', safe='(),"')
        hits = sb_req('GET', f'moj_lawyers?select=name&name=in.{q}&limit=1000')
        found.update(h['name'] for h in hits)
    for r in rows:
        r['is_lawyer'] = r['name'] in found
    return found


# ---------- 主流程 ----------

def main():
    dry = '--dry' in sys.argv
    today = date.today().isoformat()

    log('抓取官方名冊…')
    raw = fetch_roster()
    total = len(raw)
    log(f'官方名冊 {total} 筆')

    if total < MIN_TOTAL:
        log(f'❌ 筆數 {total} < 下限 {MIN_TOTAL}，視為抓取異常，不動 DB')
        if not dry:
            sb_req('POST', 'wbie_sync_log', {
                'total_count': total, 'status': 'blocked',
                'error_message': f'total {total} < MIN_TOTAL {MIN_TOTAL}'})
        sys.exit(2)

    # 上次成功同步筆數防呆（比照 010 同步慣例）
    last = sb_req('GET', 'wbie_sync_log?status=eq.ok&order=created_at.desc&limit=1&select=total_count')
    if last:
        prev = last[0]['total_count']
        if prev and total < prev * (1 - MAX_DROP_PCT / 100):
            log(f'❌ 筆數 {total} 相比上次 {prev} 縮水逾 {MAX_DROP_PCT}%，不動 DB')
            if not dry:
                sb_req('POST', 'wbie_sync_log', {
                    'total_count': total, 'status': 'blocked',
                    'error_message': f'total {total} vs prev {prev}, drop > {MAX_DROP_PCT}%'})
            sys.exit(2)

    rows = [to_row(e, today) for e in raw]

    log('讀取觀察名單與現有資料…')
    zhelu_names, comp = load_watchlist()
    apply_flags(rows, zhelu_names, comp)
    mark_lawyers(rows)

    existing = {r['id']: r for r in sb_get_all(
        'wbie_experts?select=id,name,gender,identity,email,unit,title,phone,is_discount,areas,is_zhelu,competitor_firm,removed_at')}

    feed_ids = {r['id'] for r in rows}
    new_rows = [r for r in rows if r['id'] not in existing]
    upd_rows = [r for r in rows if r['id'] in existing]

    changed = []
    for r in upd_rows:
        old = existing[r['id']]
        diffs = {f: {'old': old.get(f), 'new': r.get(f)}
                 for f in DIFF_FIELDS if old.get(f) != r.get(f)}
        if diffs:
            changed.append({'id': r['id'], 'name': r['name'], 'diffs': diffs})

    removed = [{'id': i, 'name': e['name'], 'unit': e.get('unit')}
               for i, e in existing.items() if i not in feed_ids and not e.get('removed_at')]
    reappeared = [i for i in feed_ids if existing.get(i, {}).get('removed_at')]

    # 里程碑訊號
    milestones = []
    for r in new_rows:
        if r['is_zhelu']:
            milestones.append({'type': 'zhelu_joined', 'name': r['name'], 'unit': r['unit'],
                               'msg': f"🎉 喆律 {r['name']} 首次出現在官方名冊"})
        elif r['is_competitor']:
            milestones.append({'type': 'competitor_joined', 'name': r['name'],
                               'firm': r['competitor_firm'],
                               'msg': f"⚠️ 競品 {r['competitor_firm']} {r['name']} 入庫"})
    for x in removed:
        old = existing[x['id']]
        if old.get('is_zhelu'):
            milestones.append({'type': 'zhelu_removed', 'name': x['name'],
                               'msg': f"🚨 喆律 {x['name']} 從名冊消失"})
        elif old.get('competitor_firm'):
            milestones.append({'type': 'competitor_removed', 'name': x['name'],
                               'firm': old['competitor_firm'],
                               'msg': f"競品 {old['competitor_firm']} {x['name']} 從名冊消失"})

    zhelu_count = sum(1 for r in rows if r['is_zhelu'])
    comp_count = sum(1 for r in rows if r['is_competitor'])
    lawyer_count = sum(1 for r in rows if r['is_lawyer'])
    log(f'新入庫 {len(new_rows)}、移除 {len(removed)}、異動 {len(changed)}、復歸 {len(reappeared)}')
    log(f'喆律 {zhelu_count}、競品 {comp_count}、MOJ 名冊命中 {lawyer_count}')
    for m in milestones:
        log(f"  {m['msg']}")

    if dry:
        log('--dry：不寫 DB')
        return

    # 新入庫：帶 first_seen；既有：不帶（避免 upsert 蓋掉原值）
    for i in range(0, len(new_rows), 200):
        batch = [{**r, 'first_seen': today} for r in new_rows[i:i + 200]]
        sb_req('POST', 'wbie_experts', batch,
               headers={'Prefer': 'resolution=merge-duplicates'})
    for i in range(0, len(upd_rows), 200):
        batch = [{**r, 'updated_at': datetime.now(timezone.utc).isoformat()}
                 for r in upd_rows[i:i + 200]]
        sb_req('POST', 'wbie_experts?on_conflict=id', batch,
               headers={'Prefer': 'resolution=merge-duplicates'})

    # 消失者標記 removed_at（逐筆，量通常極小）
    for x in removed:
        sb_req('PATCH', f'wbie_experts?id=eq.{x["id"]}',
               {'removed_at': today}, headers={'Prefer': 'return=minimal'})

    sb_req('POST', 'wbie_sync_log', {
        'total_count': total,
        'status': 'ok',
        'new_count': len(new_rows),
        'removed_count': len(removed),
        'changed_count': len(changed),
        'zhelu_count': zhelu_count,
        'competitor_count': comp_count,
        'lawyer_count': lawyer_count,
        'milestones': milestones or None,
        'details': {
            'new': [{'id': r['id'], 'name': r['name'], 'unit': r['unit'],
                     'identity': r['identity']} for r in new_rows][:100],
            'removed': removed[:100],
            'changed': changed[:100],
        },
    })

    # 回寫資料來源頁最後爬取時間
    sb_req('PATCH', 'data_sources?scraper_name=eq.wbie_sync',
           {'last_scraped_at': datetime.now(timezone.utc).isoformat()},
           headers={'Prefer': 'return=minimal'})

    log('✅ 同步完成')


if __name__ == '__main__':
    main()
