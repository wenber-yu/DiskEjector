#!/usr/bin/env bash
# =============================================================
# 冒烟：`Scripts/lib/test_timings.sh` 的最慢名单必须**认得真实日志**、排得对、
# 并且**说清口径**。
#
# 【它守什么】门槛 6 绿跑时只回显最后 3 行，测试日志随 mktemp 删掉 ⇒ 测试耗时
# 分布没有任何观测窗口（「本地 <1s / CI 57.1s」那组数字来自一次**红**跑，
# 之后想再看就得再造一次失败）。本函数把最慢几条压成一行、塞进那 3 行里。
#
# 【样本从哪来 —— 全部是**真实日志行**】
# `.build/preflight/门槛6.log`（2026-09-21 10:40 本机，442 条测试）。**内嵌**在
# 本文件里而不是运行时去读：`.build/` 会被清掉，那时脚本要么报错要么静默跳过，
# 而「装置没跑过」与「装置跑了但没发现问题」逐字相同。
#
# 【为什么样本里要放一条 9.500 秒】
# 那是**排序口径**的辨别力来源：若实现按**字典序**降序，`9.500` 会排在 `13.710`
# 前面（'9' > '1'）—— 名单会错，但看起来完全正常。数值序才是对的。
#
# 【为什么样本里要有 `"名字"` 这种格式】
# 真实日志里**两种名字格式并存**（实测 417 条 `名字()` + 23 条 `"名字"`）。
# 只写一个正则的实现会**静默漏掉 23 条**，而漏掉的可能恰好是要跟踪的那条。
#
# 【用法】./Scripts/test/test_timings_smoke.sh
# 【退出码】0 = 全部符合预期；1 = 有不符合
# =============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO/Scripts/lib/test_timings.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/test_timings.sh
source "$LIB"

pass=0
failn=0
check() { # check <说明> <0=符合 / 1=不符合>
    if [ "$1" = "" ]; then return; fi
    if [ "$2" = "0" ]; then
        echo "  ✅ $1"
        pass=$((pass + 1))
    else
        echo "  ❌ $1"
        failn=$((failn + 1))
    fi
}
has() { # has <被查串> <子串>
    case "$1" in *"$2"*) echo 0 ;; *) echo 1 ;; esac
}

echo "── 最慢名单（Scripts/lib/test_timings.sh）──"

# ── 样本：真实日志行的副本（已去回显缩进，与 `coverage.sh` 里 TEST_LOG 的形态一致）──
SAMPLE="$TMP/sample.log"
cat > "$SAMPLE" <<'EOF'
◇ Test run started.
◇ Test 真实占用时关闭进程并推出() started.
◇ Test "磁盘列表一变就重测占用（刷新按钮真的会刷新占用结论）" started.
✔ Test 安全盘不画琥珀条() passed after 13.710 seconds.
✔ Test "空磁盘列表清空全部结论" passed after 12.145 seconds.
✔ Test 某条中等慢的() passed after 9.500 seconds.
✔ Test 四块忙盘切紧凑行() passed after 20.105 seconds.
✘ Test 活文件里不得写死门槛数量() recorded an issue at ToolingClaimTests.swift:12:9: Expectation failed: (claims → ["x"]).isEmpty → false
✘ Test 活文件里不得写死门槛数量() failed after 22.032 seconds with 1 issue.
✔ Test 真实占用时关闭进程并推出() passed after 22.030 seconds.
✔ Test "磁盘列表一变就重测占用（刷新按钮真的会刷新占用结论）" passed after 20.129 seconds.
✔ Suite IntegrationEjectTests passed after 22.032 seconds.
✘ Test run with 442 tests in 56 suites failed after 22.032 seconds with 1 issue.
EOF

OUT="$(test_timings_line "$SAMPLE" 3)"
echo "  样本输出：$OUT"
echo ""

# ── 用例 1：口径必须印在输出里 ──
# 判据来自实测：单条 22.030 秒 ≈ 整轮 22.032 秒 ⇒ 它是「完成时刻距 run 开始」，
# 不是该测试自身耗时。不写口径，读的人会把 22 秒当成「这条测试要跑 22 秒」。
check "输出里写明了口径（不是该测试自身耗时）" "$(has "$OUT" '≠ 该测试自身耗时')"
check "输出里写明了含调度等待" "$(has "$OUT" '含并发调度等待')"

