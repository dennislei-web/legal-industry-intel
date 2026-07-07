"""抽樣量測：律師×法官 pair 密度 + 當事人方（協同/對造）切分成功率

用法: python sample_pairs.py <yyyymm>
前提: <yyyymm>.rar 已在 .judgment_work（會自行解壓，結束後刪解壓目錄）
輸出: scratchpad/pair_stats_<yyyymm>.json
"""
import os, re, sys, json, time, subprocess
from collections import defaultdict

sys.path.insert(0, r'C:\projects\legal-industry-intel\scripts')
import judgment_stats as JS

YM = sys.argv[1]
WORK = JS.WORK_DIR
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'pair_stats_{YM}.json')

# ── 當事人方標籤（flatten 後前綴比對；長標籤在前）──
PARTY_TOKENS = [
    '被上訴人', '再抗告人', '被上訴人即', '上訴人即', '抗告人即',
    '反訴原告', '反訴被告', '被上訴人兼', '上訴人兼',
    '上訴人', '抗告人', '被告', '原告', '聲請人', '相對人', '自訴人',
    '債權人', '債務人', '參加人', '告訴人', '被害人', '受刑人', '再審原告',
    '再審被告', '異議人', '聲明異議人', '被付懲戒人', '移送機關', '公訴人',
    '被繼承人', '聲請人即', '相對人即',
]
# 陣營歸類：P=攻方 D=守方 X=無法歸類
CAMP = {
    '原告': 'P', '反訴被告': 'P', '上訴人': 'P', '抗告人': 'P', '再抗告人': 'P',
    '聲請人': 'P', '債權人': 'P', '自訴人': 'P', '再審原告': 'P', '異議人': 'P',
    '聲明異議人': 'P', '移送機關': 'P', '公訴人': 'P', '告訴人': 'P',
    '被告': 'D', '反訴原告': 'D', '被上訴人': 'D', '相對人': 'D', '債務人': 'D',
    '再審被告': 'D', '受刑人': 'D', '被付懲戒人': 'D', '被害人': 'X', '參加人': 'X',
    '被繼承人': 'X',
}


def party_label(flat):
    for t in PARTY_TOKENS:
        if flat.startswith(t):
            # 「上訴人即被告」之類複合標籤 → 無法單純歸營
            if t.endswith('即') or t.endswith('兼'):
                return t.rstrip('即兼'), 'X'
            return t, CAMP.get(t, 'X')
    return None, None


def extract_lawyers_sided(jfull):
    """回傳 [(camp, lawyer_name), ...]（camp: P/D/X；X=標籤無法歸營）
    邏輯貼齊 JS.extract_lawyers 的 block parser，另外追蹤最近一個當事人標籤"""
    out = []
    cur_camp = None      # 最近一個當事人標籤的陣營
    in_block = False

    def add(seg, camp):
        for m in JS.RE_NAME_LAWYER.finditer(seg):
            n = re.sub(r'[\s　]', '', m.group(1))
            if 2 <= len(n) <= 4 and not JS.RE_BAD_NAME.search(n):
                out.append((camp or 'X', n))

    for line in jfull[:4000].splitlines():
        flat = re.sub(r'[\s　]', '', line)
        if not flat:
            continue
        lbl, camp = party_label(flat)
        has_role = any(k in flat for k in JS.LAWYER_ROLES)
        if lbl and not has_role:
            cur_camp = camp
            in_block = False
            continue
        bare_agent = (not has_role and '代理人' in flat
                      and '法定代理人' not in flat and '送達代收' not in flat)
        if has_role or bare_agent:
            # 辯護人 → 刑事被告方
            camp_here = 'D' if ('辯護人' in flat and cur_camp is None) else cur_camp
            last = None
            for m in JS.RE_ROLE_TOKEN.finditer(line):
                last = m
            add(line[last.end():] if last else line, camp_here)
            in_block = True
        elif in_block:
            stripped = re.sub(r'[（(][^）)]*[）)]?', '', line)
            leftover = re.sub(r'[\s　]', '', JS.RE_NAME_LAWYER.sub('', stripped))
            if JS.RE_NAME_LAWYER.search(stripped) and not leftover:
                camp_here = 'D' if cur_camp is None else cur_camp
                add(stripped, camp_here)
            else:
                in_block = False


    # 去重（同案同人保留第一次出現的陣營）
    seen = {}
    for camp, n in out:
        if n not in seen:
            seen[n] = camp
    return [(c, n) for n, c in seen.items()]


