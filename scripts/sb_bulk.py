"""Supabase 全量重建的共用上傳器（DELETE + 分批 upsert，含重試與筆數驗證）。

背景：「DELETE 全表 → 大批次 POST、不重試」的寫法，遇上 Supabase 偶發連線重置
（Windows 上是 WinError 10054）會讓表停在「已清空、只灌一部分」的殘缺狀態，
而且是靜默的——下游步驟照跑，錯誤數字會一路流到頁面與部署。

本模組的三道防線：
  1. 小批次（預設 500 列）+ 每批最多 6 次重試、指數 backoff、每批新連線；
  2. upsert（on_conflict）而非純 INSERT——連線在「伺服器已寫入、回應遺失」時中斷，
     重試才不會撞 UNIQUE 409；
  3. 收尾驗證實際筆數，不符就 raise，讓呼叫端 exit 1、中止下游部署。

rows 為空時一律拒絕執行，避免把表清空。
"""
import time

import requests


def _with_retry(desc, fn, tries=6, ok=(200, 201, 204)):
    """回傳 fn() 的 response；連線層例外與 5xx 都重試。

    ok 要帶 206：帶 limit 的 count 查詢回的是 206 Partial Content。
    """
    for attempt in range(tries):
        try:
            r = fn()
            if r.status_code in ok:
                return r
            # 4xx 多半是資料/schema 問題，重試無益；5xx 與 408 才重試
            if r.status_code < 500 and r.status_code != 408:
                raise RuntimeError(f'{desc} 失敗 {r.status_code}: {r.text[:300]}')
            print(f'  {desc}：HTTP {r.status_code}（第 {attempt + 1} 次）', flush=True)
        except requests.exceptions.RequestException as e:
            print(f'  {desc}：{type(e).__name__}（第 {attempt + 1} 次）', flush=True)
        time.sleep(3 * (attempt + 1))
    raise RuntimeError(f'{desc} 重試 {tries} 次仍失敗')


def count(base_url, head, table, flt=''):
    q = f'{base_url}/rest/v1/{table}?select=id&limit=1' + (f'&{flt}' if flt else '')
    r = _with_retry(f'count {table}', lambda: requests.get(
        q, headers={**head, 'Prefer': 'count=exact'}, timeout=60),
        ok=(200, 206))
    return int(r.headers['Content-Range'].split('/')[1])


def rebuild(base_url, head, table, rows, on_conflict, delete_filter,
            batch=500, tries=6):
    """全量重建 table（delete_filter 界定範圍），回傳最終筆數。

    delete_filter 例：'id=gt.0'、'etype=eq.high_value'。
    on_conflict 為表上唯一鍵欄位（逗號分隔），upsert 用。
    """
    if not rows:
        raise RuntimeError(f'{table}: rows 是空的，拒絕清空表')

    _with_retry(f'DELETE {table}', lambda: requests.delete(
        f'{base_url}/rest/v1/{table}?{delete_filter}', headers=head, timeout=180))
    print(f'DELETE {table} ({delete_filter}) ok', flush=True)

    post_head = {**head, 'Content-Type': 'application/json',
                 'Prefer': 'return=minimal,resolution=merge-duplicates',
                 'Connection': 'close'}
    url = f'{base_url}/rest/v1/{table}?on_conflict={on_conflict}'
    done = 0
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        _with_retry(f'insert {table} @{i}', lambda c=chunk: requests.post(
            url, headers=post_head, json=c, timeout=180), tries=tries)
        done += len(chunk)
        if (i // batch) % 20 == 0 or done == len(rows):
            print(f'  insert {done}/{len(rows)}', flush=True)

    final = count(base_url, head, table, delete_filter.replace('id=gt.0', ''))
    if final != len(rows):
        raise RuntimeError(f'{table} 筆數驗證失敗：DB {final} 列 ≠ 預期 {len(rows)} 列')
    print(f'{table} 上傳完成並驗證：{final} 列', flush=True)
    return final
