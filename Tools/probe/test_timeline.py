#!/usr/bin/env python3
"""读 `stamp_lines.py` 产出的时间线日志，回答「**这轮测试卡在哪儿**」。

## 它回答的问题（以及为什么现有的两个数回答不了）

本项目已有两样东西能给「最慢的测试」：

- `✔ Test X passed after N seconds.`（swift-testing 自带）
- `--xunit-output` 的 `<testcase time="N">`

两者都是「**完成时刻**距 run 开始」的墙钟 —— 测试并行执行，早开始晚结束的那条
会把整轮时长算进去。于是**完成时刻相同的一簇测试，无法区分谁先谁后**，
也就**看不出「这轮到底卡在哪个时间窗」**（`Scripts/lib/test_timings.sh` 抬头写着同一件事）。

本脚本换一个量：**完成事件在墙钟上的分布**。它一眼能分开三种形状：

| 形状 | 含义 |
|---|---|
| 完成事件均匀铺开 | 各测试各跑各的，没有串行瓶颈 |
| **一长段零完成 + 随后成批完成** | 有一串**很重**的活占着某个串行资源，轻的都在后面排队 |
| 全程零完成窗口都很短，但整轮很长 | 瓶颈在单条极慢的测试上 |

## ⚠️ 必须先过「装置自证」，否则一切数字作废

`stamp_lines.py` 靠**伪终端**让子进程行缓冲。若哪天它退化成块缓冲，时间戳会变成
「冲刷时刻」——**所有事件挤在同一时刻**，而那个形状**看起来正好像「成批完成」**。
⇒ 本脚本拿 `passed after N`（swift-testing **自己**量的完成时刻）与打点时刻逐条对拍：
两者应当接近。差得远就直接把结论标成不可信，**不打印任何「发现」**。

## 用法

    python3 Tools/probe/stamp_lines.py swift test -v > 时间线.log
    python3 Tools/probe/test_timeline.py 时间线.log [--top 5]

退出码：0 = 数据可信；3 = 装置自证失败（数据作废）。**不作判据用**（它是诊断输出）。
"""

import re
import statistics
import sys

# ⚠️ `run` 要排除：`◇ Test run started.` 与 `◇ Test <名字> started.` **同形**
# （本脚本第一版就把它数成了一条测试 ⇒ 报出 `started 20` 而汇总行声明 19，
#  自证字段自己把矛盾摆出来了 —— 这正是「让数字自己说话」的用处）。
STARTED = re.compile(r"^◇ Test (?!run started)(.*) started\.$")
FINISHED = re.compile(r"^[✔✘]\s+Test\s+(.*?)\s+(passed|failed) after ([0-9.]+) seconds")
DECLARED = re.compile(r"Test run with (\d+) tests in ")
RUN_STARTED = "◇ Test run started."

# 对拍容差：实测中位差 +0.005s、最大 0.021s（2026-09-21）。留一个数量级的余量。
TOLERANCE = 0.25


def load(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            stamp, _, rest = line.partition("\t")
            try:
                rows.append((float(stamp), rest.rstrip("\n")))
            except ValueError:
                continue  # 不是打点行（正常不该有）
    return rows


def main() -> int:
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(__doc__.split("## 用法")[1].strip() + "\n")
        return 2
    path = args[0]
    top_n = 5
    if "--top" in args:
        top_n = int(args[args.index("--top") + 1])

    rows = load(path)
    if not rows:
        print("SELFCHECK-FAIL：一行都没读到 —— 路径错了，或日志不是 stamp_lines.py 产出的")
        return 3
    origin = next((t for t, r in rows if r.startswith(RUN_STARTED)), None)
    if origin is None:
        print("SELFCHECK-FAIL：日志里没有 `◇ Test run started.` —— 没加 `-v`？本次作废")
        return 3
    rows = [(t - origin, r) for t, r in rows]

    started = [r for _, r in rows if STARTED.match(r)]
    finished = [(t, FINISHED.match(r).group(1), float(FINISHED.match(r).group(3)))
                for t, r in rows if FINISHED.match(r) and "run with" not in FINISHED.match(r).group(1)]
    declared = [m.group(1) for _, r in rows if (m := DECLARED.search(r))]
    span = max(t for t, _ in rows)

    # ---- 装置自证 ----
    diffs = [t - n for t, _, n in finished]
    worst = max(abs(d) for d in diffs) if diffs else float("nan")
    median = statistics.median(diffs) if diffs else float("nan")

    print(f"日志 {len(rows)} 行 ｜ started {len(started)} ｜ finished {len(finished)} "
          f"｜ 汇总行声明 {declared[-1] if declared else '?'} ｜ 整轮 {span:.3f}s")
    print(f"对拍（打点时刻 − swift-testing 自报的完成时刻）：中位 {median:+.3f}s、"
          f"最大 |差| {worst:.3f}s（容差 {TOLERANCE}s）")
    if not (len(started) > 0 and len(finished) > 0 and declared):
        print("SELFCHECK-FAIL：started / finished / 声明数 有一项为空 —— 正则与日志格式对不上，本次作废")
        return 3
    if worst > TOLERANCE:
        print(f"SELFCHECK-FAIL：打点时刻与自报完成时刻差到 {worst:.3f}s ⇒ "
              f"**时间戳不是事件时刻**（多半是块缓冲，见 stamp_lines.py 抬头）⇒ 本次数据作废")
        return 3

    # ---- 形状 ----
    times = sorted(t for t, _, _ in finished)
    gaps = []
    for a, b in zip(times, times[1:]):
        gaps.append((b - a, a, b))
    longest = max(gaps) if gaps else (0.0, 0.0, 0.0)
    print(f"\n最长「零完成」窗口：{longest[0]:.3f}s（{longest[1]:.3f}s → {longest[2]:.3f}s）")
    print("  ⚠️ 口径：这段窗口里**别的输出不一定没有**（设计稿/版式的诊断行会打进来）——")
    print("     它只说明「这段时间没有任何测试完成」。窗口内若有诊断行，那是**重活在跑**，不是死锁。")

    # 完成事件按时间等分 6 段，看密度
    print("\n完成事件密度（按整轮时长等分 6 段）：")
    if span > 0:
        width = span / 6
        for i in range(6):
            lo, hi = i * width, (i + 1) * width
            n = sum(1 for t in times if lo <= t < hi or (i == 5 and t == hi))
            print(f"  {lo:>6.2f}–{hi:>6.2f}s  {n:>4}  {'█' * min(60, n)}")

    print(f"\n完成时刻最晚的 {top_n} 条（口径同 `Scripts/lib/test_timings.sh`：**完成时刻**，"
          f"含排队等待，≠ 该测试自身耗时）：")
    for t, name, n in sorted(finished, key=lambda x: -x[0])[:top_n]:
        print(f"  {t:>8.3f}s  {name[:80]}")

    print("\n⚠️ 下一步（**别直接下结论**）：窗口内有哪些测试在跑，本日志答不出来 ——")
    print("   试 `swift test --filter <套件>` 单独跑一遍对照；若窗口在该套件里**单独复现**，")
    print("   就是它；若不复现，换 `--skip <套件>` 做排除。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
