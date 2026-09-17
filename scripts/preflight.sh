#!/usr/bin/env bash
# =============================================================
# DiskEjector — CI 严格门槛本地预检
#
# 【为什么需要这个脚本】
# CI 在普通 `swift build` 之外还加了两道更严的门槛：
#   1. `-Xswiftc -warnings-as-errors`（零警告构建，捕获 Swift 6 并发隔离问题）
#   2. `swift-format lint --strict`（格式零违规）
# 而这两道门槛**不在 build_app.sh 的执行路径上**——build_app.sh 用的是不带该
# flag 的 `swift build -c release`。于是本地打包一路绿灯、CI 却红。
# 本项目曾因此让 13 条 Swift 6 并发错误潜伏三天（详见 SPEC.md §6.4）。
#
# 本脚本是这两道门槛的**唯一实现**：本地与 CI 调用同一个文件，杜绝两侧逻辑分叉。
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

FAILED=0
GATE_NO=0

# 统一的门槛标题（含递增编号），保证「前置条件失败」与「命令失败」两种路径编号一致。
gate_header() {
    GATE_NO=$((GATE_NO + 1))
    echo ""
    echo "▶ 门槛 ${GATE_NO}：$1"
}

# run_gate <标题> <命令...>
# 输出重定向到日志：成功只回显尾部 3 行（保留覆盖率数字这类关键摘要），
# 失败回显尾部 30 行供定位。**不把命令输出直接接到管道上**——`cmd | tail` 会让
# `$?` 变成 tail 的状态，把失败判成成功（本项目踩过这个坑）。
run_gate() {
    local title="$1"
    shift
    gate_header "$title"
    if "$@" > "$LOG" 2>&1; then
        sed 's/^/     /' "$LOG" | tail -3
        echo "   ✓ 通过"
        return 0
    fi
    echo "   ✗ 未通过，日志尾部："
    sed 's/^/     /' "$LOG" | tail -30
    return 1
}

echo "DiskEjector 预检（仓库：${REPO_ROOT}）"

# ---------------------------------------------------------------
# 门槛 1：构建（警告视为错误）
# 覆盖 Swift 6 严格并发下的 actor-isolation 问题——这类问题在默认构建里只是
# 警告，只有加了该 flag 才会让构建失败。
# ---------------------------------------------------------------
run_gate "构建（-Xswiftc -warnings-as-errors）" \
    swift build --package-path "$PACKAGE_DIR" -Xswiftc -warnings-as-errors \
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
# 门槛 3（可选）：测试 + 覆盖率
# 复用 scripts/coverage.sh，避免门槛口径写两份。
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
