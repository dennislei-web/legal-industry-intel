"""地政士市場統計 → public/data/landagent_stats.json（產業分析＞地政士市場）

資料源（三塊）：
1. 開業名冊：內政部地政司開放資料（data.gov.tw/dataset/25111，不定期更新）
   → 現時開業者的縣市分布／執業型態
2. 歷年開業人數：內政統計查詢網 micst c0540503（91 年起，縣市×性別，年資料）
3. 業務量（建物所有權移轉登記按原因）：內政統計通報 114 年第 24 週 表1/表2
   —— PDF 表格無 API，數字硬編於 REG_SERIES / REG_113_BY_REGION，
   每年 6 月通報出爐後手動更新（產出 JSON 時會一併帶入）

用法：python landagent_stats.py           # 下載＋聚合＋寫 JSON
"""
import csv
import io
import json
import re
import sys
import urllib.request
from collections import Counter
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / 'public' / 'data' / 'landagent_stats.json'

ROSTER_URL = ('https://opdadm.moi.gov.tw/api/v1/no-auth/resource/api/dataset/'
              '862A6771-490E-43C1-BAF5-857E1E36D714/resource/'
              '241C0789-4D86-4AA5-BCC1-DD43BC97AF59/download')
# ym/ymt 為民國年*100；每年更新時把 ymt 往後撥
YEARLY_URL = ('https://statis.moi.gov.tw/micst/webMain.aspx?sys=220&kind=21&type=1'
              '&funid=c0540503&cycle=4&outmode=12&utf=1&compmode=0&outkind=3'
              '&fldlst=111&codspc0=0,2,3,2,6,1,9,1,12,1,15,16,&rdm=er7Nmcb9'
              '&ym=9100&ymt=11400')

# 建物所有權移轉登記（棟）——內政統計通報 114 年第 24 週 表1（104–113 年）
# 欄位：移轉總棟數, 買賣, 繼承, 贈與（贈與含配偶贈與；三者外還有拍賣/信託等未列）
REG_SERIES = {
    'years': [104, 105, 106, 107, 108, 109, 110, 111, 112, 113],
    'transfer': [438047, 378661, 405806, 418546, 456234, 474579, 501807, 481959, 488053, 541498],
    'sale':     [292550, 245396, 266086, 277967, 300275, 326589, 348194, 318101, 306971, 350525],
    'inherit':  [49950, 51864, 53521, 56315, 57677, 59109, 62850, 70382, 77012, 75975],
    'gift':     [55531, 41716, 42994, 43025, 43956, 43759, 44666, 49805, 51919, 54058],
    'sale_ytd_note': '114年1-4月買賣登記8萬4,637棟，較113年同期減24.2%（房市急凍）',
}
# 地政士普考歷年報考/到考/及格（公職王彙整，與考選部榜示新聞交叉核對 112=157、114=490）
# 及格制（總成績滿 60 分）無名額限制 → 及格人數逐年波動大；每年放榜後手動補一列
EXAM_SERIES = {
    'years':      [101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114],
    'applicants': [6101, 6067, 7183, 6568, 5661, 5478, 4868, 5134, 5392, 6325, 6641, 7100, 7636, 7569],
    'takers':     [3258, 3627, 3768, 3708, 3144, 3268, 2688, 2797, 2728, 2943, 3116, 3662, 3940, 3917],
    'passers':    [320, 195, 273, 373, 161, 370, 141, 224, 264, 209, 347, 157, 200, 490],
}

# 113 年移轉登記棟數——縣市別（表2），供「每位地政士對應業務量」供需比
REG_113_BY_REGION = {
    '新北市': 108952, '臺北市': 62751, '桃園市': 66839, '臺中市': 75164,
    '臺南市': 40795, '高雄市': 63411, '宜蘭縣': 10902, '新竹縣': 15226,
    '苗栗縣': 10261, '彰化縣': 15998, '南投縣': 6507, '雲林縣': 8556,
    '嘉義縣': 6113, '屏東縣': 11660, '臺東縣': 2797, '花蓮縣': 5112,
    '澎湖縣': 1199, '基隆市': 11229, '新竹市': 11591, '嘉義市': 5221,
    '金門縣': 1006, '連江縣': 208,
}

REGIONS = list(REG_113_BY_REGION.keys())


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    return urllib.request.urlopen(req, timeout=180).read()


def norm_region(addr):
    """從事務所地址取縣市（臺/台 正規化）"""
    a = (addr or '').replace('台', '臺')
    for r in REGIONS:
        if a.startswith(r):
            return r
    return '其他'


def build():
    # 1) 名冊
    text = fetch(ROSTER_URL).decode('utf-8-sig', errors='replace')
    rows = list(csv.DictReader(io.StringIO(text)))
    total = len(rows)
    by_region = Counter(norm_region(r['OfficeAddress']) for r in rows)
    by_type = Counter((r['OfficeType'] or '未填').strip() for r in rows)
    # 聯合事務所歸戶（同名事務所 ≥2 人＝聯合型態的近似）
    office_size = Counter((r['OfficeName'] or '').strip() for r in rows if (r['OfficeName'] or '').strip())
    multi = sum(1 for n in office_size.values() if n >= 2)
    print(f'roster: {total} 位；縣市 top3 {by_region.most_common(3)}；型態 {dict(by_type)}')

    # 2) 歷年序列
    ytext = fetch(YEARLY_URL).decode('utf-8-sig', errors='replace')
    years, tot, male, female, region_latest = [], [], [], [], {}
    last_year = None
    for row in csv.reader(io.StringIO(ytext)):
        if len(row) < 4 or '/' not in row[0]:
            continue
        label, t, m, f = row[0], row[1], row[2], row[3]
        yy, reg = [s.strip() for s in label.split('/', 1)]
        yy = int(yy.replace('年', ''))
        if reg == '區域別總計':
            years.append(yy)
            tot.append(int(t)); male.append(int(m)); female.append(int(f))
            last_year = yy
        else:
            region_latest.setdefault(yy, {})[reg] = None if t == '-' else int(t)
    latest_regions = region_latest.get(last_year, {})
    print(f'yearly: {years[0]}–{years[-1]}，最新 {last_year} 年 {tot[-1]} 位')

    out = {
        'updated': None,  # 由 caller 看檔案 mtime 即可；不放時間戳避免 diff 噪音
        'roster': {
            'total': total,
            'by_region': by_region.most_common(),
            'by_type': by_type.most_common(),
            'multi_person_offices': multi,
            'offices_total': len(office_size),
        },
        'yearly': {'years': years, 'total': tot, 'male': male, 'female': female,
                   'latest_year': last_year, 'latest_by_region': latest_regions},
        'reg': REG_SERIES,
        'reg_113_by_region': REG_113_BY_REGION,
        'exam': EXAM_SERIES,
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False), encoding='utf-8')
    print(f'寫入 {OUT}（{OUT.stat().st_size:,} bytes）')


if __name__ == '__main__':
    build()
