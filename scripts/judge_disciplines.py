# -*- coding: utf-8 -*-
"""法官/檢察官懲戒紀錄爬蟲：FJUD 懲戒法院職務法庭（TPJ）全量裁判 → judge_disciplines 表（mig 121）。

來源：https://judgment.judicial.gov.tw/FJUD/ 進階查詢 jud_court=TPJ（2020-07 職務法庭設立起）。
口徑：僅職務法庭懲戒案（懲/懲上/懲再…判決與裁定）；「職」字案（法官不服職務監督）當事人
角色相反且非懲戒處分，跳過。改制前公務員懲戒委員會（鑑字）未納入。
冪等：以 (case_no, name) upsert。手動執行：python judge_disciplines.py
"""
import io
import os
import re
import sys
import time

import requests

sys.stdout.reconfigure(encoding='utf-8')
HERE = os.path.dirname(os.path.abspath(__file__))
for line in io.open(os.path.join(HERE, '.env'), encoding='utf-8'):
    if '=' in line and not line.strip().startswith('#'):
        k, v = line.split('=', 1)
        os.environ.setdefault(k.strip(), v.strip())
SB_URL = os.environ['SUPABASE_URL']
SB_KEY = os.environ['SUPABASE_SERVICE_KEY']

BASE = 'https://judgment.judicial.gov.tw/FJUD/'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'

COURT_RE = (r'(?:臺灣|福建)?[^\s，。、()（）]{1,12}'
            r'(?:地方法院|高等法院|最高法院|行政法院|少年及家事法院|智慧財產及商業法院|'
            r'地方檢察署|高等檢察署|最高檢察署)(?:[^\s，。、()（）]{0,6}分[院署])?')
ROLE_RE = r'(?:候補|試署)?(?:法官|庭長|審判長|主任檢察官|檢察官|檢察長)'

# 主文 → 結果分類（依序比對，先中先贏；一列主文可命中多個）
SANCTIONS = [
    ('免除法官職務，並喪失退休金', '免除法官職務並喪失退休金'),
    ('免除法官職務，並不得再任用為公務員', '免除法官職務'),
    ('免除法官職務', '免除法官職務'),
    ('免除檢察官職務', '免除檢察官職務'),
    ('撤職', '撤職'),
    ('剝奪退休金', '剝奪退休金'),
    ('減少退休金', '減少退休金'),
    ('轉任法官以外', '轉任非法官職務'),
    ('罰款', '罰款'),
    ('降級', '降級'),
    ('減俸', '減俸'),
    ('記過', '記過'),
    ('申誡', '申誡'),
    ('停止.{0,4}職務', '停止職務'),
    ('不受懲戒', '不受懲戒'),
    ('免議', '免議'),
    ('不受理', '不受理'),
    ('上訴駁回', '上訴駁回'),
    ('抗告駁回', '抗告駁回'),
    ('駁回', '駁回'),
    ('廢棄', '原判決廢棄'),
]

EXCLUDE_LABELS = ('機關', '代表', '代理', '辯護', '律師', '輔佐')


def hidden(text, name):
    m = re.search(r'name="%s"[^>]*value="([^"]*)"' % name, text)
    return m.group(1) if m else ''


def fetch_list(session):
    """進階查詢 TPJ 全量 → 回傳 [(detail_url, title), ...]"""
    r = session.get(BASE + 'Default_AD.aspx', timeout=30)
    data = {k: hidden(r.text, k) for k in
            ('__VIEWSTATE', '__VIEWSTATEGENERATOR', '__VIEWSTATEENCRYPTED', '__EVENTVALIDATION')}
    data.update({'judtype': 'JUDBOOK', 'whosub': '0', 'jud_court': 'TPJ', 'jud_sys': '',
                 'jud_year': '', 'jud_case': '', 'jud_no': '', 'jud_no_end': '',
                 'dy1': '', 'dm1': '', 'dd1': '', 'dy2': '', 'dm2': '', 'dd2': '',
                 'jud_title': '', 'jud_jmain': '', 'jud_kw': '', 'KbStart': '', 'KbEnd': '',
                 'sel_judword': 'comm', 'ctl00$cp_content$btnQry': '送出查詢'})
    r2 = session.post(BASE + 'Default_AD.aspx', data=data, timeout=30)
    hiddens = dict(re.findall(r'<input type="hidden" name="([^"]+)"[^>]*value="([^"]*)"', r2.text))
    r3 = session.post(BASE + 'qryresult.aspx', data=hiddens, timeout=30)
    q = re.search(r'qryresultlst\.aspx\?ty=JUDBOOK&(?:amp;)?q=([0-9a-f]+)', r3.text).group(1)

    rows, page = [], 1
    while True:
        r4 = session.get(f'{BASE}qryresultlst.aspx?ty=JUDBOOK&q={q}&page={page}', timeout=30)
        got = re.findall(r'href="(data\.aspx\?[^"]+)"[^>]*>\s*([^<]+?)\s*<', r4.text)
        if not got:
            break
        rows.extend((BASE + h.replace('&amp;', '&'), re.sub(r'\s+', ' ', t)) for h, t in got)
        total = re.search(r'([\d,]+)\s*筆', r4.text)
        print(f'page {page}: +{len(got)} (total on site: {total.group(1) if total else "?"})')
        if len(got) < 20:
            break
        page += 1
        time.sleep(1)
    return rows


def strip_html(html):
    t = re.sub(r'<br\s*/?>', '\n', html)
    t = re.sub(r'<[^>]+>', '\n', t)
    t = t.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&quot;', '"')
    t = re.sub(r'[ \t　]+\n', '\n', t)
    return re.sub(r'\n{2,}', '\n', t)


