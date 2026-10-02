# -*- coding: utf-8 -*-
"""facts.tsv → firm_analysis_facts（upsert，不先清表）。
跑新分析批次後：python facts_extract.py && python upload_facts.py
每月另由 scripts/judgment_derivs_monthly.py（本機排程）在尾端跑同一組指令。

流程：讀 TSV → 讀 DB 現行內容與 firm_dedup_totals 的資料窗 → 防呆 → upsert → 驗證 → 刪掉多出來的舊列 → 再驗證。
- upsert 是單一請求（on_conflict=firm、merge-duplicates）＝單一交易，要嘛整批寫入、要嘛沒寫，過程中表不會
  是空的（舊版先 DELETE 全表再分批 POST，中途失敗時讀這張表的兩個頁面就是空的）。每列帶同一個
  refreshed_at；DB 有而 TSV 沒有的欄位保留原值。
- 防呆，任一成立就不寫入、exit 1（門檻見 MAX_*／MIN_*）：
    列數比現行少超過 5%；要刪的舊列超過現行 5%；某欄大量由有值變空（抽取或來源讀取壞了）；
    firm_dedup_totals 讀不到、TSV 的資料窗月數與它不同（TSV 不是用現在的資料產的）或比 DB 現行值小。
- 事務所集合與 DB 不同：新增的照寫；DB 多出來的舊列等 upsert 驗證通過才刪，條件＝點名的所且
  refreshed_at 早於本次。差異都會印出來。

用法：python upload_facts.py [--dry-run] [--force] [--src <tsv>]
  --dry-run  只比對、跑防呆，不寫入
  --force    防呆沒過仍寫入（人工看過差異、確認是預期的才用）
  --src      來源檔（預設 facts_extract.py 產出的 facts.tsv）
"""
import io, re, csv, json, sys, time, argparse, datetime, collections
import urllib.error, urllib.parse, urllib.request
from http.client import HTTPException

ENV = r"C:\projects\legal-industry-intel\scripts\.env"
SRC = r"C:\projects\legal-industry-intel\scripts\_batch408\v2\facts.tsv"

