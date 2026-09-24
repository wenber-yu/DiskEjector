#!/usr/bin/env python3
"""在**伪终端**里跑一个命令，给它的每一行输出打上相对时间戳，重建事件时间线。

## 为什么需要它（2026-09-21）

要回答「主 actor 被**谁**占住了」，就必须知道**每条测试自己什么时候开始**。
本项目已有两样东西都**给不出**这个数：

- `✔ Test X passed after N seconds.`（swift-testing 自带）
- `--xunit-output` 的 `<testcase time="N">`

两者都是「**完成时刻**距 run 开始」的墙钟（实测单条值 ≈ 整轮值，
见 `Scripts/lib/test_timings.sh` 抬头）—— 测试并行执行，早开始晚结束的那条
会把整轮时长算进去。**完成时刻相同的一簇测试，无法区分谁先谁后。**

而 `swift test -v` 会**按发生顺序**逐条打印事件行：

    ◇ Test run started.
    ◇ Test 退出行不染红() started.
    ✔ Test 退出行不染红() passed after 0.179 seconds.

事件**本身**没有时刻，但它们的**到达顺序**是真实的 ⇒ 只要在管道上逐行打点，
就拿到了「每条测试 started 的墙钟时刻」——**不用改任何一个测试文件**。

## ⚠️ 唯一致命风险：stdout 缓冲（本装置第一版就死在这里）

被**管道**接住时 stdout 不再是 TTY ⇒ 变成**块缓冲**：事件不是「发生即到达」，
而是攒够一个缓冲区才吐出来。那时打到的时刻是**冲刷时刻**，不是事件时刻。

实测（2026-09-21，第一版直接 `cmd | stamp_lines.py`）：
`MenuPopoverLayoutTests` 8 条测试的 9 行结果**全部**打在同一个时刻
（相对 run 开始全是 `0.000`，而 swift-testing 自己报的 N 是 0.149–0.256）
⇒ 数据**完全不可用**，而它与「事件真的同时发生」看起来一样。

⇒ 解法是**给子进程一个伪终端**（pty）：子进程以为自己在跟终端说话，
回到**行缓冲**，事件发生即到达。本脚本用 Python 的 `pty` 模块直接起子进程，
不用外部的 `script`（`script -q /dev/null` 会在输出头部混进 `^D`/退格控制字节，
且 pty 的 `onlcr` 会把 `\n` 变成 `\r\n` —— 后者本脚本顺手剥掉）。

⇒ **仍必须对拍自证**：把「打点时刻 − run 开始时刻」与 `passed after N` 里的 `N`
逐条比对，两者应当接近（实测中位差 < 50ms）；差得远就说明缓冲/时钟有问题，
本次数据作废。对拍由 `Tools/probe/test_timeline.py` 自动做并打印 ——
不在本脚本里，因为本脚本只负责「忠实打点」，不该混进判据。

## 用法

    python3 Tools/probe/stamp_lines.py <命令> [参数...] > 时间线.log
    # 例如：
    python3 Tools/probe/stamp_lines.py swift test -v > .build/probe/timeline.log

输出每行：`<相对秒>\t<原行>`（相对秒保留 6 位小数，从**子进程启动前**算起）。

⚠️ 退出码是**子进程的**退出码（`swift test` 红时本脚本也非 0）。
⚠️ 顺带剥掉 ANSI 转义序列 —— pty 让子进程认为自己在终端上，会加颜色，
而颜色码会把下游的 `^◇ Test` 之类前缀判据打掉。
"""

import errno
import os
import pty
import re
import subprocess
import sys
import time

_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def main() -> int:
    argv = sys.argv[1:]
    if not argv:
        sys.stderr.write("用法：python3 Tools/probe/stamp_lines.py <命令> [参数...]\n")
        return 2

    master, slave = pty.openpty()
    t0 = time.time()
    proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)

    out = sys.stdout
    buf = b""
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            # 子进程退出后 master 侧可能报 EIO（Linux）/ 直接返回 b''（macOS）
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        # 打点要**紧贴** read 返回，中间不做任何别的事
        t = time.time() - t0
        buf += chunk
        while True:
            nl = buf.find(b"\n")
            if nl < 0:
                break
            raw = buf[: nl + 1]
            buf = buf[nl + 1 :]
            text = raw.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
            out.write("%.6f\t%s\n" % (t, _ANSI.sub("", text)))
            out.flush()
    if buf:
        text = buf.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
        if text:
            out.write("%.6f\t%s\n" % (time.time() - t0, _ANSI.sub("", text)))
            out.flush()
    os.close(master)
    return proc.wait()


if __name__ == "__main__":
    sys.exit(main())
