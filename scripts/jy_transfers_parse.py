# -*- coding: utf-8 -*-
"""
人審會決議內文 → 遷調邊 解析器（掃描式 tokenizer）

文法特徵（實測 115年第5次等頁面）：
- 一句內多人共用動詞與目的地：
  「調派A院法官甲、B院法官乙…等8人以原職調派司法院辦事」
- 目的地寫法三種：「為{機關}{職稱}」「調任{機關}{職稱}」「調派{機關}辦事/辦理審判事務」
- 「同院」回指各自的原機關
- 原職可含借調前綴：「A院調B院辦理審判事務法官○○○」→ 形式機關取 A
- 「等N人」是名單筆數 checksum，能驗證解析正確性

輸出邊 kind：
- transfer  : 形式職務改變且跨機關（調任/為新機關）
- support   : 以原職借調他機關辦事/辦理審判事務（簽名會移動，職缺不動）
- promotion : 同院兼庭長/院長等（不跨機關，僅存參，不影響進退場）
"""
import re
import json

ORG_PAT = (
    r'司法院|法務部司法官學院|最高法院|最高行政法院|懲戒法院|公務員懲戒委員會|'
    r'智慧財產及商業法院|智慧財產法院|'
    r'臺灣高等法院(?:臺中|臺南|高雄|花蓮)分院|臺灣高等法院|'
    r'福建高等法院金門分院|'
    r'臺北高等行政法院|臺中高等行政法院|高雄高等行政法院|'
    r'福建金門地方法院|福建連江地方法院|'
    r'臺灣[一-鿿]{2}少年及家事法院|'
    r'臺灣[一-鿿]{2,3}地方法院|'
    r'最高檢察署|臺灣高等檢察署(?:[一-鿿]{2,6}分署)?|臺灣[一-鿿]{2,3}地方檢察署|'
    r'法務部|司法官學院|法官學院'
)
ORG_RE = re.compile(ORG_PAT)
# 機關後可掛的庭別/身分修飾（不含姓名）
DIV_PAT = r'(?:高等行政訴訟庭|地方行政訴訟庭|少年及家事法庭|商業法庭|智慧財產法庭)?'
TITLE_PAT = (
    r'(?:主任檢察官|檢察長|(?:試署|候補)?(?:法官|檢察官))'
    r'(?:兼(?:院長|庭長|處長|所長|廳長|主任[一-鿿]{0,4}|[一-鿿]{2,8}))?'
)
# 含 CJK 擴充與 PUA 造字區（司法院網站以自訂字型呈現罕用字，如「曾鈴」+PUA）
NAME_PAT = r'[㐀-鿿-𠀀-𯿿]{2,4}'
# 借調/辦事前綴（夾在機關與職稱之間）：調/借調{機關}辦理審判事務/辦事/(任)研究法官/辦理○○事務…
SECONDMENT_MID = rf'(?:(?:借調|調派?(?:支援)?)(?:{ORG_PAT})(?:辦理[一-鿿]{{0,8}}事務|辦事|任?[一-鿿]{{0,4}}(?=法官|檢察官))|派駐[一-鿿]{{0,14}}辦事)?'
# 司法院/憲法法庭內部行政職（廳處長轉任法官）；機關前綴可承前省略
ADMIN_UNIT = re.compile(r'((?:司法院|憲法法庭)?[一-鿿]{0,10}(?:廳長|處長|司長|參事|秘書長))(?=[一-鿿]{2,4}$)')
# 再任/派代（律師或退離再任法官，無原機關）
REAPPOINT = re.compile(rf'^派?再任法官({NAME_PAT})(?:派代)?$')
# 語境雜訊 token（非名單內容，靜默跳過）
NOISE_RE = re.compile(r'^(曾任[一-鿿]{2,12}|首次調任二審法院法官|[0-9一-鿿]{0,6}年?調任期間屆滿|為應業務需要|任期.{0,20}|以上.{0,30}|得連任.{0,6})$')

