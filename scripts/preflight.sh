#!/usr/bin/env bash
# =============================================================
# DiskEjector — CI 严格门槛本地预检
#
# 【为什么需要这个脚本】
# CI 在普通 `swift build` 之外还加了更严的门槛，其中最早的两道是：
#   1. `-Xswiftc -warnings-as-errors`（零警告构建，捕获 Swift 6 并发隔离问题）
#   2. `swift-format lint --strict`（格式零违规）
# 而这两道**不在 build_app.sh 的执行路径上**——build_app.sh 用的是不带该
# flag 的 `swift build -c release`。于是本地打包一路绿灯、CI 却红。
# 本项目曾因此让 13 条 Swift 6 并发错误潜伏三天（详见 SPEC.md §6.4）。
#
# 本脚本是**全部门槛的唯一实现**：本地与 CI 调用同一个文件，杜绝两侧逻辑分叉。
# ⚠️ **别在任何活文件里写死「N 道门槛」**（`run.sh` / `build_app.sh` / CI 工作流都栽过：
#    门槛一路在加，而那几处一直停在**最开始那个数字**上，
#    读的人据此**低估了检查范围**（`run.sh` 曾让人以为 `check` 只做构建 + 格式）。
#    要清单就跑一次 `./run.sh check` —— 它逐道打印标题，那份输出才是权威。
#
# 【用法】
#   ./scripts/preflight.sh                 # 构建（警告视为错误）+ 格式检查
#   ./scripts/preflight.sh --with-tests    # 额外跑测试与覆盖率门槛
#   COVERAGE_MIN=45 ./scripts/preflight.sh --with-tests   # 自定义覆盖率门槛
#   DISABLE_SANDBOX=1 ./scripts/preflight.sh               # 受管环境：跳过 SwiftPM 沙盒
#                                                          # （报 sandbox_apply 失败时用）
#
# 【退出码】
#   0 全部门槛通过；1 至少一道未通过（逐道打印）；2 参数错误。
#   即使前面已失败，也会把剩余门槛跑完再汇总，一次看到全部问题。
# =============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 仓库根 == SPM 包根
PACKAGE_DIR="$REPO_ROOT"
FORMAT_CONFIG="$REPO_ROOT/.swift-format"
COVERAGE_MIN="${COVERAGE_MIN:-40}"

# DISABLE_SANDBOX=1：跳过 SwiftPM 自带的 sandbox-exec。
# 受管执行环境自身已在一层沙箱内时，嵌套 sandbox-exec 会报
# "sandbox_apply: Operation not permitted" 并让构建失败（与代码无关）。
# 仅影响构建期隔离，不改变检查结论；CI 不应设置此变量。
SWIFT_SANDBOX_FLAGS=()
if [ "${DISABLE_SANDBOX:-0}" = "1" ]; then
    echo "ⓘ DISABLE_SANDBOX=1：swift build 将跳过 SwiftPM 沙盒（仅供受管环境使用）"
    SWIFT_SANDBOX_FLAGS+=(--disable-sandbox)
fi

WITH_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --with-tests) WITH_TESTS=1 ;;
        -h | --help)
            sed -n '3,23p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "未知参数：${arg}" >&2
            echo "用法：./scripts/preflight.sh [--with-tests]" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

LOG="$(mktemp -t diskejector-preflight)"
trap 'rm -f "$LOG"' EXIT

# ⚠️ 门槛失败时，把**全量**日志另存到持久目录 `.build/preflight/门槛N.log`。
#
# 为什么必须留（2026-09-20）：门槛曾红在「415 个测试里 1 个 issue」，而**失败测试的
# 名字没拿到** —— `$LOG` 被上面的 `trap` 删了、回显又只有尾部 30 行。那次之后
# 「下次要落盘再 grep」只写在「仍开着」表里，**没有任何机制保证它发生** ⇒
# 能不能拿到名字，取决于人事前有没有设 `PREFLIGHT_FAIL_TAIL=0`。
# 留一份持久副本 ⇒ 事后追查**不依赖**当时的环境变量。`.build/` 已被 gitignore。
KEEP_DIR="$REPO_ROOT/.build/preflight"
mkdir -p "$KEEP_DIR"

