# -*- coding: utf-8 -*-
"""TIPO 專利商標開放資料 FTPS 下載器 — 抽每案代理人欄位

資料源：ftps://ftp.tipo.gov.tw（990 implicit TLS、匿名、同 IP 限 3 連線）
目錄結構：/{dataset}/{民國年}/{dataset}_{申請案號}.xml，1 檔 1 案
輸出：scripts/.tipo_agents_work/{dataset}_{yr}.jsonl
      每行 {"no": 申請案號, "d": 申請日, "agents": [[姓名, 地址], ...]}
      （無代理人的案也寫一行 agents=[]，兼作 done-log 供續跑）

用法：
  python tipo_agent_fetch.py            # 跑預設全部 target（可中斷續跑）
  python tipo_agent_fetch.py TmarkAppl/114   # 只跑指定 dataset/年
"""
import io
import os
import re
import ssl
import sys
import json
import time
import socket
import threading
import queue
import xml.etree.ElementTree as ET
from ftplib import FTP_TLS, error_temp

sys.stdout.reconfigure(line_buffering=True, encoding='utf-8')

HOST = 'ftp.tipo.gov.tw'
PORT = 990
N_WORKERS = 3  # 伺服器同 IP 上限 3 條
WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.tipo_agents_work')
os.makedirs(WORK_DIR, exist_ok=True)

TARGETS = [
    'TmarkAppl/112', 'TmarkAppl/113', 'TmarkAppl/114', 'TmarkAppl/115',
    'PatentPub/112', 'PatentPub/113', 'PatentPub/114', 'PatentPub/115',
    'PatentRightsM/112', 'PatentRightsM/113', 'PatentRightsM/114', 'PatentRightsM/115',
    'PatentRightsD/112', 'PatentRightsD/113', 'PatentRightsD/114', 'PatentRightsD/115',
]


class ImplicitFTPS(FTP_TLS):
    """Serv-U implicit FTPS：連上即包 TLS"""
    def connect(self, host='', port=0, timeout=-999, source_address=None):
        if host: self.host = host
        if port: self.port = port
        if timeout != -999: self.timeout = timeout
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.af = self.sock.family
        self.sock = self.context.wrap_socket(self.sock, server_hostname=self.host)
        self.file = self.sock.makefile('r', encoding=self.encoding)
        self.welcome = self.getresp()
        return self.welcome


def mk_conn(cwd):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    f = ImplicitFTPS(context=ctx)
    f.connect(HOST, PORT, timeout=120)
    f.login()
    f.prot_p()
    f.cwd(cwd)
    return f


APPL_NO_RE = re.compile(r'_(\d+(?:D\d+)?)\.xml$')  # 設計案含衍生設計後綴（112300034D01）


def parse_case(data):
    """從單案 XML 抽 (申請日, [(代理人姓名, 地址), ...])；容錯：解析失敗回 None"""
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        # 少數檔有非法字元，清掉控制字元重試
        try:
            cleaned = re.sub(rb'[\x00-\x08\x0b\x0c\x0e-\x1f]', b'', data)
            root = ET.fromstring(cleaned)
        except ET.ParseError:
            return None
    d = root.findtext('.//appl-date') or ''
    agents = []
    for ag in root.iter('agent'):
        name = (ag.findtext('chinese-name') or '').strip()
        addr = (ag.findtext('address') or '').strip()
        if name:
            agents.append([name, addr])
    return d, agents


def run_target(target):
    ds, yr = target.split('/')
    out_path = os.path.join(WORK_DIR, f'{ds}_{yr}.jsonl')
    done = set()
    if os.path.exists(out_path):
        with open(out_path, encoding='utf-8') as fh:
            for line in fh:
                try:
                    done.add(json.loads(line)['no'])
                except Exception:
                    pass
    cwd = f'/{ds}/{yr}'
    print(f'[{target}] 列目錄...')
    lister = mk_conn(cwd)
    names = [n for n in lister.nlst() if n.lower().endswith('.xml')]
    lister.quit()
    todo = []
    for n in names:
        m = APPL_NO_RE.search(n)
        if m and m.group(1) not in done:
            todo.append(n)
    print(f'[{target}] 總 {len(names)} 檔，已完成 {len(done)}，待抓 {len(todo)}')
    if not todo:
        return 0, 0

    q = queue.Queue()
    for n in todo:
        q.put(n)
    lock = threading.Lock()
    out_fh = open(out_path, 'a', encoding='utf-8')
    stats = {'ok': 0, 'fail': 0}
    t0 = time.time()

    def worker():
        conn = None
        while True:
            try:
                name = q.get_nowait()
            except queue.Empty:
                break
            no = APPL_NO_RE.search(name).group(1)
            ok = False
            for attempt in range(4):
                try:
                    if conn is None:
                        conn = mk_conn(cwd)
                    buf = io.BytesIO()
                    conn.retrbinary(f'RETR {name}', buf.write)
                    parsed = parse_case(buf.getvalue())
                    row = {'no': no, 'd': parsed[0] if parsed else None,
                           'agents': parsed[1] if parsed else []}
                    if parsed is None:
                        row['parse_err'] = 1
                    with lock:
                        out_fh.write(json.dumps(row, ensure_ascii=False) + '\n')
                        stats['ok'] += 1
                    ok = True
                    break
                except error_temp as e:
                    # 421 連線數滿：退避重連
                    try:
                        conn.quit()
                    except Exception:
                        pass
                    conn = None
                    time.sleep(5 + attempt * 10)
                except Exception:
                    try:
                        conn.quit()
                    except Exception:
                        pass
                    conn = None
                    time.sleep(2 + attempt * 5)
            if not ok:
                with lock:
                    stats['fail'] += 1
                    print(f'[{target}] FAIL {name}')
            n_done = stats['ok'] + stats['fail']
            if n_done % 2000 == 0:
                dt = time.time() - t0
                rate = n_done / dt if dt else 0
                eta_min = (len(todo) - n_done) / rate / 60 if rate else -1
                with lock:
                    print(f'[{target}] {n_done}/{len(todo)}  {rate:.1f} 檔/s  ETA {eta_min:.0f} 分  (fail {stats["fail"]})')
        if conn is not None:
            try:
                conn.quit()
            except Exception:
                pass

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(N_WORKERS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    out_fh.flush()
    out_fh.close()
    dt = time.time() - t0
    print(f'[{target}] 完成：ok={stats["ok"]} fail={stats["fail"]} 耗時 {dt/60:.1f} 分')
    return stats['ok'], stats['fail']


def main():
    targets = sys.argv[1:] or TARGETS
    total_ok = total_fail = 0
    for tgt in targets:
        for attempt in range(3):
            try:
                ok, fail = run_target(tgt)
                total_ok += ok
                total_fail += fail
                break
            except Exception as e:
                print(f'[{tgt}] target 層例外（{type(e).__name__}: {e}），60s 後重試（可續跑）')
                time.sleep(60)
        else:
            print(f'[{tgt}] 放棄，之後可重跑續抓')
            total_fail += 1
    print(f'=== 全部結束 ok={total_ok} fail={total_fail} ===')
    if total_fail > total_ok * 0.01:
        sys.exit(1)


if __name__ == '__main__':
    main()
