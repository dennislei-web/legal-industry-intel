"""
喆律校友專用 MOJ 刷新爬蟲 — 只掃 zhelu_alumni 的 ~52 位離職律師

全名冊刷新（moj_office_refresh.py 7 分片）一週才輪完一圈，校友動態要等最多 7 天；
這支只掃校友，幾分鐘跑完，讓校友會頁的現職/去向更即時。

流程：
  1. 讀 zhelu_alumni 全部列
  2. 姓名 → moj_lawyers 解析 lic_no
     - 同名多筆：用 current_firm 前綴比對消歧（例：楊筑鈞 → 茁越國際），對不上就跳過並警告
  3. 逐位 query_lic() 問 MOJ 現值
     - 有變動 → PATCH moj_lawyers（trigger moj_lawyers_log_change 自動記到 moj_lawyer_changes，
       異動追蹤頁與事務所 modal 的人員異動卡照常吃得到）
  4. 回寫 zhelu_alumni：current_firm / current_region / category / updated_at
     - category 自動轉類只做「安全轉移」；cohort（轉合署）是人工判斷的業務分類，只報告不改；
       「名冊消失 → not_registered」與「not_registered → 重新登錄」可能是同名誤認，只報告不改

用法:
  python moj_alumni_refresh.py             # 正式跑（寫入）
  python moj_alumni_refresh.py --dry-run   # 只比對不寫入
  python moj_alumni_refresh.py 5           # 只處理前 5 位（測試）
  python moj_alumni_refresh.py --name 蔡愷凌  # 只處理這一位（前端單人重爬按鈕走這裡）
"""
import os
import re
import sys
import time
import requests
from datetime import datetime, timezone
from urllib.parse import quote
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'), override=False)
if sys.platform == 'win32':
    sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

from moj_licno_scan import normalize_office, query_lic_status  # noqa: E402（需要先 load_dotenv）

SUPABASE_URL = os.environ['SUPABASE_URL'].strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_KEY'].strip()
HEADERS_SB = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}


def sb_get(path):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/{path}', headers=HEADERS_SB, verify=False, timeout=60)
    r.raise_for_status()
    return r.json()


def sb_patch(path, payload):
    for attempt in range(3):
        try:
            r = requests.patch(
                f'{SUPABASE_URL}/rest/v1/{path}', json=payload,
                headers={**HEADERS_SB, 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                verify=False, timeout=30,
            )
            if r.status_code in (200, 204):
                return True
            print(f'  ! PATCH {path} error {r.status_code}: {r.text[:200]}', flush=True)
            return False
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError):
            time.sleep(5 * (attempt + 1))
    print(f'  ! PATCH {path} timeout，放棄', flush=True)
    return False


def resolve_lic(alumnus, moj_by_name):
    """姓名 → moj_lawyers 列。同名多筆用 current_firm 前綴消歧。
    回傳 (row 或 None, reason)"""
    cands = moj_by_name.get(alumnus['name'], [])
    if not cands:
        return None, 'no_match'
    if len(cands) == 1:
        return cands[0], 'unique'
    firm = (alumnus.get('current_firm') or '').strip()
    if firm:
        hit = [c for c in cands
               if c.get('office_normalized') and (
                   c['office_normalized'].startswith(firm) or firm.startswith(c['office_normalized']))]
        if len(hit) == 1:
            return hit[0], 'firm_disambiguated'
    return None, f'ambiguous_x{len(cands)}'


# 一人所 firm_key 口徑同 mig 060 view / 前端 firmKeyRe
SOLO_FIRM_KEY_RE = re.compile(r'^(.+?(?:法律|律師)事務所)')


def is_solo_leader(name, office_norm):
    """一人所唯一律師＝所長（2026-07-08 拍板；口徑＝mig 060 moj_solo_firm_lawyers）。
    逐位 live 查 view（而非預載），避免吃到本輪回寫 moj_lawyers 前的舊狀態。"""
    if not office_norm or '事務所' not in office_norm:
        return False
    m = SOLO_FIRM_KEY_RE.match(office_norm)
    key = m.group(1) if m else office_norm
    try:
        rows = sb_get(f'moj_solo_firm_lawyers?select=name&firm_key=eq.{quote(key)}&limit=1')
        return bool(rows) and rows[0]['name'] == name
    except requests.RequestException:
        return False  # 查不到就維持保守分類，下輪再試