# 原職單元：{機關}{庭別}{借調前綴?}{職稱}
FROM_UNIT = re.compile(
    rf'({ORG_PAT})({DIV_PAT}){SECONDMENT_MID}({TITLE_PAT})'
)
TITLE_ONLY = re.compile(rf'({TITLE_PAT})')
# 錨定句尾姓名的完整版：TITLE 的貪婪量詞（如「兼主任○○」）可經回溯讓出姓名字元
NAMED_FROM = re.compile(rf'({ORG_PAT}){DIV_PAT}{SECONDMENT_MID}({TITLE_PAT})({NAME_PAT})')
NAMED_TITLE = re.compile(rf'({TITLE_PAT})({NAME_PAT})')
DEST_RE = re.compile(
    rf'(?:首次調任為?|再次調任為?|再次調派為|調任為?|為)(同院|{ORG_PAT})({DIV_PAT})({TITLE_PAT})'
)
SECOND_RE = re.compile(rf'(?:以原職)?調派?(?:支援)?({ORG_PAT})(?:辦理審判事務|辦事|擔任|任[㐀-鿿]{{0,4}}法官)')
# 「並以新職（繼續）調派○○辦理審判事務」：形式職務在 dest、實際簽名在此機關
NEWPOST_RE = re.compile(rf'並?以新職(?:繼續)?調?派?({ORG_PAT})(?:辦理審判事務|辦事|任[㐀-鿿]{{0,4}})')
COUNT_RE = re.compile(r'等(\d+|[一二三四五六七八九十]+)人')
EFFECT_RE = re.compile(r'自(1[01]\d)年(\d{1,2})月(\d{1,2})日生效')
CN_NUM = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10}
# 這些句子不含遷調（試署及格/證明書/票選/懲戒/免兼），跳過可降噪
SKIP_RE = re.compile(r'服務成績|專業法官證明書|票選|遴選委員會|評鑑|免兼|退養|司法事務官|公設辯護人|書記官長|分發員額')
EXIT_RE = re.compile(rf'(?:准|同意)({ORG_PAT}){DIV_PAT}({TITLE_PAT})({NAME_PAT})(?:等\d*人?)?(辭職|辭去法官職務|退休)')


def cn_int(s):
    if s.isdigit():
        return int(s)
    if s.startswith('十'):
        return 10 + CN_NUM.get(s[1:], 0) if len(s) > 1 else 10
    if '十' in s:
        a, _, b = s.partition('十')
        return CN_NUM[a] * 10 + (CN_NUM.get(b, 0) if b else 0)
    return CN_NUM.get(s, 0)


