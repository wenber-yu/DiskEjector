#!/usr/bin/env python3
"""本地 appcast 服务器：把**每一次请求**记到文件里。

## 为什么需要它

要判「从只读挂载卷运行时，Sparkle 到底有没有真的去取 appcast」。
看界面是不行的 —— 「取了、发现是最新」与「压根没取、界面沿用旧状态」
在界面上都可能表现为「已是最新版本」。**请求日志才是硬判据**。

## 装置自证

① 启动时先自测一次（自己请求自己），确认**记录通路本身**是通的 ——
   否则「日志里没有请求」会被误读成「Sparkle 没发请求」，而其实是记录坏了；
② 每条记录带**墙上时间戳**，好与界面变化的时间对齐；
③ 同时把 User-Agent 记下来 —— 能区分「这个请求是 Sparkle 发的」还是别的东西发的。
"""

import http.server
import os
import socketserver
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "feed-hits.log")


# 限速（字节/秒）：只作用于**归档**（.zip / .dmg），appcast 本身不限速。
#
# ## 为什么需要它
#
# 第 32 行要抓的是「`fraction == nil` 那一瞬」（下载已开始、第一格进度还没到）。
# 本地 2.6MB 会在几十毫秒内下完 ⇒ 那一瞬根本采不到（`axtext --watch` 是 0.15s 一拍）。
# 把归档限速到几百 KB/s，下载就能持续好几秒，那一瞬才**落得进采样窗口**。
#
# ⚠️ 默认**不限速**（`THROTTLE = 0`）—— §8.94 那次实验依赖原行为，不能改它。
THROTTLE = 0
ARCHIVE_EXTS = (".zip", ".dmg", ".tar.gz", ".pkg")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def do_GET(self):
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        ua = self.headers.get("User-Agent", "?")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{ts}\tGET {self.path}\tUA={ua}\n")
            f.flush()
        print(f"[{ts}] GET {self.path}  UA={ua[:70]}", flush=True)

        if THROTTLE and self.path.lower().split("?")[0].endswith(ARCHIVE_EXTS):
            self._send_throttled()
            return
        super().do_GET()

    def _send_throttled(self) -> None:
        """分块发送归档，块间 sleep —— 让下载持续足够久，好让采样窗口能落进去。"""
        rel = self.path.lstrip("/").split("?")[0]
        path = os.path.join(HERE, rel)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()

        chunk = 32 * 1024
        per_chunk = chunk / THROTTLE  # 每块应耗时（秒）
        sent = 0
        t_start = time.time()
        with open(path, "rb") as f:
            while True:
                data = f.read(chunk)
                if not data:
                    break
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                except Exception as exc:  # 客户端提前断开（例如取消了下载）
                    print(f"  [throttle] 客户端断开 sent={sent} ({exc})", flush=True)
                    return
                sent += len(data)
                time.sleep(per_chunk)
        print(
            f"  [throttle] sent {sent}/{size} bytes in "
            f"{time.time() - t_start:.1f}s（限速 {THROTTLE} B/s）",
            flush=True,
        )

    def log_message(self, fmt, *args):  # 关掉默认日志，避免与上面的重复
        pass


def main() -> int:
    global THROTTLE
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    # 第二个参数 = 归档限速（字节/秒），不给就**不限速**（兼容 §8.94 那次实验）
    if len(sys.argv) > 2:
        THROTTLE = int(sys.argv[2])
    if os.path.exists(LOG):
        os.remove(LOG)

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
        # ① 自证：先自己打自己一次，确认记录通路是通的
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        time.sleep(0.3)
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/__selfcheck__", timeout=3).read()
        except Exception:
            pass
        time.sleep(0.3)
        with open(LOG, encoding="utf-8") as f:
            first = f.read()
        if "__selfcheck__" not in first:
            print("SELFCHECK-FAIL：自己请求自己都没记下来 ⇒ 记录通路坏了，本次实验作废")
            return 3
        throttle_note = f"归档限速 {THROTTLE} B/s" if THROTTLE else "不限速"
        print(f"SELFCHECK ok（记录通路已验证）\nserving {HERE} on 127.0.0.1:{port}（{throttle_note}）")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    sys.exit(main())