def is_marked_leader(name, office_norm):
    """前台 admin 標註所長（mig 061 firm_leader_overrides）→ 視同自行開業。
    firm_name 與現職所互為前綴即算（口徑同前端 getFirmLeaders 的分所合併）。"""
    if not office_norm:
        return False
    try:
        rows = sb_get(f'firm_leader_overrides?select=firm_name&lawyer_name=eq.{quote(name)}')
        return any(r.get('firm_name') and (
            office_norm.startswith(r['firm_name']) or r['firm_name'].startswith(office_norm)
        ) for r in rows)
    except requests.RequestException:
        return False  # 查不到就維持保守分類，下輪再試


def classify(name, office_norm, current_category):
    """由事務所名推分類（安全規則；cohort/recent 特例在外層處理）"""
    if not office_norm:
        return 'no_office'
    if office_norm.startswith('喆律'):
        # 仍掛喆律：可能是轉合署(cohort)或甫離職未異動(recent)，維持原分類
        return current_category if current_category in ('cohort', 'recent') else 'cohort'
    if office_norm.startswith(name):
        return 'own_firm'  # 例：謝淯婷律師事務所
    if is_marked_leader(name, office_norm):
        return 'own_firm'  # 前台 admin 標為所長（firm_leader_overrides）＝自行開業
    if is_solo_leader(name, office_norm):
        return 'own_firm'  # 一人所唯一律師＝所長，例：蔡愷凌／均凌理韜
    if ('事務所' not in office_norm) and ('法律' not in office_norm):
        return 'inhouse'   # 例：元上工程股份有限公司
    return 'law_firm'


# 這些轉移可自動套用；其餘（尤其涉及 cohort / not_registered 的）只報告
AUTO_APPLY = {
    ('recent', 'law_firm'), ('recent', 'own_firm'), ('recent', 'inhouse'), ('recent', 'no_office'),
    ('law_firm', 'own_firm'), ('law_firm', 'inhouse'), ('law_firm', 'no_office'),
    ('own_firm', 'law_firm'), ('own_firm', 'inhouse'), ('own_firm', 'no_office'),
    ('inhouse', 'law_firm'), ('inhouse', 'own_firm'), ('inhouse', 'no_office'),
    ('no_office', 'law_firm'), ('no_office', 'own_firm'), ('no_office', 'inhouse'),
}