def main():
    rar = os.path.join(WORK, f'{YM}.rar')
    exdir = os.path.join(WORK, YM)
    if not os.path.isdir(exdir):
        print(f'解壓 {rar} ...', flush=True)
        t0 = time.time()
        r = subprocess.run([JS.SEVENZ, 'x', rar, f'-o{exdir}', '-y', '-bso0', '-bsp0'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr[:500])
        print(f'解壓完成 {(time.time()-t0)/60:.1f} 分', flush=True)

    st = defaultdict(int)
    jpc = defaultdict(int)   # 每案法官數分布（有律師的案件）
    lpc = defaultdict(int)   # 每案律師數分布
    pair_ljc = set()         # (lawyer, judge, court)
    pair_lj = set()          # (lawyer, judge)
    pair_co = set()          # 協同 (l1,l2,court) 同案同營
    pair_op = set()          # 對造 (l1,l2,court) 同案異營(P vs D)
    ev = defaultdict(int)    # 事件數（未去重）
    t0 = time.time()

    for root, _d, files in os.walk(exdir):
        for fn in files:
            if not fn.endswith('.json'):
                continue
            st['files'] += 1
            try:
                with open(os.path.join(root, fn), encoding='utf-8-sig') as f:
                    doc = json.load(f)
            except Exception:
                continue
            jfull = doc.get('JFULL') or ''
            if not jfull:
                continue
            head = jfull[:60]
            mc = JS.RE_COURT.search(head.strip())
            court = JS.normalize_court(mc.group(1)) if mc else '未知法院'
            cat = JS.classify(head, doc.get('JCASE') or '')
            lawyers = JS.extract_lawyers(jfull)
            if not lawyers:
                continue
            st['cases_with_lawyers'] += 1
            st[f'cwl_{cat}'] += 1
            lpc[min(len(lawyers), 9)] += 1
            st['mentions'] += len(lawyers)
            judges = JS.extract_judges(jfull)
            jpc[min(len(judges), 5)] += 1
            for L in lawyers:
                for J in judges:
                    ev['lj'] += 1
                    pair_ljc.add((L, J, court))
                    pair_lj.add((L, J))
            # 方歸屬
            sided = extract_lawyers_sided(jfull)
            sided_names = {n for _c, n in sided}
            all_assigned = set(lawyers) <= sided_names
            camps = defaultdict(list)
            for c, n in sided:
                camps[c].append(n)
            n_x = len(camps.get('X', []))
            if all_assigned and n_x == 0:
                st[f'sided_ok_{cat}'] += 1
            elif n_x > 0:
                st[f'sided_amb_{cat}'] += 1
            else:
                st[f'sided_miss_{cat}'] += 1
            # 協同：同營內兩兩
            for c in ('P', 'D'):
                ns = sorted(set(camps.get(c, [])))
                for i in range(len(ns)):
                    for j in range(i + 1, len(ns)):
                        ev['co'] += 1
                        pair_co.add((ns[i], ns[j], court))
            # 對造：P×D（民事/家事/行政才有意義，但先全記，報表再分）
            if cat in ('民事', '家事', '行政'):
                for a in set(camps.get('P', [])):
                    for b in set(camps.get('D', [])):
                        ev['op'] += 1
                        k = (a, b, court) if a <= b else (b, a, court)
                        pair_op.add(k)
                if camps.get('P') and camps.get('D'):
                    st[f'both_sides_{cat}'] += 1
            if st['cases_with_lawyers'] % 20000 == 0:
                print(f"...{st['files']} files, {st['cases_with_lawyers']} cwl, "
                      f"{(time.time()-t0)/60:.1f}m", flush=True)

    res = {
        'yyyymm': YM,
        'stats': dict(st),
        'judges_per_case': dict(jpc),
        'lawyers_per_case': dict(lpc),
        'events': dict(ev),
        'distinct': {
            'lawyer_judge_court': len(pair_ljc),
            'lawyer_judge': len(pair_lj),
            'co_pair_court': len(pair_co),
            'op_pair_court': len(pair_op),
        },
        'parse_minutes': round((time.time() - t0) / 60, 1),
    }
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    print(json.dumps(res, ensure_ascii=False, indent=1))

if __name__ == '__main__':
    main()