# ── 用例 2：排序是**数值**降序（9.500 必须排在 13.710 之后）──
case "$OUT" in
*"22.032s 活文件里不得写死门槛数量()"*) check "第一名是 22.032s" 0 ;;
*) check "第一名是 22.032s" 1 ;;
esac
case "$OUT" in
*"22.030s 真实占用时关闭进程并推出()"*) check "第二名是 22.030s（22.030 < 22.032）" 0 ;;
*) check "第二名是 22.030s（22.030 < 22.032）" 1 ;;
esac
case "$OUT" in
*"20.129s"*) check "第三名是 20.129s（20.129 > 20.105）" 0 ;;
*) check "第三名是 20.129s（20.129 > 20.105）" 1 ;;
esac
case "$OUT" in
*"13.710s"*) check "13.710s 未进前三（N=3 生效）" 1 ;;
*) check "13.710s 未进前三（N=3 生效）" 0 ;;
esac
case "$OUT" in
*"9.500s"*) check "9.500s 未进前三（若按字典序它会抢到第一）" 1 ;;
*) check "9.500s 未进前三（若按字典序它会抢到第一）" 0 ;;
esac

# ── 用例 3：`"名字"` 格式必须被认出来 ──
case "$OUT" in
*'20.129s "磁盘列表一变就重测占用（刷新按钮真的会刷新占用结论）"'*)
    check '带引号的名字格式被认出且名字完好（未被截断/切碎）' 0 ;;
*)
    check '带引号的名字格式被认出且名字完好（未被截断/切碎）' 1 ;;
esac

# ── 用例 4：汇总行不能被当成一条测试 ──
# 汇总行与普通结果行同形（`Test ... failed after N seconds`），且**永远是第一名**
# ⇒ 不排除的话名单第一位会被一个假条目占死。
case "$OUT" in
*"run with 442 tests"*) check "汇总行没有被当成一条测试" 1 ;;
*) check "汇总行没有被当成一条测试" 0 ;;
esac

# ── 用例 5：自证字段（解析到的条数 / 汇总行声明的条数）──
# 样本里带耗时的结果行共 7 条（`recorded an issue` 那条没有耗时，应排除）。
case "$OUT" in
*"［耗时行 7/442］"*) check "自证字段正确（耗时行 7/442）" 0 ;;
*) check "自证字段正确（耗时行 7/442）" 1 ;;
esac

# ── 用例 6：N 可调 ──
OUT1="$(test_timings_line "$SAMPLE" 1)"
case "$OUT1" in
*"·"*) check "N=1 时只有一条（没有多余的分隔符）" 1 ;;
*) check "N=1 时只有一条（没有多余的分隔符）" 0 ;;
esac

# ── 用例 7：**locale 无关** ──
# 本机 locale **未设**（等价 C），CI 设 `LC_ALL=en_US.UTF-8`（.github/workflows/ci.yml）。
# 用多字节字符类（`[✔✘]`）或 BSD awk 的位置索引（`substr`/`match` 的 RSTART）实现的话，
# C locale 下会按**字节**处理 ⇒ 要么一条都匹配不上、要么把中文名字切碎
# ⇒ 本地与 CI 行为**分叉**。判据：三种 locale 下输出**逐字节相同**。
OUT_UNSET="$(env -u LANG -u LC_ALL bash -c 'source "$1"; test_timings_line "$2" 3' _ "$LIB" "$SAMPLE")"
OUT_C="$(LC_ALL=C bash -c 'source "$1"; test_timings_line "$2" 3' _ "$LIB" "$SAMPLE")"
OUT_U="$(LC_ALL=en_US.UTF-8 bash -c 'source "$1"; test_timings_line "$2" 3' _ "$LIB" "$SAMPLE")"
if [ "$OUT_C" = "$OUT_U" ] && [ "$OUT_UNSET" = "$OUT_U" ]; then
    check "未设/C/en_US.UTF-8 三种 locale 输出逐字节相同" 0