FAILED=0
GATE_NO=0

# 门槛执行与「失败报告」抽在 `scripts/lib/gate_report.sh` —— 抽出来的唯一目的是让它
# **有行为测试**（`scripts/test/gate_report_smoke.sh` 直接 source 它、喂一个必失败的
# 假门槛，几毫秒验完）。留在 preflight.sh 里就只剩源码文本断言，而那种断言守得住
# 「那行还在」，守不住「改坏了但还在」。
#
# ⚠️ `FAIL_TAIL` 由 `gate_report.sh` 自己从 `PREFLIGHT_FAIL_TAIL` 派生（与「按值分支」
#    那一支同文件 —— 见那边注释）。这里只提供 LOG / KEEP_DIR 两个变量。
source "$REPO_ROOT/scripts/lib/gate_report.sh"

echo "DiskEjector 预检（仓库：${REPO_ROOT}）"

# ---------------------------------------------------------------
# 门槛 1：构建（警告视为错误）
# 覆盖 Swift 6 严格并发下的 actor-isolation 问题——这类问题在默认构建里只是
# 警告，只有加了该 flag 才会让构建失败。
#
# **`--build-tests` 不可省**：不加它时编译的只有 **App 目标**，测试目标不在门内。
# 2026-09-17 实际踩到：`KeySilentWindowTests` 里有一条 `#expect(alert is NSPanel)`
# —— `alert` 的静态类型就是 `EjectAlertPanel`，编译器判定该表达式**恒真**
# （`-warnings-as-errors` 下报 `'is' test is always true`），
# 而它在测试目标里，门槛 1 一直看不见；同时 `swift test` 不把这个警告当错误，
# 于是这条**没有牙的断言**活了很久。与 §6.4 那 13 条并发错误是同一个病根：
# **门槛的覆盖面比它声称的窄**。谁再把 `--build-tests` 去掉，这条就回来。
# ---------------------------------------------------------------
run_gate "构建（-Xswiftc -warnings-as-errors，含测试目标）" \
    swift build --package-path "$PACKAGE_DIR" --build-tests -Xswiftc -warnings-as-errors \
    ${SWIFT_SANDBOX_FLAGS[@]+"${SWIFT_SANDBOX_FLAGS[@]}"} \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 2：swift-format 严格格式检查
# **--strict 不可省**：swift-format lint 默认即使发现问题也返回 0，不加它形同虚设。
# 显式传 --configuration：脚本可能从任意工作目录被调用，不能依赖自动发现。
# 修复方式：xcrun swift-format format --in-place --recursive \
#             --configuration "$FORMAT_CONFIG" Sources Tests
# ---------------------------------------------------------------
GATE2_TITLE="格式检查（swift-format lint --strict）"
if [ ! -f "$FORMAT_CONFIG" ]; then
    gate_header "$GATE2_TITLE"
    echo "   ✗ 缺少配置文件 ${FORMAT_CONFIG}" >&2
    FAILED=$((FAILED + 1))
elif ! xcrun --find swift-format >/dev/null 2>&1; then
    gate_header "$GATE2_TITLE"
    echo "   ✗ 未找到 swift-format（随 Xcode 工具链提供，请确认已安装 Xcode）" >&2
    FAILED=$((FAILED + 1))
else
    run_gate "$GATE2_TITLE" \
        xcrun swift-format lint --strict \
        --configuration "$FORMAT_CONFIG" \
        --recursive "$PACKAGE_DIR/Sources" "$PACKAGE_DIR/Tests" \
        || FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------
