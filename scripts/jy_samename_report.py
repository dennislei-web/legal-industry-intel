# -*- coding: utf-8 -*-
"""
同名法官區辨報告：官方遷調邊 × 共署指紋 × 署名時間線 三源交叉

對象：
A. 現任名冊同名跨院（jy_judges_snapshot 最新月，同名掛 2+ 院）
B. 「查無遷調」疑難轉調候選（leave→appear 同名 ≤6 月、無官方邊）

判準：
1. 時間重疊：同名在兩院署名期間長期重疊（>6 月）→ 必為兩人
2. 官方路徑：judge_transfers 邊串出的個人法院軌跡 → 歷史段落歸屬
3. 共署圈：judge_copanel_pairs 同事集合；兩段軌跡同事圈 Jaccard≈0 → 傾向兩人；
   借調（support 邊）期間會在 host 院與 host 同事共署 → 解釋「查無遷調」的位移

輸出：reports/samename_report.md
"""
import os
import sys
import json
from collections import defaultdict

import requests
import judgment_stats as js

sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reports', 'samename_report.md')


def rest(path, **params):
    rows, offset = [], 0
    while True:
        r = requests.get(f'{js.SUPABASE_URL}/rest/v1/{path}',
                         params={**params, 'limit': 1000, 'offset': offset},
                         headers=js.HEADERS_SB, timeout=120, verify=False)
        r.raise_for_status()
        chunk = r.json()
        rows.extend(chunk)
        if len(chunk) < 1000:
            return rows
        offset += 1000


def month_diff(a, b):
    return (int(a[:4]) - int(b[:4])) * 12 + int(a[4:]) - int(b[4:])


def circle(name, court, ym_from=None, ym_to=None):
    """該名字在該院（期間內）的共署同事集合"""
    params = {'or': f'(judge_a.eq.{name},judge_b.eq.{name})',
              'court_name': f'eq.{court}', 'select': 'judge_a,judge_b,yyyymm,case_count'}
    rows = rest('judge_copanel_pairs', **params)
    s = set()
    for r in rows:
        if ym_from and r['yyyymm'] < ym_from:
            continue
        if ym_to and r['yyyymm'] > ym_to:
            continue
        s.add(r['judge_b'] if r['judge_a'] == name else r['judge_a'])
    return s


def segments(name):
    """judge_month_stats → 該名字各院署名區段"""
    rows = rest('judge_month_stats', name=f'eq.{name}',
                select='court_name,yyyymm,case_count', order='yyyymm')
    seg = defaultdict(lambda: {'first': None, 'last': None, 'months': 0, 'cases': 0})
    for r in rows:
        c = r['court_name']
        if c == '未知法院':
            continue
        s = seg[c]
        s['first'] = s['first'] or r['yyyymm']
        s['last'] = r['yyyymm']
        s['months'] += 1
        s['cases'] += r['case_count']
    return dict(seg)


def edges(name):
    return rest('judge_transfers', name=f'eq.{name}',
                select='kind,from_org,to_org,effective_date,decision_title', order='effective_date')


def overlap_months(a, b):
    """兩區段 (first,last) 重疊月數"""
    lo = max(a['first'], b['first'])
    hi = min(a['last'], b['last'])
    return month_diff(hi, lo) + 1 if lo <= hi else 0


def jaccard(s1, s2):
    if not s1 or not s2:
        return None
    return len(s1 & s2) / len(s1 | s2)