else
    check "未设/C/en_US.UTF-8 三种 locale 输出逐字节相同" 1
    echo "     未设：$OUT_UNSET"
    echo "     C   ：$OUT_C"
    echo "     UTF8：$OUT_U"
fi
case "$OUT_C" in
*"真实占用时关闭进程并推出"*) check "C locale 下中文名字完好（未被按字节切碎）" 0 ;;
*) check "C locale 下中文名字完好（未被按字节切碎）" 1 ;;
esac
case "$OUT_UNSET" in
*"［耗时行 7/442］"*) check "未设 locale 下也能解析出 7 条（本机真实状态）" 0 ;;
*) check "未设 locale 下也能解析出 7 条（本机真实状态）" 1 ;;
esac

# ── 用例 8：调用方的真实环境（`set -euo pipefail`）下不能崩 ──
# `coverage.sh` 是 `set -euo pipefail`。若实现把 `head -n N` 接在管道上（这是
# 「取前 N 条」最自然的写法），`head` 提前退出会让上游收 SIGPIPE(141) ⇒ 整条
# 管道非 0 ⇒ 门槛被判红。
#
# ⚠️ **必须用大样本**：13 行的样本太小，`sed`/`sort` 在 `head` 退出前就写完了，
#    SIGPIPE **根本不会触发** ⇒ 这条用例会变成没牙的（变异测试实测确认：
#    把 `head` 接回管道后，小样本下本用例**仍然绿**）。20000 行才能让 `sort`
#    写到一半被打断。
BIG="$TMP/big.log"
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "✔ Test 大样本测试%d() passed after %d.5 seconds.\n", i, i % 100 }' > "$BIG"
check "大样本已生成（自证：$(wc -l < "$BIG" | tr -d ' ') 行）" \
    "$([ "$(wc -l < "$BIG" | tr -d ' ')" -eq 20000 ] && echo 0 || echo 1)"
bash -c 'set -euo pipefail; source "$1"; test_timings_line "$2" 3 >/dev/null' _ "$LIB" "$SAMPLE"
check "小样本 · 调用方 set -euo pipefail 下退出码为 0" "$?"
bash -c 'set -euo pipefail; source "$1"; test_timings_line "$2" 3 >/dev/null' _ "$LIB" "$BIG"
check "大样本(20000 行) · set -euo pipefail 下退出码为 0（SIGPIPE 陷阱）" "$?"

# ── 用例 9（阴性对照）：日志里没有耗时行时，不许输出垃圾名单 ──
# 判据必须查「名单的固定结构」而不是「最慢」二字：警告文案里含「最慢名单不可用」
# —— 用 `*"最慢"*` 判会把**警告本身**误判成名单（本脚本第一版就是这样，白红一条）。
# 判据：必须打警告、**不能**出现「N 条（墙钟…」这个名单骨架。
EMPTY="$TMP/empty.log"
cat > "$EMPTY" <<'EOF'
◇ Test run started.
◇ Test 某条测试() started.
✘ Test run with 442 tests in 56 suites failed after 22.032 seconds with 1 issue.
EOF
OUT_E="$(test_timings_line "$EMPTY" 3)"
case "$OUT_E" in
*"条（墙钟"*) check "空日志时不打出名单骨架（阴性对照）" 1 ;;
*) check "空日志时不打出名单骨架（阴性对照）" 0 ;;
esac
case "$OUT_E" in
*"未能从测试日志里解析出任何耗时行"*) check "空日志时给出显式警告" 0 ;;
*) check "空日志时给出显式警告" 1 ;;
esac

# ── 用例 10：文件不存在时不崩、不输出名单 ──
OUT_M="$(test_timings_line "$TMP/不存在的文件.log" 3)"
case "$OUT_M" in
*"条（墙钟"*) check "日志文件不存在时不打出名单骨架" 1 ;;
*) check "日志文件不存在时不打出名单骨架" 0 ;;
esac

echo ""
echo "── 合计：${pass} 通过 / ${failn} 不符合 ──"
[ "$failn" -eq 0 ]