def main(limit=None, dry_run=False, only_name=None):
    print('[1/4] 載入校友名單...')
    alumni = sb_get('zhelu_alumni?select=id,name,category,current_firm,current_region,note,moj_exclude&order=id')
    print(f'  共 {len(alumni)} 位校友')
    if only_name:
        alumni = [a for a in alumni if a['name'] == only_name]
        print(f'  只處理 {only_name}：找到 {len(alumni)} 位')
        if not alumni:
            print(f'  ! zhelu_alumni 查無「{only_name}」，結束')
            return
    if limit:
        alumni = alumni[:limit]
        print(f'  限制處理 {limit} 位')

    print('[2/4] 解析 MOJ 名冊對應...')
    names = sorted({a['name'] for a in alumni})
    in_list = ','.join(f'"{n}"' for n in names)
    moj_rows = sb_get(
        f'moj_lawyers?select=lic_no,name,office,office_normalized,main_region,state_desc'
        f'&name=in.({quote(in_list)})&limit=1000')
    moj_by_name = {}
    for r in moj_rows:
        moj_by_name.setdefault(r['name'], []).append(r)

    print('[3/4] 逐位問 MOJ API...')
    t0 = time.time()
    stats = {'moj_changed': 0, 'alumni_updated': 0, 'skipped': 0, 'api_miss': 0}
    reports = []  # 需要人工看的事項

    for i, a in enumerate(alumni, 1):
        tag = f'{a["name"]}(#{a["id"]})'
        if a.get('moj_exclude'):
            # MOJ 同名非本人（mig 067 前台標註）：完全不比對、不回寫，避免把別人的現職寫回來
            print(f'  跳過: {tag} 已標「同名非本人」(moj_exclude)', flush=True)
            stats['skipped'] += 1
            continue
        moj, why = resolve_lic(a, moj_by_name)

        if moj is None:
            if why == 'no_match':
                if a['category'] == 'not_registered':
                    pass  # 本來就無登錄，正常
                else:
                    reports.append(f'⚠ {tag} 現行名冊查無（原分類 {a["category"]}）→ 未自動改，請人工確認')
            else:
                reports.append(f'⚠ {tag} 同名多筆無法消歧（{why}），已跳過；'
                               f'可把 current_firm 填成正確事務所前綴來消歧')
            stats['skipped'] += 1
            continue

        data, st = query_lic_status(moj['lic_no'])
        if data is None:
            if st == 'gone':
                # 名冊已移除（註銷/停止登錄）。甫離職(recent)本來就在等這個訊號 → 自動轉；
                # 其他分類（尤其 cohort）除名是大事，只報告請人工確認
                if a['category'] == 'not_registered':
                    pass  # 已是無登錄，moj_lawyers 舊列殘留造成的重複訊號，不再報告
                elif a['category'] == 'recent':
                    upd = {'category': 'not_registered', 'current_firm': None,
                           'current_region': None,
                           'updated_at': datetime.now(timezone.utc).isoformat()}
                    print(f'  轉類: {tag} recent → not_registered（名冊已移除 {moj["lic_no"]}）', flush=True)
                    if dry_run:
                        print(f'  [dry-run] zhelu_alumni #{a["id"]} ← {upd}', flush=True)
                        stats['alumni_updated'] += 1
                    elif sb_patch(f'zhelu_alumni?id=eq.{a["id"]}', upd):
                        stats['alumni_updated'] += 1
                else:
                    reports.append(f'🔔 {tag} 名冊已移除（{moj["lic_no"]}，原分類 {a["category"]}）'
                                   f'→ 建議轉 not_registered，未自動改')
            else:
                reports.append(f'⚠ {tag} MOJ API 連線失敗（{moj["lic_no"]}），本輪未動')
                stats['api_miss'] += 1
            continue

        # --- 更新 moj_lawyers（讓 trigger 記異動）---
        new_norm = normalize_office(data.get('office'))
        new_state = data.get('statedesc') or None
        payload = {}
        if new_norm != moj.get('office_normalized'):
            payload['office'] = data.get('office')
            payload['office_normalized'] = new_norm
        if new_state is not None and new_state != moj.get('state_desc'):
            payload['state'] = str(data.get('state')) if data.get('state') is not None else None
            payload['state_desc'] = new_state
        if payload:
            print(f'  MOJ 異動: {tag} {moj.get("office_normalized") or "-"} → {new_norm or "-"}'
                  + (f' / 狀態 → {new_state}' if 'state_desc' in payload else ''), flush=True)
            if not dry_run and sb_patch(f'moj_lawyers?lic_no=eq.{quote(moj["lic_no"])}', payload):
                stats['moj_changed'] += 1
                time.sleep(1)
            elif dry_run:
                stats['moj_changed'] += 1

        # --- 回寫 zhelu_alumni ---
        upd = {}
        if new_norm != (a.get('current_firm') or None):
            upd['current_firm'] = new_norm
        region = moj.get('main_region')
        if region and region != a.get('current_region'):
            upd['current_region'] = region

        proposed = classify(a['name'], new_norm, a['category'])
        if proposed != a['category']:
            if a['category'] == 'cohort':
                reports.append(f'🔔 {tag} 是轉合署(cohort)但 MOJ 事務所已變為'
                               f'「{new_norm or "（空）"}」→ 業務分類請人工確認')
            elif (a['category'], proposed) in AUTO_APPLY:
                upd['category'] = proposed
                print(f'  轉類: {tag} {a["category"]} → {proposed}（{new_norm or "-"}）', flush=True)
            else:
                reports.append(f'🔔 {tag} 建議轉類 {a["category"]} → {proposed}'
                               f'（{new_norm or "（空）"}）→ 未自動改，請人工確認')

        if upd:
            upd['updated_at'] = datetime.now(timezone.utc).isoformat()
            if dry_run:
                print(f'  [dry-run] zhelu_alumni #{a["id"]} ← {upd}', flush=True)
                stats['alumni_updated'] += 1
            elif sb_patch(f'zhelu_alumni?id=eq.{a["id"]}', upd):
                stats['alumni_updated'] += 1

        if i % 10 == 0:
            print(f'  [{i}/{len(alumni)}] 已耗時 {(time.time()-t0)/60:.1f} 分鐘', flush=True)
        time.sleep(0.2)

    print('\n[4/4] === 完成 ===')
    print(f'處理: {len(alumni)} 位' + ('（dry-run，未寫入）' if dry_run else ''))
    print(f'moj_lawyers 異動: {stats["moj_changed"]} 筆')
    print(f'zhelu_alumni 更新: {stats["alumni_updated"]} 筆')
    print(f'跳過（查無/同名）: {stats["skipped"]} 筆 / API 失敗: {stats["api_miss"]} 筆')
    print(f'耗時: {(time.time()-t0)/60:.1f} 分鐘')
    if reports:
        print('\n=== 需人工確認 ===')
        for line in reports:
            print(line)


if __name__ == '__main__':
    args = sys.argv[1:]
    _dry = '--dry-run' in args
    args = [x for x in args if x != '--dry-run']
    _name = None
    if '--name' in args:
        _i = args.index('--name')
        _name = args[_i + 1]
        args = args[:_i] + args[_i + 2:]
    _limit = int(args[0]) if args else None
    main(limit=_limit, dry_run=_dry, only_name=_name)
