#!/usr/bin/env bash
# =============================================================
# 冒烟：`Scripts/lib/coverage_tail.sh` 的收尾输出必须**落在门槛能看见的那 3 行里**
#
# 【它守什么】门槛 6 由 `run_gate` 执行，**成功时只回显最后 3 行**
# （`Scripts/lib/gate_report.sh` 的 `sed ... | tail -3`）。于是「最慢名单有没有
# 被看见」完全取决于它**排在第几行** —— 而这件事**源码文本断言守不住**：
# 断言只能证明「那行还在」，证明不了「它在最后 3 行里」。本脚本**真调函数、
# 真做一次 `tail -3`**，把布局变成可测的。
#
# 【它同时守一个更容易忘的】诊断输出**不能挤掉通过信号**：`✅ 覆盖率达标`
# 必须在 tail -3 里。有人往收尾函数里多塞一行（哪怕是有用的一行），它就会被
# 挤出去 —— 而门槛看起来仍然绿。
#
# 【用法】./Scripts/test/coverage_tail_smoke.sh
# 【退出码】0 = 全部符合预期；1 = 有不符合
# =============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO/Scripts/lib/coverage_tail.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/coverage_tail.sh
source "$LIB"

pass=0
failn=0
check() {
    if [ "$1" = "" ]; then return; fi
    if [ "$2" = "0" ]; then
        echo "  ✅ $1"
        pass=$((pass + 1))
    else
        echo "  ❌ $1"
        failn=$((failn + 1))
    fi
}
has() { case "$1" in *"$2"*) echo 0 ;; *) echo 1 ;; esac; }

echo "── 覆盖率收尾输出的布局（Scripts/lib/coverage_tail.sh）──"

# 样本：真实日志行的副本（`.build/preflight/门槛6.log`，2026-09-21 10:40 本机）
SAMPLE="$TMP/sample.log"
cat > "$SAMPLE" <<'EOF'
✔ Test 安全盘不画琥珀条() passed after 13.710 seconds.
✔ Test 四块忙盘切紧凑行() passed after 20.105 seconds.
✔ Test 真实占用时关闭进程并推出() passed after 22.030 seconds.
✘ Test run with 442 tests in 56 suites failed after 22.032 seconds with 1 issue.
EOF

# ── 复现 `coverage.sh` 成功路径：行覆盖率那行在函数**外**，函数负责后两行 ──
# ⚠️ 不能写成 `out="$(...)"` 再看变量：`tail -3` 必须在**真实管道**里做一次，
#    否则守的是我的想象而不是门槛的实际行为。
{
    echo "   行覆盖率: 64.38%   门槛: 40%"
    coverage_success_tail "$SAMPLE" 3
} > "$TMP/full" 2>&1
TAIL3="$(tail -3 "$TMP/full")"
echo "  tail -3 实际内容："
printf '%s\n' "$TAIL3" | sed 's/^/     │ /'
echo ""

check "tail -3 里有「行覆盖率」（门槛的核心数字没被挤掉）" "$(has "$TAIL3" '行覆盖率')"
check "tail -3 里有最慢名单骨架" "$(has "$TAIL3" '条（墙钟')"
check "tail -3 里有口径（不是该测试自身耗时）" "$(has "$TAIL3" '≠ 该测试自身耗时')"
check "tail -3 里有自证字段（耗时行 N/M）" "$(has "$TAIL3" '［耗时行 3/442］')"
check "tail -3 里有通过信号「✅ 覆盖率达标」" "$(has "$TAIL3" '✅ 覆盖率达标')"

