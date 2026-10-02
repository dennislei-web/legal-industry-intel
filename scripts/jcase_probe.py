# -*- coding: utf-8 -*-
"""Step 0 實測：下載單月裁判書月包，全文件掃 JCASE（字別）×文件類型分佈。
產出：
  .judgment_work/{ym}_jcase_dist.json  — {jcase: {'n': 件數, '判決': n, '裁定': n, '其他': n}}
用法：python jcase_probe.py 202001
沿用 judgment_stats.py 的下載/法院正規化/文件類型函式；不動任何 DB。
"""
import sys, os, json, time, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from judgment_stats import download, extract_month, WORK_DIR, doctype_of  # noqa: E402


def probe(yyyymm):
    rar_path = os.path.join(WORK_DIR, f'{yyyymm}.rar')
    if not os.path.exists(rar_path):
        t0 = time.time()
        download(yyyymm)
        print(f'  下載耗時 {(time.time() - t0) / 60:.1f} 分鐘')
    # 與 judgment_stats.parse() 共用同一個解壓函數（先解到暫存名、成功才改名，防半套目錄）
    fresh = not os.path.isdir(os.path.join(WORK_DIR, yyyymm))
    t0 = time.time()
    extract_dir = extract_month(yyyymm)
    if fresh:
        print(f'  解壓耗時 {(time.time() - t0) / 60:.1f} 分鐘')

    t0 = time.time()
    dist = collections.defaultdict(lambda: collections.Counter())
    n = 0
    for root, _dirs, files in os.walk(extract_dir):
        for fn in files:
            if not fn.endswith('.json'):
                continue
            n += 1
            try:
                with open(os.path.join(root, fn), encoding='utf-8-sig') as f:
                    doc = json.load(f)
            except (json.JSONDecodeError, OSError):
                continue
            jcase = (doc.get('JCASE') or '').strip()
            if not jcase:
                continue
            dt = doctype_of((doc.get('JFULL') or '')[:60])
            dist[jcase]['n'] += 1
            dist[jcase][dt] += 1
            if n % 50000 == 0:
                print(f'  ...{n} 檔，{(time.time() - t0) / 60:.1f} 分')
    out = {jc: dict(c) for jc, c in dist.items()}
    out_path = os.path.join(WORK_DIR, f'{yyyymm}_jcase_dist.json')
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False)
    print(f'掃描完成：{n} 檔、{len(out)} 個相異字別、{(time.time() - t0) / 60:.1f} 分鐘 → {out_path}')


if __name__ == '__main__':
    probe(sys.argv[1])