env = {}
for ln in io.open(ENV, encoding='utf-8-sig'):
    ln = ln.strip()
    if ln and '=' in ln and not ln.startswith('#'):
        k, v = ln.split('=', 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
URL = env['SUPABASE_URL']
KEY = env.get('SUPABASE_SERVICE_KEY') or env.get('SUPABASE_KEY')
H = {'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}

INT_COLS = {'lawyer_count', 'avg_cases', 'founded_year', 'roster_n', 'court_n', 'cases_5y',
            'cases_nominal', 'dedup_months',
            'rev_low_wan', 'rev_high_wan', 'succession_risk', 'ex_judicial_n', 'g_reviews',
            'fb_pixel', 'google_ads', 'line_tag', 'yahoo_ads', 'tiktok_pixel', 'gov_tender_amt', 'indep_seats', 'awards_n'}
NUM_COLS = {'g_rating', 'dup_rate'}

TABLE = '/rest/v1/firm_analysis_facts'
MAX_SHRINK = 0.05    # 列數比現行少超過這個比例 → 不寫
MAX_DROP = 0.05      # 要刪的舊列超過現行列數的這個比例 → 不寫
MAX_EMPTIED = 0.05   # 某欄由有值變空的所，超過該欄原有值家數的這個比例（且多於 MIN_EMPTIED 家）→ 不寫
MIN_EMPTIED = 10
RETRY_WAITS = (5, 15, 45)  # 連線錯誤／逾時／5xx／429 的退避秒數
NUM_RE = re.compile(r'-?\d+(\.\d+)?$')


class Abort(Exception):
    """不能繼續：印訊息、exit 1。"""


def rest(method, path, body=None, prefer=None):
    """打 PostgREST，回 (HTTP 狀態, 回應 JSON 或 None, 第幾次成功)。連線錯誤／逾時／5xx／429 退避重試，
    其餘 4xx 不重試。這支腳本的寫入不是帶 on_conflict 就是帶條件，重送同一份內容結果相同。"""
    headers = dict(H)
    if prefer:
        headers['Prefer'] = prefer
    data = json.dumps(body, ensure_ascii=False).encode('utf-8') if body is not None else None
    what = '%s %s' % (method, path.split('?')[0])
    for attempt in range(1, len(RETRY_WAITS) + 2):
        req = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw.strip() else None), attempt
        except urllib.error.HTTPError as e:
            err = 'HTTP %d %s' % (e.code, e.read().decode('utf-8', 'replace')[:300])
            if e.code < 500 and e.code not in (408, 429):
                raise Abort('%s 失敗：%s' % (what, err))
        except (OSError, HTTPException, ValueError) as e:  # URLError 是 OSError；ValueError＝回應不是 JSON
            err = '%s: %s' % (type(e).__name__, e)
        if attempt > len(RETRY_WAITS):
            raise Abort('%s 試了 %d 次仍失敗：%s' % (what, attempt, err))
        wait = RETRY_WAITS[attempt - 1]
        print('  %s 第 %d 次失敗（%s），%d 秒後重試' % (what, attempt, err[:200], wait))
        time.sleep(wait)


def get_all(path):
    """分頁讀完（PostgREST 每回應上限 1000 列）；path 要帶唯一鍵的 order。"""
    out = []
    while True:
        rows = rest('GET', '%s&limit=1000&offset=%d' % (path, len(out)))[1] or []
        out += rows
        if len(rows) < 1000:
            return out


def convert(r):
    """TSV 一列 → 要寫入的型別。數值欄轉不動的（空字串、facts_extract 對 null 做 str() 留下的字面 None）一律 NULL。"""
    o = {}
    for k, v in r.items():
        if k in INT_COLS:
            try:
                o[k] = int(float(v))
            except (ValueError, TypeError):
                o[k] = None
        elif k in NUM_COLS:
            try:
                o[k] = float(v)
            except (ValueError, TypeError):
                o[k] = None
        else:
            o[k] = v or None
    return o


def read_tsv(path):
    """讀 facts.tsv，回 (欄位名 list, {firm: 轉型後的列})。結構不對（欄數不符、firm 空白或重複）直接中止。"""
    try:
        fp = io.open(path, encoding='utf-8', newline='')
    except OSError as e:
        raise Abort('讀不到來源檔 %s：%s' % (path, e))
    new = {}
    with fp:
        # facts_extract.py 直接用 tab 串接、不加引號，這裡也不解讀引號
        rd = csv.DictReader(fp, delimiter='\t', quoting=csv.QUOTE_NONE)
        cols = rd.fieldnames or []
        if 'firm' not in cols or 'refreshed_at' in cols:
            raise Abort('來源檔表頭不對（要有 firm、不能有 refreshed_at）：%s' % path)
        for i, r in enumerate(rd, 2):
            if None in r or any(v is None for v in r.values()):
                raise Abort('來源檔第 %d 行的欄數與表頭不符' % i)
            o = convert(r)
            if not o['firm']:
                raise Abort('來源檔第 %d 行的 firm 是空的' % i)
            if o['firm'] in new:
                raise Abort('來源檔的 firm 重複：%s' % o['firm'])
            new[o['firm']] = o
    if not new:
        raise Abort('來源檔沒有資料列：%s' % path)
    return cols, new


def dedup_window():
    """firm_dedup_totals 目前的資料窗 (起月, 迄月, 月數)；讀不到回 None。月數算法同 facts_extract.py。"""
    try:
        lo = rest('GET', '/rest/v1/firm_dedup_totals?select=ym_from&order=ym_from.asc&limit=1')[1]
        hi = rest('GET', '/rest/v1/firm_dedup_totals?select=ym_to&order=ym_to.desc&limit=1')[1]
    except Abort as e:
        print('  %s' % e)
        return None
    if not lo or not hi:
        return None
    lo, hi = lo[0]['ym_from'], hi[0]['ym_to']
    return lo, hi, (int(hi[:4]) - int(lo[:4])) * 12 + int(hi[4:]) - int(lo[4:]) + 1


def blank(v):
    return v is None or v == ''


def norm(v):
    """比對用：None 與空字串算同一個空值；數值不分 int／float／數字字串。"""
    if blank(v):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return float(v) if isinstance(v, str) and NUM_RE.match(v) else v


def names(xs, n=8):
    xs = sorted(xs)
    return '、'.join(xs[:n]) + ('…等 %d 家' % len(xs) if len(xs) > n else '')


def window_of(rows):
    """一批列裡 dedup_months 的最大值；沒有任何一列有值回 None。"""
    vals = [r['dedup_months'] for r in rows if not blank(r.get('dedup_months'))]
    return max(vals) if vals else None


def diff(cols, new, db):
    """兩邊都有的所裡，內容有變的家數與各欄的變動家數。"""
    by_col, changed = collections.Counter(), 0
    for k, r in new.items():
        if k in db:
            cs = [c for c in cols if norm(r[c]) != norm(db[k].get(c))]
            changed += bool(cs)
            by_col.update(cs)
    return changed, by_col


def guards(cols, new, db, win):
    """回傳不該寫入的理由（空 list＝通過）。win＝dedup_window() 的結果。"""
    bad = []
    n_new, n_db = len(new), len(db)
    drop = set(db) - set(new)
    if n_new < n_db * (1 - MAX_SHRINK):
        bad.append('列數 %d → %d，少了 %.1f%%（上限 %.0f%%）'
                   % (n_db, n_new, (n_db - n_new) / n_db * 100, MAX_SHRINK * 100))
    if len(drop) > n_db * MAX_DROP:
        bad.append('要刪的舊列 %d 列，超過現行 %d 列的 %.0f%%：%s' % (len(drop), n_db, MAX_DROP * 100, names(drop)))
    both = [k for k in new if k in db]
    for c in cols:
        had = [k for k in both if not blank(db[k].get(c))]
        lost = [k for k in had if blank(new[k][c])]
        if len(lost) > max(MIN_EMPTIED, len(had) * MAX_EMPTIED):
            bad.append('%s：%d 家由有值變空（原有值 %d 家，上限 %.0f%%），例：%s'
                       % (c, len(lost), len(had), MAX_EMPTIED * 100, names(lost, 3)))
    new_win, db_win = window_of(new.values()), window_of(db.values())
    if win is None:
        bad.append('firm_dedup_totals 讀不到，無法確認資料窗')
    elif new_win != win[2]:
        bad.append('TSV 的資料窗 %s 個月，firm_dedup_totals 現在是 %d 個月（%s–%s）：TSV 不是用現在的資料產的，'
                   '重跑 facts_extract.py' % (new_win, win[2], win[0], win[1]))
    if db_win and (new_win or 0) < db_win:
        bad.append('資料窗 %s 個月，比 DB 現行的 %d 個月小' % (new_win, db_win))
    return bad


def verify(cols, new, stamp, leftover=()):
    """重讀全表核對，回 (全表 {firm: 列}, 問題 list)。leftover＝此刻還可以留在表裡的舊列（尚未刪）。"""
    after = {r['firm']: r for r in get_all(TABLE + '?select=*&order=firm')}
    bad = []
    missing = set(new) - set(after)
    if missing:
        bad.append('TSV 有、DB 沒有：%s' % names(missing))
    extra = set(after) - set(new) - set(leftover)
    if extra:
        bad.append('DB 有、TSV 沒有：%s' % names(extra))
    wrote = [k for k in new if k in after]
    old = [k for k in wrote if datetime.datetime.fromisoformat(after[k]['refreshed_at']) != stamp]
    if old:
        bad.append('refreshed_at 不是本次：%s' % names(old))
    off = [k for k in wrote if any(norm(new[k][c]) != norm(after[k].get(c)) for c in cols)]
    if off:
        bad.append('內容與 TSV 不一致：%s' % names(off))
    return after, bad


def stale_filter(firms, stamp):
    """刪舊列用的條件：點名的所，且 refreshed_at 早於本次（剛寫進去的列不會中）。"""
    lst = ','.join('"%s"' % n.replace('\\', '\\\\').replace('"', '\\"') for n in firms)
    return 'firm=in.(%s)&refreshed_at=lt.%s' % (urllib.parse.quote(lst, safe=''),
                                                urllib.parse.quote(stamp.isoformat(), safe=''))


def delete_stale(drop, stamp):
    """刪 DB 多出來的舊列，每次點名 20 家（網址長度）。回實際刪掉的列數。"""
    drop, gone = sorted(drop), 0
    for i in range(0, len(drop), 20):
        gone += len(rest('DELETE', TABLE + '?' + stale_filter(drop[i:i + 20], stamp),
                         prefer='return=representation')[1] or [])
    return gone


def main():
    ap = argparse.ArgumentParser(description='facts.tsv → firm_analysis_facts（upsert）')
    ap.add_argument('--dry-run', action='store_true', help='只比對、跑防呆，不寫入')
    ap.add_argument('--force', action='store_true', help='防呆沒過仍寫入')
    ap.add_argument('--src', default=SRC, help='來源檔')
    args = ap.parse_args()

    cols, new = read_tsv(args.src)
    db_rows = get_all(TABLE + '?select=*&order=firm')
    db = {r['firm']: r for r in db_rows}
    if db_rows:
        unknown = [c for c in cols if c not in db_rows[0]]
        if unknown:
            raise Abort('TSV 有 DB 沒有的欄位：%s（先套 migration 再寫入）' % '、'.join(unknown))
        kept = [c for c in db_rows[0] if c not in cols and c != 'refreshed_at']
        if kept:
            print('  DB 有、TSV 沒有的欄位（保留原值）：%s' % '、'.join(kept))
    win = dedup_window()
    data_cols = [c for c in cols if c != 'firm']
    add, drop = set(new) - set(db), set(db) - set(new)
    changed, by_col = diff(data_cols, new, db)
    for label, xs in (('＋新增', sorted(add)), ('－移除', sorted(drop))):
        for i in range(0, len(xs), 10):
            print('  %s：%s' % (label, '、'.join(xs[i:i + 10])))

    print('facts.tsv %d 列（%d 欄）；DB 現行 %d 列；firm_dedup_totals 資料窗 %s'
          % (len(new), len(cols), len(db), '%s–%s（%d 個月）' % win if win else '讀不到'))
    top = '、'.join('%s %d' % x for x in by_col.most_common(6)) + ('…' if len(by_col) > 6 else '')
    print('差異：新增 %d 家、移除 %d 家、內容有變 %d 家%s' % (len(add), len(drop), changed, '（%s）' % top if top else ''))
    bad = guards(data_cols, new, db, win)
    if bad:
        print('防呆沒過%s：' % ('' if args.force else '，不寫入'))
        for b in bad:
            print('  - ' + b)
        if not args.force:
            print('確認差異是預期的再加 --force 寫入；--dry-run 只比對不寫')
            sys.exit(1)
        print('--force：照寫')
    else:
        print('防呆通過（列數 %d→%d、要刪 %d 列、沒有欄位大量變空、資料窗 %s→%s 個月）'
              % (len(db), len(new), len(drop), window_of(db.values()), window_of(new.values())))
    if args.dry_run:
        print('--dry-run：不寫入')
        return

    stamp = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    payload = [dict(r, refreshed_at=stamp.isoformat()) for r in new.values()]
    status, _, tries = rest('POST', TABLE + '?on_conflict=firm', payload,
                            prefer='resolution=merge-duplicates,return=minimal')
    print('upsert %d 列完成（HTTP %d，第 %d 次）' % (len(payload), status, tries))
    after, problems = verify(data_cols, new, stamp, leftover=drop)
    if problems:  # 沒對上就不往下刪舊列
        raise Abort('寫入後驗證沒過：' + '；'.join(problems))
    if drop:
        print('刪除多出來的舊列 %d 列' % delete_stale(drop, stamp))
        after, problems = verify(data_cols, new, stamp)
        if problems:
            raise Abort('刪除舊列後驗證沒過：' + '；'.join(problems))
    w = window_of(after.values())
    print('驗證通過：DB %d 列、refreshed_at 全為本次（%s）、內容與 TSV 一致；dedup_months=%s 共 %d 列、cases_5y 合計 %s'
          % (len(after), stamp.astimezone().strftime('%Y-%m-%d %H:%M:%S'), w,
             sum(1 for r in after.values() if w is not None and r.get('dedup_months') == w),
             format(sum(r.get('cases_5y') or 0 for r in after.values()), ',')))


if __name__ == '__main__':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    try:
        main()
    except Abort as e:
        print(e)
        sys.exit(1)