def analyze_roster_pairs(md):
    snaps = rest('jy_judges_snapshot', select='snapshot_month,name,court_name',
                 order='snapshot_month.desc')
    latest = snaps[0]['snapshot_month']
    cur = defaultdict(set)
    for r in snaps:
        if r['snapshot_month'] == latest:
            cur[r['name']].add(r['court_name'])
    multi = {n: cs for n, cs in cur.items() if len(cs) > 1}
    md.append(f'## A. 現任名冊同名跨院（{latest} 快照，{len(multi)} 組）\n')
    for name in sorted(multi):
        courts = sorted(multi[name])
        seg = segments(name)
        ed = edges(name)
        md.append(f'### {name}（現任：{"、".join(courts)}）\n')
        verdict = []
        # 例外先判：懲戒法院（職務法庭）法官全為他院現職法官「兼任」→ 雙掛=同一人
        dual = [c for c in courts if c in ('懲戒法院', '公務員懲戒委員會')]
        if dual:
            dc = dual[0]
            dseg = seg.get(dc)
            note = f'（該院署名 {dseg["cases"]} 件/{dseg["months"]} 月，量極低符合兼任型態）' if dseg else '（該院無署名，職務法庭案件極少）'
            verdict.append(f'**高度可能同一人**：{dc}職務法庭法官依法由他院現職法官兼任，'
                           f'名冊雙掛非同名兩人{note}')
        else:
            # 判準 1：兩現任院署名時間重疊（非兼任情形下，長期並行＝兩人）
            both = [c for c in courts if c in seg]
            if len(both) == 2:
                ov = overlap_months(seg[both[0]], seg[both[1]])
                min_cases = min(seg[both[0]]['cases'], seg[both[1]]['cases'])
                if ov > 6 and min_cases >= 50:
                    verdict.append(f'兩院署名長期並行（重疊 {ov} 月、較小側 {min_cases} 件）→ **確認兩人**')
                elif ov > 6:
                    verdict.append(f'兩院署名重疊 {ov} 月，但一側量極低（{min_cases} 件）→ 可能借調/掛名雜訊，需人工看')
                elif ov > 0:
                    verdict.append(f'兩院署名重疊 {ov} 月（短）→ 傾向兩人或轉調交接期')
                else:
                    verdict.append('兩院署名無重疊 → 靠官方遷調邊判斷（無邊則傾向兩人先後在任）')
            elif len(both) == 1:
                verdict.append(f'僅 {both[0]} 有署名，另一院無 → 另一院者可能新任/借調中，暫無法指紋比對')
        # 判準 2：官方邊（個人法院軌跡，決定歷史段落歸屬）
        xfer = [e for e in ed if e['kind'] in ('transfer', 'support')]
        if xfer:
            verdict.append('官方遷調邊：' + '；'.join(
                f"{e['effective_date'][:7]} {e['from_org']}→{e['to_org']}（{e['kind']}）" for e in xfer))
        else:
            verdict.append('官方遷調邊：無（2019-12 後未見此名遷調）')
        for v in verdict:
            md.append(f'- {v}')
        md.append('')
        md.append('| 法院 | 署名期間 | 活躍月 | 掛名件數 |')
        md.append('|---|---|---|---|')
        for c, s in sorted(seg.items(), key=lambda kv: kv[1]['first']):
            md.append(f"| {c} | {s['first']}–{s['last']} | {s['months']} | {s['cases']:,} |")
        md.append('')


def analyze_orphan_candidates(md):
    """查無遷調的 leave→appear 候選：共署圈仲裁"""
    lv = rest('judge_changes', change_type='eq.leave', select='name,court_name,event_month,transfer_to,active_months')
    ap = rest('judge_changes', change_type='eq.appear', select='name,court_name,event_month')
    ap_by = defaultdict(list)
    for r in ap:
        if r['event_month'] >= '202001':
            ap_by[r['name']].append(r)
    cands = []
    for r in lv:
        if r['event_month'] < '202001' or (r['active_months'] or 0) < 12 or r['transfer_to']:
            continue
        for a in ap_by.get(r['name'], []):
            d = month_diff(a['event_month'], r['event_month'])
            if 0 <= d <= 6 and a['court_name'] != r['court_name']:
                cands.append((r['name'], r['court_name'], a['court_name'],
                              r['event_month'], a['event_month']))
    md.append(f'\n## B. 查無官方遷調的轉調候選（{len(cands)} 組）——共署圈仲裁\n')
    md.append('| 法官 | 原院 | 新院 | 末見→首見 | 原院圈 | 新院圈 | 交集 | 研判 |')
    md.append('|---|---|---|---|---|---|---|---|')
    for name, fc, tc, lm, am in sorted(cands, key=lambda x: -int(x[3])):
        c1 = circle(name, fc)
        c2 = circle(name, tc)
        inter = len(c1 & c2)
        # 共署圈交集高＝兩院有共同合作者（同一人帶著案件/庭別移動極少見；交集多半代表
        # 兩院間本來就有人員流動）→ 仲裁主要靠時間銜接 + 無同名第三軌
        verdict = '時間銜接，傾向同一人轉調（公告漏載/借調）' if month_diff(am, lm) <= 3 else '間隔較長，同名混入風險'
        md.append(f'| {name} | {fc} | {tc} | {lm}→{am} | {len(c1)} | {len(c2)} | {inter} | {verdict} |')
    md.append('')


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    md = ['# 同名法官區辨報告（官方遷調邊 × 共署指紋 × 署名時間線）\n']
    analyze_roster_pairs(md)
    analyze_orphan_candidates(md)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(md))
    print(f'報告 -> {OUT}')


if __name__ == '__main__':
    main()
