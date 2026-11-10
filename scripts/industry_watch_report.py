"""產業觀察定期報告產生器（喆律戰情＞產業觀察）

每週／每月／每季／每年各產一份，寫進 industry_watch_reports（admin-only），前端可隨時翻閱、兩期比較。

用法：
  python scripts/industry_watch_report.py auto                 # 每日排程用：補產所有「已到產出日、但還沒有報告」的最近幾期
  python scripts/industry_watch_report.py weekly  [--period 2026-11-06] [--force]
  python scripts/industry_watch_report.py monthly [--period 2026-10]    [--force]
  python scripts/industry_watch_report.py quarterly [--period 2026-Q3]  [--force]
  python scripts/industry_watch_report.py yearly  [--period 2026]       [--force]
  python scripts/industry_watch_report.py backfill            # 一次補齊 2026-07-27 起所有已完成期間
  python scripts/industry_watch_report.py interpret [--cadence monthly] [--force]   # 幫已存在的報告補（重寫）AI 解讀
  （有 ANTHROPIC_API_KEY 時，每產一期會順手呼叫 Claude 寫「AI 解讀」；--no-ai 關掉）

期間與產出日：
  每週＝週六～週五（接在週五本機法務部掃描之後），週六起產出，period_key＝週五日期
  每月＝自然月，次月 20 日起產出（裁判書月包、官方統計都更新後）
  每季＝自然季，季後次月 20 日起產出
  每年＝自然年，次年 1 月 20 日起產出
報告內文全部由數字規則產生（不呼叫 LLM），比較基準＝同頻率的前一期報告。
注意：repo 是公開的，GitHub Actions log 也公開——這支只印期間與計數，不印人名／所名。
"""
import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_START = dt.date(2026, 7, 27)          # 律師異動乾淨起點
GENERATOR = 'industry_watch_report.py v1'
CADENCE_LABEL = {'weekly': '週報', 'monthly': '月報', 'quarterly': '季報', 'yearly': '年報'}
PREV_LABEL = {'weekly': '上週', 'monthly': '上月', 'quarterly': '上季', 'yearly': '去年'}


# ───────────────────────── 連線 ─────────────────────────
def load_env():
    env = {k: os.environ[k] for k in ('SUPABASE_URL', 'SUPABASE_SERVICE_KEY') if k in os.environ}
    path = os.path.join(HERE, '.env')
    if os.path.exists(path):
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                k = k.strip()
                if k in ('SUPABASE_URL', 'SUPABASE_SERVICE_KEY') and k not in env:
                    env[k] = v.strip().strip('"').strip("'")
    missing = [k for k in ('SUPABASE_URL', 'SUPABASE_SERVICE_KEY') if not env.get(k)]
    if missing:
        sys.exit(f'缺少連線設定 {len(missing)} 項（.env 或環境變數）')
    return env['SUPABASE_URL'].strip().rstrip('/'), env['SUPABASE_SERVICE_KEY'].strip()


URL, KEY = None, None