def parse_clause(clause):
    """單一子句（；分隔）→ (persons, dest, count_check)
    persons = [(org, title, name)]；dest = ('transfer'|'support', org, title) 或 None"""
    persons = []
    # 括號註記先剝（「為臺灣士林地方法院（試署）法官」的（試署）會讓目的地偵測失敗）
    clause = re.sub(r'（[^）]{0,25}）|\([^)]{0,25}\)', '', clause)
    # 找目的地：借調式（調派X辦理審判事務）與一般式（為/調任X）皆取「最後一個」，
    # 再比誰更靠句尾——原職描述裡也可能出現「調X辦理審判事務」，靠尾者才是本句動詞。
    # 「並以新職調派X辦事」屬 NEWPOST（形式職務另在 dest），不能當本句目的地。
    secs = [m for m in SECOND_RE.finditer(clause)
            if '以新職' not in clause[max(0, m.start()-6):m.start()+4]
            and not TITLE_ONLY.match(clause, m.end())]  # 後面緊跟職稱＝from-unit 借調前綴，非本句動詞
    dests = list(DEST_RE.finditer(clause))
    sec = secs[-1] if secs else None
    d = dests[-1] if dests else None
    if sec and (not d or sec.start() >= d.start()):
        dest = ('support', sec.group(1), '法官')
        body = clause[:sec.start()]
    elif d:
        dest = ('transfer', d.group(1), (d.group(3) or '法官'))
        body = clause[:d.start()]
    else:
        return [], None, None, [], [], None

    # token 化：以頓號切，每個 token 是「機關+職稱+姓名」「職稱+姓名」或「裸姓名」
    body = re.sub(r'.*：', '', body)          # 「再次調派為二審法院法官：」等敘述前綴
    body = re.sub(r'（[^）]{0,25}）|\([^)]{0,25}\)', '', body)  # 括號借調註記：「（調司法院辦事）」等
    body = re.sub(r'^」?[一二三四五六七八九十]{1,3}、', '', body)  # 舊頁面「一、」項次黏在句首
    body = re.sub(r'等\d+人.*$', '', body)
    body = re.sub(r'等[一二三四五六七八九十]+人.*$', '', body)
    cur = None  # (org, title)
    unparsed, inline_edges = [], []
    for token in re.split(r'[、，]', body):
        token = re.sub(r'^[」「]+', '', token.strip())
        token = re.sub(r'^(調派|現任|首次調任|再次調任)', '', token)
        if not token or NOISE_RE.match(token):
            continue
        rm = REAPPOINT.match(token)
        if rm:
            persons.append(('(再任)', '法官', rm.group(1)))
            continue
        fm = NAMED_FROM.fullmatch(token)
        if fm:
            cur = (fm.group(1), fm.group(2))
            persons.append((cur[0], cur[1], fm.group(3)))
            continue
        tf = NAMED_TITLE.fullmatch(token) if cur else None
        if tf:
            cur = (cur[0], tf.group(1))
            persons.append((cur[0], cur[1], tf.group(2)))
            continue
        m = FROM_UNIT.match(token)
        if m:
            cur = (m.group(1), m.group(3))
            rest = token[m.end():]
        else:
            am = ADMIN_UNIT.match(token)
            if am:
                cur = ('司法院', am.group(1).replace('司法院', ''))
                rest = token[am.end():]
            else:
                tm = TITLE_ONLY.match(token)
                if tm and cur:
                    cur = (cur[0], tm.group(1))
                    rest = token[tm.end():]
                else:
                    rest = token
        rest = re.sub(r'(調派|派代|首次調任|再次調任)$', '', rest)
        if not rest:
            continue
        if cur and re.fullmatch(NAME_PAT, rest) and not ORG_RE.match(rest):
            persons.append((cur[0], cur[1], rest))
            continue
        # 「甲及乙」兩名連寫
        two = re.fullmatch(rf'({NAME_PAT})及({NAME_PAT})', rest) if cur else None
        if two:
            persons.append((cur[0], cur[1], two.group(1)))
            persons.append((cur[0], cur[1], two.group(2)))
            continue
        # 「甲及{機關}{職稱}乙」：及 之後是完整原職單元
        ju = re.fullmatch(rf'({NAME_PAT})及(({ORG_PAT}).+)$', rest) if cur else None
        if ju:
            persons.append((cur[0], cur[1], ju.group(1)))
            m2 = FROM_UNIT.match(ju.group(2))
            if m2 and re.fullmatch(NAME_PAT, ju.group(2)[m2.end():]):
                cur = (m2.group(1), m2.group(3))
                persons.append((cur[0], cur[1], ju.group(2)[m2.end():]))
                continue
            unparsed.append(ju.group(2))
            continue
        # 「甲為X法院法官、乙為Y法院法官」：token 自帶目的地的完整配對
        dm = DEST_RE.search(rest) if cur else None
        if dm and re.fullmatch(NAME_PAT, rest[:dm.start()]):
            to_org = cur[0] if dm.group(1) == '同院' else dm.group(1)
            inline_edges.append((cur[0], cur[1], rest[:dm.start()], to_org, dm.group(3) or '法官'))
        else:
            unparsed.append(token)
    cm = COUNT_RE.search(clause)
    # 「並以新職調派○○」：實際工作地與形式職務不同 → 回傳給上層補發 support 邊
    np = NEWPOST_RE.search(clause)
    newpost_org = np.group(1) if np else None
    return persons, dest, (cn_int(cm.group(1)) if cm else None), unparsed, inline_edges, newpost_org


