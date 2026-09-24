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

## 用法

```bash
python3 Tools/probe/feedsrv.py <port> [归档限速B/s] [--log <路径>]
```

`--log` 可选。⚠️ **默认必须仍是** `Tools/probe/feed-hits.log`（脚本自己所在目录）——
有人照旧用法去那儿找日志。它只是**入库目录里必然产生的脏文件**，所以实验方
可以用 `--log .build/probe/<轮次>/feed-hits.log` 把它指到 `.build/` 下
（`.build/` 已在 `.gitignore` 里），跑完 `git status` 就是干净的。
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
    global THROTTLE, LOG

    # `--log <路径>` 是**可选**的：位置参数（port / 限速）的语义一个字都不能动，
    # 否则旧用法会静默跑歪。所以只把 `--log*` 从 argv 里摘出来，剩下的仍按位置解析。
    argv = sys.argv[1:]
    positional: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--log":
            if i + 1 >= len(argv):
                print("用法：feedsrv.py <port> [归档限速B/s] [--log <路径>]")
                return 2
            LOG = os.path.abspath(argv[i + 1])
            i += 2
            continue
        if arg.startswith("--log="):
            LOG = os.path.abspath(arg[len("--log="):])
            i += 1
            continue
        positional.append(arg)
        i += 1

    port = int(positional[0]) if len(positional) > 0 else 8765
    # 第二个参数 = 归档限速（字节/秒），不给就**不限速**（兼容 §8.94 那次实验）
    if len(positional) > 1:
        THROTTLE = int(positional[1])

    # `--log` 常指向 `.build/probe/<轮次>/` 这类还不存在的目录 —— 不建的话
    # 第一条记录就会抛 FileNotFoundError，而 ① 自证会把它误报成「记录通路坏了」。
    log_dir = os.path.dirname(LOG)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
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
        print(f"SELFCHECK ok（记录通路已验证）\nserving {HERE} on 127.0.0.1:{port}"
              f"（{throttle_note}）\nlog → {LOG}")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    sys.exit(main())