def roc_date(s):
    m = re.search(r'(\d{2,3})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日', s or '')
    if not m:
        return None
    return f'{int(m.group(1)) + 1911:04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}'


def parse_detail(html, url):
    meta = {}
    for key in ('裁判字號', '裁判日期', '裁判案由'):
        m = re.search(key + r'[^<]*</div>\s*<div[^>]*>([^<]+)', html)
        meta[key] = m.group(1).strip() if m else ''
    text = strip_html(html)
    lines = [ln.strip() for ln in text.split('\n')]

    case_no = re.sub(r'\s+', '', re.sub(r'^(?:懲戒法院|司法院)職務法庭\s*', '', meta['裁判字號']))
    kind = '裁定' if '裁定' in case_no else '判決'

    # 當事人區塊：「label＋2 格以上空白＋姓名」列（掃到主文為止；區塊位置因頁面雜訊不固定）
    respondents, cur_label = [], ''
    for ln in lines:
        if re.match(r'^主[\s　]{0,4}文$', ln):
            break
        # 分隔：新制 2+ 半形空白 / 舊制（司法院職務法庭）單一全形空白
        m = re.match(r'^([一-鿿][一-鿿\s　]{1,16}?)(?:[ \t]{2,}|　+)([一-鿿]{2,4})$', ln)
        if m:
            cur_label = re.sub(r'[\s　]', '', m.group(1))
            name = m.group(2)
        elif re.match(r'^[一-鿿]{2,4}$', ln) and cur_label and ln not in ('律師',):
            name = ln  # 同 label 連續列名（多名被付懲戒人）
        else:
            continue
        if ('懲戒人' in cur_label or cur_label == '被移送人') and \
                not any(x in cur_label for x in EXCLUDE_LABELS):
            respondents.append(name)

    # 主文：主文標記到 事實/理由 之間
    mm = re.search(r'主\s{0,4}文\s*\n(.*?)\n\s*(?:事\s{0,4}實|理\s{0,4}由|犯罪事實)', text, re.S)
    main = re.sub(r'\s+', '', mm.group(1))[:600] if mm else ''

    out = []
    for name in dict.fromkeys(respondents):  # 去重保序
        # 該員主文句（多名被付懲戒人時各取各的），取不到就用整段
        sm = re.search(re.escape(name) + r'[^。]{0,120}。', main)
        my_main = sm.group(0) if sm else main
        labels = list(dict.fromkeys(
            label for pat, label in SANCTIONS if re.search(pat, my_main)))
        if any(l.endswith('駁回') and l != '駁回' for l in labels) and '駁回' in labels:
            labels.remove('駁回')  # 上訴駁回/抗告駁回 已涵蓋
        sanction = '、'.join(labels) or '（見主文）'
        # 任職機關與身分：全文首次「機關+職稱...姓名」或「姓名...機關+職稱」鄰近共現
        role, org = '', ''
        for m in re.finditer(re.escape(name), text):
            win = text[max(0, m.start() - 120):m.start() + 120]
            cm = re.findall(r'(%s)[^\n。]{0,20}?(%s)' % (COURT_RE, ROLE_RE), win)
            if cm:
                org = cm[0][0]
                # COURT_RE 前綴可能黏到日期等雜訊 → 從機關正式起始詞切起
                om = re.search(r'(?:臺灣|福建|最高|智慧財產|臺北高等|臺中高等|高雄高等|懲戒法院)', org)
                if om:
                    org = org[om.start():]
                role = '檢察官' if '檢察' in cm[0][1] or '檢察' in org else '法官'
                break
        if not role:
            role = '檢察官' if re.search(re.escape(name) + r'[^\n。]{0,30}檢察官', text) else \
               ('法官' if re.search(re.escape(name) + r'[^\n。]{0,30}法官', text) else '')
        out.append({
            'case_no': case_no, 'kind': kind, 'case_cause': meta['裁判案由'],
            'decided_date': roc_date(meta['裁判日期']), 'name': name,
            'role': role or None, 'org': org or None, 'sanction': sanction,
            'main_text': main or None, 'source_url': url,
        })
    return out


def upload(rows):
    r = requests.post(
        f'{SB_URL}/rest/v1/judge_disciplines?on_conflict=case_no,name',
        headers={'apikey': SB_KEY, 'Authorization': f'Bearer {SB_KEY}',
                 'Content-Type': 'application/json',
                 'Prefer': 'resolution=merge-duplicates'},
        json=rows, timeout=60)
    r.raise_for_status()


def main():
    s = requests.Session()
    s.headers['User-Agent'] = UA
    listing = fetch_list(s)
    print(f'清單共 {len(listing)} 篇')
    all_rows, skipped = [], 0
    for i, (url, title) in enumerate(listing, 1):
        # 「職」字案（不服職務監督）非懲戒處分，當事人角色相反 → 跳過
        if re.search(r'年度\s*職(?!懲)', title):
            skipped += 1
            continue
        for attempt in range(3):
            try:
                r = s.get(url, timeout=30)
                r.raise_for_status()
                break
            except Exception as e:
                print(f'  retry {url}: {e}')
                time.sleep(5)
        else:
            continue
        rows = parse_detail(r.text, url)
        if not rows:
            print(f'  [警告] 無被付懲戒人: {title}')
        all_rows.extend(rows)
        if i % 20 == 0:
            print(f'{i}/{len(listing)} 篇（累計 {len(all_rows)} 列）')
        time.sleep(1.2)
    print(f'解析完成：{len(all_rows)} 列（跳過職字案 {skipped} 篇），上傳中…')
    for j in range(0, len(all_rows), 100):
        upload(all_rows[j:j + 100])
    print('done')


if __name__ == '__main__':
    main()