# 门槛 3：注释里的「承诺句」必须带日期
# 覆盖一类**编译与测试都看不见**的错误：代码是对的、注释是错的。
# 2026-09-20 一轮里修掉 4 处（§8.88），其中「应用自身还不检查更新」挂着而
# Sparkle 早已接好 —— 读的人会照着错的注释做决策。
#
# ⚠️ **判据是「标了承诺就必须写日期」，不是「关键词出现就报警」**：
# 用 `尚未|还没` 这类泛词实测 33 处命中只有 ~3 处是真问题（precision ≈ 9%），
# 那种扫描器一定会被关掉。详见 scripts/scan_stale_comments.sh 的文件头。
#
# 放在测试**之前**：它只要几秒，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "注释承诺句（标了未核实/TODO/已知限制就必须带日期）" \
    "$REPO_ROOT/scripts/scan_stale_comments.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 4：脚本冒烟（`run.sh ci` 的几条关键路径）
# 覆盖一类**只有网络抖动时才出现**的失败路径：`scripts/ci_status.sh` 曾把
# 「查询失败」当成「一个空 run」，并报出**方向完全错**的诊断（§8.107）。
# 用假 `gh`（`scripts/test/fake-gh/gh`）把那条路径变成**确定性样本**。
#
# ⚠️ **`--offline` 不可省**：不带它时冒烟脚本会去打 GitHub API（十几秒，且随网络抖动），
# 让一道**与网络无关**的门槛自己变成 flaky —— 那正是「门槛会自己烂掉」的来源。
# 它同时是**判据必须有人执行**的落点：这个冒烟脚本 2026-09-20 造出来时
# 没有任何东西跑它（`scripts/test/` 下 0 个消费者），等于白写。
#
# 放在测试**之前**：它只要几秒，而门槛里最贵的失败应该最先暴露。
# ---------------------------------------------------------------
run_gate "脚本冒烟（ci_status.sh 的确定性用例，不碰网络）" \
    "$REPO_ROOT/scripts/test/ci_status_smoke.sh" --offline \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 5：门槛**自己**的失败报告（`scripts/lib/gate_report.sh`）
# 守「门槛红的时候能不能拿到失败项的名字 + 全量日志有没有留住」。
# 2026-09-20 之前这件事只是一条写在「仍开着」表里的建议 ⇒ 真红了一次却不知道
# 红的是谁，至今追不回来（`trap` 删了临时日志，回显又只有尾部 30 行）。
#
# ⚠️ 为什么它必须有行为测试而不是源码文本断言：文本断言守得住「那行还在」，
# 守不住「改坏了但还在」。⇒ `run_gate` 抽进 `scripts/lib/` 就是为了能被 source。
# ---------------------------------------------------------------
run_gate "门槛失败报告（红时要给出失败项的名字并留住全量日志）" \
    "$REPO_ROOT/scripts/test/gate_report_smoke.sh" \
    || FAILED=$((FAILED + 1))

# ---------------------------------------------------------------
# 门槛 5（可选）：测试 + 覆盖率
# 复用 scripts/coverage.sh，避免门槛口径写两份。
#
# ⚠️ **跑门槛时不要同时改文件**：构建中会编辑源文件 ⇒ 编译器报
# `input file ... was modified during the build`，门槛红而**与代码无关**
# （2026-09-20 实测复现）。症状与 flaky 测试**逐字相同**，极易误判。
# ---------------------------------------------------------------
if [ "$WITH_TESTS" = "1" ]; then
    run_gate "测试与覆盖率（≥${COVERAGE_MIN}%）" \
        "$REPO_ROOT/scripts/coverage.sh" "$COVERAGE_MIN" \
        || FAILED=$((FAILED + 1))
fi

echo ""
echo "=================================================="
if [ "$FAILED" = "0" ]; then
    echo " ✅ ${GATE_NO} 道门槛全部通过"
    if [ "$WITH_TESTS" = "0" ]; then
        echo "    （加 --with-tests 可一并跑测试与覆盖率）"
    fi
else
    echo " ✗ 有 ${FAILED} 道门槛未通过（详见上方日志）"
    echo "   格式问题一键修复："
    echo "     xcrun swift-format format --in-place --recursive \\"
    echo "       --configuration \"$FORMAT_CONFIG\" Sources Tests"
fi
echo "=================================================="

[ "$FAILED" = "0" ]