def http(method, path, body=None, headers=None, retries=3):
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode('utf-8')
    h = {'apikey': KEY, 'Authorization': f'Bearer {KEY}', 'Content-Type': 'application/json'}
    h.update(headers or {})
    for attempt in range(retries):
        req = urllib.request.Request(URL + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                txt = r.read().decode('utf-8')
                return json.loads(txt) if txt.strip() else None
        except urllib.error.HTTPError as e:
            if e.code >= 500 and attempt < retries - 1:
                time.sleep(30)
                continue
            raise RuntimeError(f'HTTP {e.code} {method} {path.split("?")[0]}') from None
        except urllib.error.URLError:
            if attempt < retries - 1:
                time.sleep(30)
                continue
            raise


# ───────────────────────── 期間 ─────────────────────────
def week_period(end):            # end＝週五
    return end - dt.timedelta(days=6), end


def month_period(y, m):
    s = dt.date(y, m, 1)
    e = (dt.date(y + (m == 12), m % 12 + 1, 1) - dt.timedelta(days=1))
    return s, e


def quarter_period(y, q):
    s = dt.date(y, 3 * q - 2, 1)
    e = month_period(y, 3 * q)[1]
    return s, e


def period_of(cadence, key):
    if cadence == 'weekly':
        end = dt.date.fromisoformat(key)
        if end.weekday() != 4:
            sys.exit('週報 period 要給週五日期')
        return week_period(end)
    if cadence == 'monthly':
        y, m = map(int, key.split('-'))
        return month_period(y, m)
    if cadence == 'quarterly':
        y, q = key.split('-Q')
        return quarter_period(int(y), int(q))
    return dt.date(int(key), 1, 1), dt.date(int(key), 12, 31)


def ready_date(cadence, end):
    """最早可產出日"""
    if cadence == 'weekly':
        return end + dt.timedelta(days=1)
    nxt = end + dt.timedelta(days=1)        # 期間結束的次月 1 日
    return dt.date(nxt.year, nxt.month, 20)


def key_of(cadence, start, end):
    if cadence == 'weekly':
        return end.isoformat()
    if cadence == 'monthly':
        return f'{start.year}-{start.month:02d}'
    if cadence == 'quarterly':
        return f'{start.year}-Q{(start.month - 1) // 3 + 1}'
    return str(start.year)


def all_periods(cadence, today):
    """DATA_START 起所有已到產出日的期間（舊→新）"""
    out = []
    if cadence == 'weekly':
        end = DATA_START + dt.timedelta(days=(4 - DATA_START.weekday()) % 7)
        if end - dt.timedelta(days=6) < DATA_START:
            end += dt.timedelta(days=7)
        while ready_date('weekly', end) <= today:
            out.append(week_period(end))
            end += dt.timedelta(days=7)
    elif cadence == 'monthly':
        y, m = DATA_START.year, DATA_START.month
        while True:
            s, e = month_period(y, m)
            if ready_date('monthly', e) > today:
                break
            out.append((s, e))
            y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    elif cadence == 'quarterly':
        y, q = DATA_START.year, (DATA_START.month - 1) // 3 + 1
        while True:
            s, e = quarter_period(y, q)
            if ready_date('quarterly', e) > today:
                break
            out.append((s, e))
            y, q = (y + 1, 1) if q == 4 else (y, q + 1)
    else:
        y = DATA_START.year
        while ready_date('yearly', dt.date(y, 12, 31)) <= today:
            out.append((dt.date(y, 1, 1), dt.date(y, 12, 31)))
            y += 1
    return out


# ───────────────────────── 小工具 ─────────────────────────
def short(firm):
    if not firm:
        return '（未登錄）'
    for suf in ('法律事務所', '律師事務所'):
        if firm.endswith(suf) and len(firm) > len(suf):
            return firm[: -len(suf)]
    return firm


def fmt(v, unit=''):
    if v is None:
        return '—'
    if isinstance(v, float):
        return f'{v:.1f}{unit}'
    return f'{v:,}{unit}'


def delta_txt(cur, prev, unit='', pct=True):
    if cur is None or prev is None:
        return ''
    d = cur - prev
    if isinstance(d, float):
        s = f'{d:+.1f}{unit}'
    else:
        s = f'{d:+,}{unit}'
    if pct and prev and not unit.endswith('%') and not isinstance(cur, float):
        s += f'（{d / prev * 100:+.0f}%）'
    return s


def rate(n, d):
    return round(n / d * 100, 1) if d else None


# ───────────────────────── 報告組裝 ─────────────────────────
def turnover_now():
    """firm_turnover_stats()：7/27 起累積、年化；只在期間剛結束時記錄"""
    rows = http('POST', '/rest/v1/rpc/firm_turnover_stats', {}) or []
    t = rows[0] if isinstance(rows, list) and rows else rows      # 函式回 json 純量時 PostgREST 直接給物件
    if not t or not isinstance(t, dict):
        return None
    days = float(t.get('days') or 0)
    if days <= 0:
        return None
    k = 365.0 / days
    multi = [b for b in t.get('bands') or [] if b.get('band', 0) >= 2]
    avg = sum(b['avg_n'] for b in multi)
    lv = sum(b['leave_n'] for b in multi)
    zl = next((f for f in t.get('firms') or [] if f.get('firm_key') == '喆律法律事務所'), None)
    band_name = {2: '2–4 人所', 3: '5–9 人所', 4: '10–29 人所', 5: '30 人以上'}
    return {
        'window': f"{t.get('t0')}～{t.get('t1')}",
        'rate': round(lv / avg * k * 100, 1) if avg else None,
        'bands': [(band_name.get(b['band'], str(b['band'])), round(b['leave_n'] / b['avg_n'] * k * 100, 1) if b['avg_n'] else None) for b in multi],
        'zhelu': round(zl['leave_n'] / zl['avg_n'] * k * 100, 1) if zl and zl.get('avg_n') else None,
    }


def build_metrics(r, cadence, turnover):
    f = r['flow']
    lc = r['lawyer_count']
    lc_begin = lc.get('begin') if lc.get('begin') is not None else lc.get('begin_first')
    snap = r.get('snapshot') or {}
    se = snap.get('end') or {}
    jd = r.get('judgment') or {}
    rep = r.get('rep_rate') or {}
    zl_in = sum(1 for m in r['zhelu_moves'] if '喆律' in (m.get('to') or '') and '喆律' not in (m.get('from') or ''))
    zl_out = sum(1 for m in r['zhelu_moves'] if '喆律' in (m.get('from') or '') and '喆律' not in (m.get('to') or ''))
    M = {}

    def put(key, label, value, unit='', group=''):
        M[key] = {'label': label, 'value': value, 'unit': unit, 'group': group}

    put('lawyer_total', '全國執業律師數（公會人數）', lc.get('end'), '人', '供給')
    put('lawyer_delta', '律師數期間增減', (lc['end'] - lc_begin) if lc.get('end') is not None and lc_begin is not None else None, '人', '供給')
    put('new_lawyers', '新進律師', f['new_lawyers'], '人', '供給')
    put('firm_to_firm', '跨所移動', f['firm_to_firm'], '筆', '人才流動')
    put('entering', '從非事務所進入事務所', f['entering'], '筆', '人才流動')
    put('leaving', '離開事務所（去企業／公職等）', f['leaving'], '筆', '人才流動')
    put('team_moves', '整團轉所（同路線 ≥3 人）', len(r['team_moves']), '組', '人才流動')
    put('zhelu_in', '喆律轉入／新進', zl_in, '人', '喆律')
    put('zhelu_out', '喆律轉出', zl_out, '人', '喆律')
    put('opened', '新設事務所（不含改名）', r['opened']['n'] - (r['opened']['by_kind'] or {}).get('rename', 0), '家', '事務所')
    put('closed', '熄燈事務所（含併入，不含改名）', r['closed']['n'] - (r['closed']['by_kind'] or {}).get('rename', 0), '家', '事務所')
    put('state_removed', '名冊轉非正常（停業／除名等）', f['state_removed'], '人', '供給')
    put('discipline', '懲戒紀錄異動', f['discipline'], '筆', '供給')
    if cadence != 'weekly':
        put('firms_total', '事務所總數（月快照）', se.get('firms'), '家', '事務所')
        put('firm_lawyers', '事務所內律師數（月快照）', se.get('lawyers'), '人', '事務所')
        put('solo_firms', '單人所', se.get('s1'), '家', '事務所')
        put('firms_10_29', '10–29 人所', se.get('s10_29'), '家', '事務所')
        put('firms_30plus', '30 人以上所', se.get('s30'), '家', '事務所')
        put('judgment_yms', '裁判書資料月份', '、'.join(f'{y[:4]}-{y[4:]}' for y in (jd.get('yms') or [])), '', '喆律')
        put('zhelu_cases', '喆律裁判書案量（所級去重）', jd.get('zhelu_cases'), '件', '喆律')
        put('zhelu_rank', '喆律案量全國排名', jd.get('zhelu_rank'), '名', '喆律')
        c, fm = rep.get('民事訴訟') or {}, rep.get('家事訴訟') or {}
        put('civil_rep_rate', '民事訴訟委任率（有標的金額者）', rate(c.get('repped', 0), c.get('n', 0)), '%', '需求')
        put('family_rep_rate', '家事訴訟委任率（有標的金額者）', rate(fm.get('repped', 0), fm.get('n', 0)), '%', '需求')
        if turnover:
            put('turnover_rate', '2 人以上律所律師離職率（年化）', turnover['rate'], '%', '人才流動')
            put('zhelu_turnover_rate', '喆律律師離職率（同口徑年化）', turnover['zhelu'], '%', '喆律')
    return M


def build_report(cadence, start, end, r, prev, turnover):
    M = build_metrics(r, cadence, turnover)
    P = (prev or {}).get('metrics') or {}
    pl = PREV_LABEL[cadence]

    def pv(k):
        return (P.get(k) or {}).get('value')

    def cmp(k, unit=''):
        d = delta_txt(M[k]['value'], pv(k), unit)
        return f'，較{pl} {d}' if d else ''

    f = r['flow']
    hl = []
    lt = M['lawyer_total']['value']
    if lt is not None:
        dlt = M['lawyer_delta']['value']
        hl.append(f'全國執業律師 {fmt(lt)} 人' + (f'，本期 {dlt:+,} 人' if dlt is not None else '') + '。')
    hl.append(f"跨所移動 {fmt(f['firm_to_firm'])} 筆{cmp('firm_to_firm')}；新進律師 {fmt(f['new_lawyers'])} 位{cmp('new_lawyers')}。")
    hl.append(f"新設事務所 {M['opened']['value']} 家、熄燈 {M['closed']['value']} 家（含併入）。")
    if r['team_moves']:
        hl.append('整團轉所：' + '；'.join(f"{short(t['from'])}→{short(t['to'])} {t['n']} 人" for t in r['team_moves'][:5]) + '。')
    if M['zhelu_in']['value'] or M['zhelu_out']['value']:
        hl.append(f"喆律：轉入／新進 {M['zhelu_in']['value']} 人、轉出 {M['zhelu_out']['value']} 人。")
    if cadence != 'weekly':
        if M['firms_total']['value'] is not None:
            hl.append(f"事務所 {fmt(M['firms_total']['value'])} 家（單人所 {fmt(M['solo_firms']['value'])}）{cmp('firms_total')}。")
        if M['zhelu_rank']['value'] is not None:
            yms = '、'.join(f'{y[:4]}-{y[4:]}' for y in (r['judgment'].get('yms') or []))
            same_month = pv('judgment_yms') == M['judgment_yms']['value']
            hl.append(f"裁判書（{yms}）喆律所級去重案量 {fmt(M['zhelu_cases']['value'])} 件，全國第 {M['zhelu_rank']['value']} 名" +
                      (f"（{pl}報告第 {pv('zhelu_rank')} 名）" if pv('zhelu_rank') is not None and not same_month else '') + '。')
        if M.get('turnover_rate') and M['turnover_rate']['value'] is not None:
            hl.append(f"2 人以上律所律師離職率年化 {M['turnover_rate']['value']}%（名冊口徑下限），喆律同口徑 {fmt(M['zhelu_turnover_rate']['value'], '%')}。")

    S = []
    # 供給
    gg = [g for g in r.get('guild_gain') or [] if g.get('gain')]
    sec = {'heading': '律師供給', 'bullets': [
        f"全國執業律師（公會人數，週更）：{fmt(lt)} 人" + (f"，本期 {M['lawyer_delta']['value']:+,}" if M['lawyer_delta']['value'] is not None else ''),
        f"新進律師 {fmt(f['new_lawyers'])} 位；名冊轉非正常 {f['state_removed']} 人、恢復正常 {f['state_restored']} 人；懲戒紀錄異動 {f['discipline']} 筆",
    ]}
    if gg:
        sec['bullets'].append('各公會增減：' + '、'.join(f"{g['region']} {g['gain']:+d}" for g in gg[:8]))
    S.append(sec)
    # 人才流動
    sec = {'heading': '人才流動', 'bullets': [
        f"跨所移動 {f['firm_to_firm']} 筆、從企業／公職等進入事務所 {f['entering']} 筆、離開事務所 {f['leaving']} 筆",
    ]}
    if r['team_moves']:
        sec['bullets'].append('整團轉所（同一路線 ≥3 人）：' + '；'.join(
            f"{short(t['from'])} → {short(t['to'])} {t['n']} 人（{'、'.join(t['names'][:6])}）" for t in r['team_moves']))
    rows = [[short(x['fk']), x['moved_in'], x['moved_out'], f"{x['net']:+d}"] for x in r['net_top'][:8]] + \
           [[short(x['fk']), x['moved_in'], x['moved_out'], f"{x['net']:+d}"] for x in r['net_bottom'][:8]]
    if rows:
        sec['table'] = {'cols': ['事務所', '轉入', '轉出', '淨流'], 'rows': rows}
    S.append(sec)
    if r['intake_top']:
        S.append({'heading': '新進律師去向（前 10）', 'table': {'cols': ['事務所', '新進人數'], 'rows': [[short(x['firm']), x['n']] for x in r['intake_top']]}})
    if cadence == 'weekly' and r.get('moves_list'):
        S.append({'heading': f"本週轉所名單（{len(r['moves_list'])} 筆{'，只列前 80' if len(r['moves_list']) >= 80 else ''}）",
                  'table': {'cols': ['律師', '原事務所', '新事務所'], 'rows': [[m['name'], short(m['from']), short(m['to'])] for m in r['moves_list']]}})
    # 事務所新設／熄燈
    ob, cb = r['opened']['by_kind'] or {}, r['closed']['by_kind'] or {}
    kind_o = {'new': '全新', 'spinoff': '拆分', 'merger': '合併新設', 'rename': '改名'}
    kind_c = {'shutdown': '收掉', 'merge': '併入他所', 'unlisted': '轉未登錄', 'rename': '改名'}
    sec = {'heading': '事務所新設與熄燈', 'bullets': [
        '新設：' + ('、'.join(f'{kind_o.get(k, k)} {v}' for k, v in ob.items()) or '無'),
        '熄燈：' + ('、'.join(f'{kind_c.get(k, k)} {v}' for k, v in cb.items()) or '無'),
    ]}
    big_o = [x for x in r['opened']['top'] if (x.get('n') or 0) >= 2]
    big_c = [x for x in r['closed']['top'] if (x.get('n') or 0) >= 2]
    if big_o:
        sec['bullets'].append('2 人以上新設：' + '、'.join(f"{short(x['firm'])}（{x['n']} 人{'，拆自' + short(x['split_from']) if x.get('split_from') else ''}）" for x in big_o))
    if big_c:
        sec['bullets'].append('2 人以上熄燈：' + '、'.join(f"{short(x['firm'])}（{x['n']} 人{'→' + short(x['dest']) if x.get('dest') else ''}）" for x in big_c))
    foreign = [x for x in r['opened']['top'] if '外國法事務' in (x.get('firm') or '')]
    if foreign:
        sec['bullets'].append(f'其中外國法事務律師事務所 {len(foreign)} 家（前 15 大新設中）')
    S.append(sec)
    # 喆律
    if r['zhelu_moves']:
        S.append({'heading': '喆律相關異動', 'table': {'cols': ['日期', '律師', '原單位', '新單位'],
                  'rows': [[m['d'], m['name'], short(m.get('from')), short(m.get('to'))] for m in r['zhelu_moves']]}})
    if r.get('discipline_list'):
        S.append({'heading': '懲戒紀錄異動', 'table': {'cols': ['日期', '律師', '事務所'],
                  'rows': [[x['d'], x['name'], short(x['office']) if x.get('office') else '—'] for x in r['discipline_list']]}})
    if cadence != 'weekly':
        snap = r.get('snapshot') or {}
        se, sb = snap.get('end') or {}, snap.get('begin') or {}
        if se:
            lab = [('firms', '事務所總數'), ('lawyers', '所內律師數'), ('s1', '單人所'), ('s2_4', '2–4 人所'), ('s5_9', '5–9 人所'), ('s10_29', '10–29 人所'), ('s30', '30 人以上')]
            S.append({'heading': f"事務所規模結構（{snap.get('begin_month') or '—'} → {snap.get('end_month')} 月快照）",
                      'table': {'cols': ['項目', snap.get('begin_month') or '期初', snap.get('end_month'), '增減'],
                                'rows': [[n, fmt(sb.get(k)), fmt(se.get(k)), delta_txt(se.get(k), sb.get(k), '', False) or '—'] for k, n in lab]}})
        jd = r.get('judgment') or {}
        if jd.get('top10'):
            yms = '、'.join(f'{y[:4]}-{y[4:]}' for y in (jd.get('yms') or []))
            S.append({'heading': f'裁判書案量前 10 大事務所（{yms}，所級去重）',
                      'note': '公開裁判書＝下限；按現任名冊回溯；司法院公開滯後約 2 個月，所以月報看的是較早月份。',
                      'table': {'cols': ['排名', '事務所', '件數'], 'rows': [[x['rank'], short(x['firm']), x['cases']] for x in jd['top10']] +
                                ([[jd['zhelu_rank'], '喆律（本所）', jd['zhelu_cases']]] if jd.get('zhelu_rank') and jd['zhelu_rank'] > 10 else [])}})
        if M['civil_rep_rate']['value'] is not None:
            S.append({'heading': '需求面：委任率', 'bullets': [
                f"民事訴訟（有標的金額者）委任率 {M['civil_rep_rate']['value']}%{cmp('civil_rep_rate', '%')}",
                f"家事訴訟（有標的金額者）委任率 {fmt(M['family_rep_rate']['value'], '%')}{cmp('family_rep_rate', '%')}",
            ], 'note': '終結案件微資料，月份同上方裁判書。'})
        if turnover:
            S.append({'heading': '律師離職率（名冊口徑，年化）', 'note': f"窗口 {turnover['window']} 累積；名冊捕捉率約七成，業界校正後約再高 4–6%。",
                      'table': {'cols': ['規模', '年化離職率'], 'rows': [[b, fmt(v, '%')] for b, v in turnover['bands']] +
                                [['2 人以上合計', fmt(turnover['rate'], '%')], ['喆律（同口徑）', fmt(turnover['zhelu'], '%')]]}})
    if cadence in ('quarterly', 'yearly'):
        todo = ['市場規模頁的單價／委任率假設是否需要校正', '事務所深度分析：本期新設或衝上排行的所補做分析', '薪資帶：面試筆記與喆律人資池級有無新資料']
        if cadence == 'yearly':
            todo += ['考選部律師高考放榜人數（供給預測）', '法扶年報、內政部調解通報、公證年報、TIPO 年報等年更頁面', '產業評析（docs/industry_review_2026.md）整份改寫']
        S.append({'heading': '本期待人工檢查', 'bullets': todo})
    caveats = [f"律師異動自 {DATA_START.isoformat()} 起才可靠，期間早於此日的部分不計。"]
    if start <= dt.date(2026, 10, 31) and end >= dt.date(2026, 10, 23):
        caveats.append('⚠️ 2026-10-23～10-29 法務部官網改版、異動偵測停擺；10-30／10-31 新架構首輪掃描一次補登（10-31 單日新進 175 位、新設所大增），'
                       '本期新進律師與新設事務所數字含累積補登，不代表當期真實增量。')
    if cadence != 'weekly':
        caveats.append('裁判書與委任率的月份＝期間往前推 2 個月（司法院公開滯後），所以本期看的是較早月份。')
    S.append({'heading': '資料口徑', 'bullets': caveats + [
        '跨所移動按事務所本所歸戶（分所併本所），兩端都不是事務所的假異動已排除。',
        '比較基準＝同頻率的前一期報告' + (f"（{prev['title']}）" if prev else '（本期為第一份，無比較）') + '。',
    ]})

    title = {'weekly': f'產業觀察週報 {start.isoformat()}～{end.isoformat()}',
             'monthly': f'產業觀察月報 {start.year} 年 {start.month} 月',
             'quarterly': f'產業觀察季報 {start.year} 年第 {(start.month - 1) // 3 + 1} 季',
             'yearly': f'產業觀察年報 {start.year} 年'}[cadence]
    if start < DATA_START:
        title += '（異動自 7/27 起）'
    return {'title': title, 'summary': hl[0] + hl[1] if len(hl) > 1 else (hl[0] if hl else ''), 'highlights': hl,
            'sections': S, 'metrics': M}


# ───────────────────────── AI 解讀（Claude） ─────────────────────────
INTERP_MODEL = 'claude-opus-5-5'
INTERP_SCHEMA = {
    'type': 'object',
    'properties': {
        'headline': {'type': 'string'},
        'insights': {'type': 'array', 'items': {
            'type': 'object',
            'properties': {'title': {'type': 'string'}, 'body': {'type': 'string'}},
            'required': ['title', 'body'], 'additionalProperties': False}},
        'zhelu': {'type': 'array', 'items': {'type': 'string'}},
        'actions': {'type': 'array', 'items': {'type': 'string'}},
        'watch': {'type': 'array', 'items': {'type': 'string'}},
        'data_cautions': {'type': 'array', 'items': {'type': 'string'}},
    },
    'required': ['headline', 'insights', 'zhelu', 'actions', 'watch', 'data_cautions'],
    'additionalProperties': False,
}
INTERP_SYSTEM = """你是喆律法律事務所主持律師的產業策略分析師。你會收到一份「台灣法律產業觀察」定期報告的數字（本期＋同頻率前幾期），要寫出數字背後的含意。

讀者：喆律主持律師，以經營者視角看報告，要的是「這代表什麼、對我們有什麼影響、該做什麼」，不是把數字再念一次。

背景（判讀時可以引用，但不要當成本期數字）：
- 台灣約 5,500 家事務所、所內律師約 1.16 萬人；單人所約 68%，20 人以上約 30 家，前 10 大只佔約 6%，市場極度分散。新增律師約六成在台北。
- 2 人以上律所律師離職率（名冊口徑）年化約 14%，是下限，校正後約 18–20%；10–29 人中型所流動最高。
- 民事訴訟委任率隨標的金額上升（1–10 萬約 4.5%、100 萬以上過半）；家事委任率基線高。
- 喆律：約 68 位律師的量產型事務所，主力家事、消債、刑事等可標準化案件，靠線上行銷獲客，人均案量遠高於傳統大所；裁判書所級去重案量全國前 5。
- 「案量高但不做行銷」的事務所，主要案源約四分之三是在地口碑；靠線上行銷的極少，這是喆律的差異化能力。
- 前司法官開設的中型精品所是近年明顯趨勢。

資料口徑（一定要遵守）：
- 律師異動自 2026-07-27 起才可靠。2026-10-23～10-29 法務部官網改版、異動偵測停擺；10-30／10-31 新架構首輪掃描一次補登（10-31 單日新進 175 位、新設所大增）。涵蓋這段的期間，新進律師與新設事務所數字含累積補登，不能解讀成真實增量。
- 週報數字小，單週 ±幾筆的變化多半是雜訊；百分比變化在基數很小時（例如上週 4 筆）沒有意義，不要拿來下結論。
- 裁判書案量只算公開裁判書（下限）、按現任名冊回溯；月份是期間往前推 2 個月。
- 公會人數是週更序列，跨會重複計入，看趨勢不看絕對數。
- 名單裡的人名與所名都是公開登錄資料；具名討論時只陳述異動事實，不推測個人動機或負面評價。

寫作規則：
- 全部用繁體中文；百分點也寫成 %，不要用 pt／pp。不要自創縮寫。
- 每一點都要扣回報告裡的具體數字或名單（寫出數字），不可以引用報告沒有的數字，也不可以捏造事實；背景資料只能當參照。
- 先分辨「真實變化」和「資料假象／雜訊」。資料不足以下結論時直接說不足，不要硬湊洞察。
- 與前幾期比較時，看方向是否持續（連續幾期上升／下降），不要只看單期差額。
- 欄位：headline＝一句話總結本期最重要的事（30–60 字）；insights＝3–5 點產業含意，每點有標題與 2–4 句說明；zhelu＝2–4 點對喆律的影響（招募、留才、競爭、業務線、獲客）；actions＝2–4 個具體可執行的建議動作（誰、做什麼，能做的人選或對象就寫出來）；watch＝1–3 個下一期要盯的訊號；data_cautions＝0–3 點本期要小心的資料問題（沒有就空陣列）。
- 簡潔：整份解讀約 500–900 字。"""


def _env_value(path, name):
    if path and os.path.exists(path):
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                if line.strip().startswith(name + '='):
                    v = line.split('=', 1)[1].strip().strip('"').strip("'")
                    if v:
                        return v
    return None


def load_anthropic_key():
    """ANTHROPIC_API_KEY：環境變數 → scripts/.env → ANTHROPIC_KEY_FILE 指定的 .env
    （ANTHROPIC_KEY_FILE 可放環境變數或 scripts/.env，本機排程用後者指到 lawyer-dashboard 的 .env）；都沒有回 None（只做規則報告）"""
    if os.environ.get('ANTHROPIC_API_KEY', '').strip():
        return os.environ['ANTHROPIC_API_KEY'].strip()
    local_env = os.path.join(HERE, '.env')
    key_file = os.environ.get('ANTHROPIC_KEY_FILE', '').strip() or _env_value(local_env, 'ANTHROPIC_KEY_FILE')
    for path in (local_env, key_file):
        v = _env_value(path, 'ANTHROPIC_API_KEY')
        if v:
            return v
    return None


def history_for(cadence, end, n=8):
    rows = http('GET', f'/rest/v1/industry_watch_reports?select=period_key,metrics&cadence=eq.{cadence}'
                       f'&period_end=lt.{end.isoformat()}&order=period_end.desc&limit={n}') or []
    out = []
    for r in reversed(rows):
        out.append({'period': r['period_key'],
                    'metrics': {k: v.get('value') for k, v in (r.get('metrics') or {}).items()}})
    return out


def interpret(cadence, start, end, rep, history):
    key = load_anthropic_key()
    if not key:
        return None
    import anthropic                       # 只有要解讀時才需要這個套件
    client = anthropic.Anthropic(api_key=key, max_retries=3)
    payload = {
        'report_type': CADENCE_LABEL[cadence], 'period': f'{start.isoformat()}～{end.isoformat()}', 'title': rep['title'],
        'highlights': rep['highlights'], 'sections': rep['sections'],
        'metrics': {k: {'label': v['label'], 'value': v['value'], 'unit': v['unit']} for k, v in rep['metrics'].items()},
        'previous_periods_same_cadence': history,
    }
    msg = ('以下是本期報告與同頻率前幾期的指標（JSON）。請依系統說明寫出解讀。\n\n'
           + json.dumps(payload, ensure_ascii=False))
    try:
        resp = client.beta.messages.create(
            model=INTERP_MODEL, max_tokens=16000,
            system=INTERP_SYSTEM,
            messages=[{'role': 'user', 'content': msg}],
            output_config={'effort': 'high', 'format': {'type': 'json_schema', 'schema': INTERP_SCHEMA}},
            betas=['server-side-fallback-2026-07-01'], fallbacks='default',
        )
    except anthropic.APIStatusError as e:
        print(f'  ⚠️ 解讀失敗 HTTP {e.status_code}（報告照常寫入，之後可用 interpret 模式補）')
        return None
    except anthropic.APIConnectionError:
        print('  ⚠️ 解讀失敗：連不上 API（報告照常寫入）')
        return None
    if resp.stop_reason != 'end_turn':
        print(f'  ⚠️ 解讀未完成 stop_reason={resp.stop_reason}')
        return None
    text = next((b.text for b in resp.content if b.type == 'text'), '')
    try:
        data = json.loads(text)
    except ValueError:
        print('  ⚠️ 解讀回傳不是合法 JSON')
        return None
    u = resp.usage
    print(f'  🧠 解讀完成（輸入 {u.input_tokens} / 輸出 {u.output_tokens} tokens）')
    return {'interpretation': data, 'interp_model': resp.model,
            'interpreted_at': dt.datetime.now(dt.timezone.utc).isoformat()}


# ───────────────────────── 主流程 ─────────────────────────
def existing_keys(cadence):
    rows = http('GET', f'/rest/v1/industry_watch_reports?select=period_key&cadence=eq.{cadence}') or []
    return {r['period_key'] for r in rows}


def prev_report(cadence, start):
    rows = http('GET', f'/rest/v1/industry_watch_reports?select=title,metrics,period_end&cadence=eq.{cadence}'
                       f'&period_end=lt.{start.isoformat()}&order=period_end.desc&limit=1') or []
    return rows[0] if rows else None


def generate(cadence, start, end, today, use_ai=True):
    key = key_of(cadence, start, end)
    raw = http('POST', '/rest/v1/rpc/industry_watch_metrics', {'p_start': start.isoformat(), 'p_end': end.isoformat()})
    turnover = turnover_now() if cadence != 'weekly' and (today - end).days <= 31 else None
    rep = build_report(cadence, start, end, raw, prev_report(cadence, start), turnover)
    row = {'cadence': cadence, 'period_key': key, 'period_start': start.isoformat(), 'period_end': end.isoformat(),
           'title': rep['title'], 'summary': rep['summary'], 'highlights': rep['highlights'], 'sections': rep['sections'],
           'metrics': rep['metrics'], 'raw': raw, 'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'generator': GENERATOR}
    http('POST', '/rest/v1/industry_watch_reports?on_conflict=cadence,period_key', row,
         {'Prefer': 'resolution=merge-duplicates,return=minimal'})
    print(f'  ✅ {cadence} {key}：{len(rep["sections"])} 段、{len(rep["metrics"])} 項指標')
    if use_ai:
        ai = interpret(cadence, start, end, rep, history_for(cadence, end))
        if ai:
            http('PATCH', f'/rest/v1/industry_watch_reports?cadence=eq.{cadence}&period_key=eq.{key}', ai,
                 {'Prefer': 'return=minimal'})


def interpret_existing(cadence, force, recent=None):
    """幫已存在的報告補（或重寫）AI 解讀，舊→新；recent＝只看最近 N 期"""
    sel = 'period_key,period_start,period_end,title,highlights,sections,metrics,interpretation'
    rows = http('GET', f'/rest/v1/industry_watch_reports?select={sel}&cadence=eq.{cadence}&order=period_end.asc') or []
    if recent:
        rows = rows[-recent:]
    n = 0
    for r in rows:
        if r.get('interpretation') and not force:
            continue
        start, end = dt.date.fromisoformat(r['period_start']), dt.date.fromisoformat(r['period_end'])
        rep = {k: r[k] for k in ('title', 'highlights', 'sections', 'metrics')}
        print(f'  {cadence} {r["period_key"]}')
        ai = interpret(cadence, start, end, rep, history_for(cadence, end))
        if ai:
            http('PATCH', f'/rest/v1/industry_watch_reports?cadence=eq.{cadence}&period_key=eq.{r["period_key"]}', ai,
                 {'Prefer': 'return=minimal'})
            n += 1
    return n


def main():
    global URL, KEY
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['auto', 'backfill', 'interpret', 'weekly', 'monthly', 'quarterly', 'yearly'])
    ap.add_argument('--period')
    ap.add_argument('--force', action='store_true', help='不檢查產出日、已存在也重產（interpret 模式＝已有解讀也重寫）')
    ap.add_argument('--no-ai', action='store_true', help='只產規則報告，不呼叫 Claude 解讀')
    ap.add_argument('--cadence', help='interpret 模式只處理這個頻率')
    ap.add_argument('--today', help='測試用，假裝今天是這天')
    a = ap.parse_args()
    URL, KEY = load_env()
    today = dt.date.fromisoformat(a.today) if a.today else (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=8)).date()
    use_ai = not a.no_ai
    if use_ai and not load_anthropic_key():
        print('（沒有 ANTHROPIC_API_KEY，本次只產規則報告、不寫 AI 解讀）')
        use_ai = False
    fails = 0

    if a.mode == 'interpret':
        if not use_ai:
            sys.exit('interpret 模式需要 ANTHROPIC_API_KEY')
        for cad in ([a.cadence] if a.cadence else ['weekly', 'monthly', 'quarterly', 'yearly']):
            print(f'{CADENCE_LABEL[cad]}：補解讀 {interpret_existing(cad, a.force)} 份')
        return

    if a.mode in ('auto', 'backfill'):
        for cad in ('weekly', 'monthly', 'quarterly', 'yearly'):
            have = existing_keys(cad)
            periods = all_periods(cad, today)
            if a.mode == 'auto':
                periods = periods[-3:]          # 只補最近三期，避免舊期被意外重產
            todo = [(s, e) for s, e in periods if a.force or key_of(cad, s, e) not in have]
            print(f'{CADENCE_LABEL[cad]}：已到產出日 {len(periods)} 期、待產 {len(todo)} 期')
            for s, e in todo:              # 舊→新，比較基準才會是剛產好的前一期
                try:
                    generate(cad, s, e, today, use_ai)
                except Exception as ex:  # noqa: BLE001
                    fails += 1
                    print(f'  ❌ {cad} {key_of(cad, s, e)}：{ex}')
            if use_ai and a.mode == 'auto':   # 之前解讀失敗或當時沒金鑰的最近幾期，順手補上
                k = interpret_existing(cad, False, recent=3)
                if k:
                    print(f'  補解讀 {k} 份')
    else:
        cad = a.mode
        if a.period:
            s, e = period_of(cad, a.period)
        else:
            ps = all_periods(cad, today)
            if not ps:
                sys.exit('還沒有已到產出日的期間；要提前產請加 --period 與 --force')
            s, e = ps[-1]
        if not a.force and ready_date(cad, e) > today:
            sys.exit(f'{key_of(cad, s, e)} 還沒到產出日 {ready_date(cad, e)}；確定要提前產請加 --force')
        generate(cad, s, e, today, use_ai)
    if fails:
        sys.exit(1)


if __name__ == '__main__':
    main()