# ── 阳性对照：证明「N 传 0 ⇒ 名单为空」这个因果**真的成立** ──
# 上面每条判据都建立在「名单里有条目」这个前提上。若判据分不出空/非空，
# 它们对「条数被传成 0」这类退化就是瞎的 —— 而空名单时骨架、口径、自证
# **全都还在**，四条判据会一起假绿。
# ⚠️ 不能只写「TAIL3 里没有空名单形状」：TAIL3 用的是写死的 3，**永远不会**
#    出现空名单 ⇒ 那条断言永远绿 = 没牙（本脚本第一版就是这样，变异 N4 当场
#    证明它抓不住）。所以这里**主动用 N=0 构造**一次，并做**双向**断言。
# ⚠️ 判据不能写成 `*'：［'*`：`out` 为空时那句是 `）： ［`（`${out}` 占位留了
#    空格），冒号后并**不是**紧跟 `［` —— 判据会永远不成立（本脚本第二版踩到）。
EMPTY_TAIL="$(coverage_success_tail "$SAMPLE" 0)"
case "$EMPTY_TAIL" in
*"22.030s"*|*"20.105s"*|*"13.710s"*)
    check "阳性对照：N=0 时名单为空（判据能分辨空/非空）" 1
    ;;
*)
    check "阳性对照：N=0 时名单为空（判据能分辨空/非空）" 0
    ;;
esac
# 反向：同一判据在 N=3 时必须判「非空」——否则上面那条可能只是永远绿。
case "$TAIL3" in
*"22.030s"*) check "阳性对照的反向：N=3 时同一判据判「非空」" 0 ;;
*) check "阳性对照的反向：N=3 时同一判据判「非空」" 1 ;;
esac

# ── 收尾函数必须**恰好 2 行** ──
# 这是上面那三条的前提：行覆盖率那行在函数外，函数多一行就会把**通过信号**
# 挤出 tail -3（门槛看起来仍绿，但「✅ 达标」不见了）。
n="$(coverage_success_tail "$SAMPLE" 3 | wc -l | tr -d ' ')"
check "收尾函数恰好输出 2 行（实得 ${n} 行）" "$([ "$n" -eq 2 ] && echo 0 || echo 1)"

# ── 阴性对照：诊断解析不到时，通过信号**仍然**要打出来 ──
# `test_timings_line` 的产物是诊断、不是判据；它失败时绝不能把「✅ 覆盖率达标」
# 一起吞掉 —— 那会把「测试全绿、覆盖率达标」显示成一次可疑的收尾。
EMPTY="$TMP/empty.log"
printf '◇ Test run started.\n' > "$EMPTY"
OUT_E="$(coverage_success_tail "$EMPTY" 3)"
case "$OUT_E" in
*"✅ 覆盖率达标"*) check "解析不到耗时行时仍打出通过信号（阴性对照）" 0 ;;
*) check "解析不到耗时行时仍打出通过信号（阴性对照）" 1 ;;
esac
case "$OUT_E" in
*"条（墙钟"*) check "解析不到时不打出名单骨架" 1 ;;
*) check "解析不到时不打出名单骨架" 0 ;;
esac

# ── 调用方真实环境（`set -euo pipefail`）下不能崩 ──
# `coverage.sh` 是 `set -euo pipefail`，且它就在 `if awk ...; then` 的
# **真分支**里调用 —— 这里若返回非 0，门槛会被判红。
bash -c 'set -euo pipefail; source "$1"; coverage_success_tail "$2" 3 >/dev/null' _ "$LIB" "$SAMPLE"
check "set -euo pipefail 下退出码为 0" "$?"

# ── 接线：`coverage.sh` 必须**真的调用**它，且条数写对 ──
# ⚠️ 上面所有用例测的都是**函数本身**：哪天 `coverage.sh` 不再调用它（回退成
#    原来那句 `echo "✅ 覆盖率达标"`），函数照样好、冒烟照样绿，而**功能没了**。
#    ⇒ 接线本身也是契约，必须单独守一次。
# ⚠️ **参数也要钉住**：写成 `coverage_success_tail "$TEST_LOG" 0` 时函数依然被调用、
#    依然打出「✅ 覆盖率达标」，只是名单退化成空的 —— 只查函数名抓不住（变异 N4
#    实测确认：只查函数名时这条变异**仍绿**）。所以判据带上 ` 3`。
# ⚠️ 剥掉注释再匹配：否则**注释里提到**这个函数名就算数。
# ⚠️ 用 `case` 模式匹配而不是 `grep`：本仓库在 shell grep 上反复踩过静默失败。
COV_CODE="$(sed 's/#.*//' "$REPO/Scripts/coverage.sh")"
case "$COV_CODE" in
*'coverage_success_tail "$TEST_LOG" 3'*) check "coverage.sh 真的调用了收尾函数且条数为 3（非注释）" 0 ;;
*) check "coverage.sh 真的调用了收尾函数且条数为 3（非注释）" 1 ;;
esac
# 阴性对照：同一套剥注释 + 匹配的口径，对一个**没有**该调用的文件必须报「没有」。
# （少了这条，`case` 写错成永远成立时，上面那条会假绿。）
case "$(sed 's/#.*//' "$REPO/Scripts/lib/gate_report.sh")" in
*'coverage_success_tail "$TEST_LOG" 3'*) check "阴性对照：别的脚本不会被误判成有接线" 1 ;;
*) check "阴性对照：别的脚本不会被误判成有接线" 0 ;;
esac

