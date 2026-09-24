#!/usr/bin/env bash
# =============================================================
# 冒烟：`Scripts/lib/gate_report.sh` 的**失败报告**必须真的给得出失败项的名字
#
# 【它守什么】2026-09-20：门槛曾红在「415 个测试里 1 个 issue」，而**失败测试的名字
# 没拿到** —— 日志被 `trap` 删了、回显只有尾部 30 行。那次之后「下次要落盘再 grep」
# 只写在「仍开着」表里，**没有机制保证它发生**。本脚本就是那个机制的行为测试。
#
# 【为什么要有辨别力 —— 别写成「名字正好也在尾部」】
# 假门槛把失败项名字写在**第 1 行**、后面垫 20 行通过行，`FAIL_TAIL=2` ⇒
# 回显的尾部**必然不含**名字。⇒ 输出里还能看到名字，**只可能**来自「失败项摘要」。
# 少了这个设计，把摘要删掉测试照样绿 —— 那是「假绿」，比不测更糟。
#
# 【用法】./Scripts/test/gate_report_smoke.sh
# 【退出码】0 = 全部符合预期；1 = 有不符合
# =============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO/Scripts/lib/gate_report.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GATE_NO=0
FAILED=0
LOG="$TMP/gate.log"
KEEP_DIR="$TMP/keep"
mkdir -p "$KEEP_DIR"
# ⚠️ 走**真实**环境变量：设成 2 ⇒ 回显只给尾部 2 行，而失败项名字在第 1 行
#    ⇒ 名字**必然**被截掉。这是本脚本「有辨别力」的来源（详见文件头）。
PREFLIGHT_FAIL_TAIL=2

# shellcheck source=../lib/gate_report.sh
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

NAME="✘ Test 某条真的会红的测试() failed after 1.00 seconds"

echo "── 门槛失败报告（Scripts/lib/gate_report.sh）──"

# ── 用例 1：名字在第 1 行、后面垫 20 行 ⇒ 只有「摘要」救得回来 ──
#
# ⚠️ **不要用 `out="$(run_gate …)"`**：命令替换会把 run_gate 放进**子 shell**，
#    `GATE_NO` 的自增**不回传** ⇒ 三道假门槛全变成「门槛 1」，保留日志互相覆盖，
#    而按编号做的断言会因为「编号恒为 1」而**假绿**（本脚本第一版就是这个 bug）。
#    改成重定向到文件 —— 同一 shell 内执行，编号才对得上。
run_gate "假门槛（必失败）" bash -c '
    printf "%s\n" "'"$NAME"'"
    i=1
    while [ "$i" -le 20 ]; do echo "     ✓ 通过行 ${i}"; i=$((i + 1)); done
    exit 1
' > "$TMP/out1" 2>&1
rc=$?
out="$(cat "$TMP/out1")"
check "run_gate 对失败的门槛返回非 0" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

case "$out" in
*"$NAME"*) check "输出里能看到失败项的名字（尾部 2 行不含它 ⇒ 只能来自摘要）" 0 ;;
*) check "输出里能看到失败项的名字（尾部 2 行不含它 ⇒ 只能来自摘要）" 1 ;;
esac

case "$out" in
*"全量日志已保留"*) check "提示了日志保留路径" 0 ;;
*) check "提示了日志保留路径" 1 ;;
esac

keep1="$KEEP_DIR/门槛1.log"
check "全量日志真的落盘了（$keep1 存在）" "$([ -f "$keep1" ] && echo 0 || echo 1)"
if [ -f "$keep1" ]; then
    # ⚠️ 必须是**全量**（21 行），不能只是被 tail 过的那 2 行 —— 否则留了也没用
    n="$(wc -l < "$keep1" | tr -d ' ')"
    check "留下的是**全量**日志（实得 ${n} 行，应 ≥ 21）" "$([ "$n" -ge 21 ] && echo 0 || echo 1)"
    case "$(cat "$keep1")" in
    *"$NAME"*) check "保留的日志里含失败项名字" 0 ;;
    *) check "保留的日志里含失败项名字" 1 ;;
    esac
fi

# ── 用例 2（阴性对照）：通过的门槛不该留日志、也不该报摘要 ──
run_gate "假门槛（必成功）" bash -c 'echo "     ✓ ok"' > "$TMP/out2" 2>&1
rc2=$?
out2="$(cat "$TMP/out2")"
check "run_gate 对成功的门槛返回 0" "$([ "$rc2" -eq 0 ] && echo 0 || echo 1)"
case "$out2" in
*"失败项摘要"*) check "通过的门槛不报「失败项摘要」（阴性对照）" 1 ;;
*) check "通过的门槛不报「失败项摘要」（阴性对照）" 0 ;;
esac
check "通过的门槛不留日志（门槛2.log 不存在）" \
    "$([ -f "$KEEP_DIR/门槛2.log" ] && echo 1 || echo 0)"

# ── 用例 3（阴性对照）：日志里没有失败标记时，不该硬造摘要 ──
run_gate "假门槛（失败但无标记）" bash -c 'echo "只有一行普通输出"; exit 1' \
    > "$TMP/out3" 2>&1
out3="$(cat "$TMP/out3")"
case "$out3" in
*"失败项摘要"*) check "无失败标记时不硬造摘要（阴性对照）" 1 ;;
*) check "无失败标记时不硬造摘要（阴性对照）" 0 ;;
esac
check "无失败标记时仍然留住日志（失败就该留）" \
    "$([ -f "$KEEP_DIR/门槛3.log" ] && echo 0 || echo 1)"

echo ""
echo "── 合计：${pass} 通过 / ${failn} 不符合 ──"
[ "$failn" -eq 0 ]
