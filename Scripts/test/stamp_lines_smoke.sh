#!/usr/bin/env bash
# =============================================================
# 冒烟：`Tools/probe/stamp_lines.py` 的核心契约 ——
# **打点时刻是「事件时刻」，不是「冲刷时刻」**。
#
# 【为什么这条契约必须被守】
# `stamp_lines.py` 是「谁占住了主 actor / 这轮测试卡在哪」的唯一观测手段
# （背景与它要回答的问题见 `Tools/probe/test_timeline.py` 抬头）。
# 它成立的前提只有一条：**子进程的输出是行缓冲的**。
#
# 而 stdout 一旦是**管道**就变成块缓冲 ⇒ 事件攒够一个缓冲区才吐出来 ⇒
# 打到的时刻是**冲刷时刻**。那时所有事件挤成几坨，而那个形状
# **看起来正好像「成批完成」** —— 也就是**看起来像一条真发现**。
# 2026-09-21 本装置的第一版就是这么死的：`MenuPopoverLayoutTests` 8 条测试的
# 9 行结果**全部**打在相对 run 开始 `0.000s`（而自报的 N 是 0.149–0.256）。
#
# 【判据为什么是「一对」而不是「一条」】
# 只断言「伪终端版拿到了 0.4s 间隔」守不住它 —— 那个断言在「子进程本来就会
# 逐行冲刷」的实现上**同样通过**（那时 pty 是多余的，而 pty 恰恰是本装置
# 唯一的机关）。⇒ 必须配**阴性对照**：同一个子进程、同样的读取方式，
# 只把「伪终端」换成「管道」，间隔必须**塌成 ~0**。
# 两条一起才说明：**是伪终端在起作用**（而不是「子进程碰巧会冲刷」）。
#
# 【本脚本不依赖任何本机路径】
# 解释器逐个**试跑**（`-c 'print(sys.version_info[0])'`）取第一个真能跑的。
# ⚠️ **判据必须是「跑起来的输出」，不能是 `[ -x ]`**（2026-09-21 本机实测踩到）：
#    `/usr/bin/python3` 在本机**存在且可执行**，但它是个 `xcrun` 桩，
#    实际跑起来只打印「You have not agreed to the Xcode license agreements」
#    —— 判「可执行」为真、判「能用」为假，两者逐字不同。
#    （同病根：`git` / `swift` 也被同一个桩挡住。这正是 `Tools/clt_swift_env.sh` 的由来。）
# ⚠️ 不写死 `~/.workbuddy-ai/binaries/python/...`：那是本机专用路径，
#    写进去会让这条门在 CI 上变成「找不到解释器」的红（与代码无关）。
# 候选全不可用 ⇒ **判红并说清是「找不到能跑的解释器」**，不许静默通过。
#
# 【用法】Scripts/test/stamp_lines_smoke.sh
# 退出码：0 = 通过；1 = 未通过。
# =============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAMPER="$REPO_ROOT/Tools/probe/stamp_lines.py"

# 逐个试跑，取第一个**真的能跑**的 python3。
pick_python() {
    local candidate
    for candidate in "${PYTHON:-}" \
        /usr/bin/python3 \
        /Library/Developer/CommandLineTools/usr/bin/python3 \
        "$(command -v python3 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        local out
        if out="$("$candidate" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" \
            && [ "$out" = "3" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! PY="$(pick_python)"; then
    echo "   ✗ 找不到**能跑的** python3（试过 \${PYTHON}、/usr/bin/python3、CLT、PATH）——"
    echo "     本次冒烟**未执行**。⚠️ 注意 `[ -x ]` 为真不等于跑得起来：本机上"
    echo "     /usr/bin/python3 就是被 Xcode 许可桩挡住的（只打印许可警告）。"
    exit 1
fi
echo "   [自证] 解释器：${PY}（$("$PY" --version 2>&1)）"
if [ ! -f "$STAMPER" ]; then
    echo "   ✗ 找不到 $STAMPER"
    exit 1
fi

TMP="$(mktemp -d -t stamp-lines-smoke)"
trap 'rm -rf "$TMP"' EXIT

# 子进程：三行输出、行间各停 0.4 秒。**故意不 flush** —— 这正是 swift-testing
# 的行为（它不会为管道特判），也是本对照能成立的原因。
cat > "$TMP/child.py" <<'PY'
import time
for label in ("A", "B", "C"):
    print("line-" + label)
    time.sleep(0.4)
PY

"$PY" "$STAMPER" "$PY" "$TMP/child.py" > "$TMP/stamped.log" 2>&1

"$PY" - "$TMP/stamped.log" "$TMP/child.py" <<'PY'
import subprocess
import sys
import time

stamped_path, child_path = sys.argv[1], sys.argv[2]
SLEEP = 0.4
fails = []


def deltas(stamps):
    return [b - a for a, b in zip(stamps, stamps[1:])]


# ---- ① 装置自证：真的读到了三行 ----
rows = []
with open(stamped_path, encoding="utf-8", errors="replace") as f:
    for line in f:
        stamp, _, rest = line.partition("\t")
        try:
            rows.append((float(stamp), rest.rstrip("\n")))
        except ValueError:
            continue
print(f"   [自证] 打点行 {len(rows)} 行（期望 3）：{[r for _, r in rows]}")
if len(rows) != 3:
    print("   ✗ 打点行数不对 ⇒ 装置坏了（不是「没间隔」），本次结论作废")
    sys.exit(1)

# ---- ② 阳性：伪终端下，间隔应当 ≈ 0.4s ----
pos = deltas([t for t, _ in rows])
print(f"   [阳性] 伪终端版的间隔：{['%.3f' % d for d in pos]}")
for i, d in enumerate(pos):
    if not (SLEEP * 0.6 <= d <= SLEEP * 1.6):
        fails.append(f"伪终端版第 {i + 1} 个间隔是 {d:.3f}s，期望 ≈ {SLEEP}s")

# ---- ③ 阴性对照：同一子进程走**管道**，间隔必须塌掉 ----
# 这一条证明「是伪终端在起作用」，而不是「子进程碰巧会逐行冲刷」。
proc = subprocess.Popen([sys.executable, child_path], stdout=subprocess.PIPE)
neg = []
while True:
    line = proc.stdout.readline()
    if not line:
        break
    neg.append(time.time())
proc.wait()
neg = deltas([t - neg[0] for t in neg]) if neg else []
print(f"   [阴性] 朴素管道版的间隔：{['%.3f' % d for d in neg]}")
if not neg or max(neg) > SLEEP * 0.3:
    fails.append(
        f"朴素管道版居然拿到了间隔 {['%.3f' % d for d in neg]} ⇒ "
        f"这个子进程本来就会逐行冲刷，本对照**失去了分辨力**（换个子进程或改用不 flush 的写法）"
    )

if fails:
    print("   ✗ 未通过：")
    for f in fails:
        print(f"      · {f}")
    sys.exit(1)
print("   ✓ 通过：伪终端拿到间隔、朴素管道塌掉 ⇒ 「打点时刻 = 事件时刻」这条契约成立")
PY