def parse_text(text, fallback_date=None):
    """整頁內文 → edges list（dict）。回傳 (edges, warnings)"""
    edges, warnings = [], []
    text = re.sub(r'\s+', '', text)
    for sent in re.split(r'。', text):
        if not sent or SKIP_RE.search(sent):
            # 退場事件仍要撈（辭職/退休句可能同時含證明書字眼機率低）
            pass
        em = EFFECT_RE.search(sent)
        eff = f'{int(em.group(1))+1911:04d}-{int(em.group(2)):02d}-{int(em.group(3)):02d}' if em else fallback_date
        # 退場（辭職/退休）
        for x in EXIT_RE.finditer(sent):
            edges.append({'kind': 'exit', 'name': x.group(3), 'from_org': x.group(1),
                          'from_title': x.group(2), 'to_org': None, 'to_title': x.group(4),
                          'effective_date': eff})
        if SKIP_RE.search(sent):
            continue
        for clause in re.split(r'；', sent):
            persons, dest, n_check, unparsed, inline_edges, newpost_org = parse_clause(clause)
            if not dest:
                continue
            # 「等N人」指涉緊鄰其前的名單（persons）；inline 配對（自帶目的地）不在 N 內
            if n_check is not None and n_check not in (len(persons) + len(inline_edges), len(persons)):
                warnings.append(f'count mismatch: 等{n_check}人 vs parsed {len(persons)+len(inline_edges)} :: {clause[:80]}')
            for u in unparsed:
                warnings.append(f'unparsed token: 「{u}」 :: {clause[:60]}')
            for org, title, name, to_org, to_title in inline_edges:
                kind = 'promotion' if to_org == org else 'transfer'
                edges.append({'kind': kind, 'name': name, 'from_org': org, 'from_title': title,
                              'to_org': to_org, 'to_title': to_title, 'effective_date': eff})
            for org, title, name in persons:
                kind, to_org, to_title = dest
                if to_org == '同院':
                    to_org = org
                if kind == 'transfer' and to_org == org:
                    kind = 'promotion'
                edges.append({'kind': kind, 'name': name, 'from_org': org, 'from_title': title,
                              'to_org': to_org, 'to_title': to_title, 'effective_date': eff})
                # 「並以新職調派○○辦理審判事務」：形式職務在 to_org、簽名會出現在 newpost_org
                if newpost_org and kind == 'transfer' and newpost_org != to_org:
                    edges.append({'kind': 'support', 'name': name, 'from_org': to_org,
                                  'from_title': to_title, 'to_org': newpost_org,
                                  'to_title': '法官', 'effective_date': eff})
    return edges, warnings


if __name__ == '__main__':
    import os, sys
    sys.stdout.reconfigure(encoding='utf-8')
    d = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_jy_transfers_pages')
    tot_e, tot_w = 0, 0
    for fn in sorted(os.listdir(d)):
        if not fn.endswith('.json'):
            continue
        page = json.load(open(os.path.join(d, fn), encoding='utf-8'))
        fb = None
        if page.get('roc_date'):
            y, m, dd = page['roc_date'].split('-')
            fb = f'{int(y)+1911:04d}-{m}-{dd}'
        edges, warns = parse_text(page['text'], fb)
        tot_e += len(edges); tot_w += len(warns)
        kinds = {}
        for e in edges:
            kinds[e['kind']] = kinds.get(e['kind'], 0) + 1
        print(f"{page['title']}: {len(edges)} edges {kinds} warns={len(warns)}")
        for w in warns:
            print('  !', w)
    print(f'TOTAL edges={tot_e} warns={tot_w}')