# ── 测试日志必须**持久化**（2026-09-23，账本 #51）──
#
# 为什么值得一条：它原来是 `mktemp` + `trap rm`，**跑完即删** ⇒ 门槛成功时
# 逐条 `passed after` 一行都留不下 ⇒ 「CI 上那条测试慢了多少」永远量不到
# （§8.135 就栽在这上面）。改回 mktemp **不会让任何东西变红** —— 测试照样绿、
# 覆盖率照样达标，只是那条路又断了。
#
# 判据：① 文件里**不许**再出现 `mktemp`（那正是「跑完即删」的来源）；
#       ② `TEST_LOG=` 的赋值必须**派生自** `KEEP_DIR`（与门槛同一处持久目录，
#          不在别处再写一个路径 ⇒ 不会漂）。两条都要 —— 只查 ② 的话，
#          把 `KEEP_DIR` 换成 `mktemp` 就只剩下 ① 抓得住。
COV_BODY="$(sed 's/#.*//' "$REPO/Scripts/coverage.sh")"
case "$COV_BODY" in
*mktemp*) check "coverage.sh 不再用 mktemp 存测试日志（跑完即删就量不到逐条耗时）" 1 ;;
*) check "coverage.sh 不再用 mktemp 存测试日志（跑完即删就量不到逐条耗时）" 0 ;;
esac
# ⚠️ **判据要按「两步派生」写，不能写成一串 `*A*B*`**（本脚本第一版就是这么错的）：
#    `TEST_LOG="` 出现在 `TEST_LOG_DIR=...` **之后**，而 `${KEEP_DIR}` 在**之前**
#    ⇒ `*'TEST_LOG="'*'${KEEP_DIR}'*` **永远不成立**，报出来的却是「没派生自 KEEP_DIR」
#    —— 与「真的没派生」逐字相同。这是「静态扫描器的错多半是口径错」的又一例。
#    改成两步：① 落点变量取自 KEEP_DIR；② 日志文件名挂在那个变量下。
case "$COV_BODY" in
*'TEST_LOG_DIR="${KEEP_DIR'*) check "测试日志目录取自 KEEP_DIR（不与门槛目录分叉）" 0 ;;
*) check "测试日志目录取自 KEEP_DIR（不与门槛目录分叉）" 1 ;;
esac
case "$COV_BODY" in
*'TEST_LOG="$TEST_LOG_DIR/'*) check "测试日志文件名挂在那个目录下（不是另写一个路径）" 0 ;;
*) check "测试日志文件名挂在那个目录下（不是另写一个路径）" 1 ;;
esac
# 阴性对照：同一个 `mktemp` 判据，对**确实用** mktemp 的文件必须报「有」
# （少了这条，判据写反或永远不成立时上面那条会假绿）。
case "$(sed 's/#.*//' "$REPO/Scripts/preflight.sh")" in
*mktemp*) check "阴性对照：preflight.sh 确实还在用 mktemp ⇒ 判据能分辨" 0 ;;
*) check "阴性对照：preflight.sh 确实还在用 mktemp ⇒ 判据能分辨" 1 ;;
esac

echo ""
echo "── 合计：${pass} 通过 / ${failn} 不符合 ──"
[ "$failn" -eq 0 ]
