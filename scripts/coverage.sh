#!/usr/bin/env bash
#
# 测试覆盖率门槛。
#
# 用法：
#   ./scripts/coverage.sh            # 使用默认门槛（见 DEFAULT_MIN 常量）
#   ./scripts/coverage.sh 45         # 指定门槛（百分比整数）
#   DISABLE_SANDBOX=1 ./scripts/coverage.sh   # 受管环境：跳过 SwiftPM 沙盒
#                                             # （报 sandbox_apply 失败时用）
#
# 统计口径：只统计「核心逻辑」——Models / Services / Settings。
# **为什么排除 Views 与 App 入口**：SwiftUI 视图与 NSApplication 委托几乎无法在
# 单元测试中真实驱动（需要宿主 App、runloop、窗口服务器），把它们计入分母会得到
# 一个被 UI 代码体量主导、对改进不敏感的数字。门槛的意义是防止核心逻辑的测试
# 被悄悄删掉，而不是追求一个漂亮的百分比。
#
# 排除范围是 **`Sources/DiskEjectorApp/` 整个目录**，而不是逐个文件列：
# 该目录是 AppKit 应用装配层（AppDelegate + MainMenu）。原先只排除了
# `DiskEjectorApp.swift` 一个文件，导致 2026-09-12 新增 `MainMenu.swift` 后
# 147 行无人测试的菜单构造代码混进分母，覆盖率从 62.5% 稀释到 56.7% ——
# 一个纯粹的记账噪音，掩盖了真实的核心逻辑覆盖率。按目录排除对后续新增文件免疫。

set -euo pipefail

DEFAULT_MIN=40
MIN_COVERAGE="${1:-$DEFAULT_MIN}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 仓库根 == SPM 包根
PACKAGE_DIR="$REPO_ROOT"

cd "$PACKAGE_DIR"

# DISABLE_SANDBOX=1：跳过 SwiftPM 自带的 sandbox-exec（受管环境嵌套沙箱会失败）。
# 仅影响构建期隔离，不改变测试与覆盖率结果；CI 不应设置此变量。
SWIFT_SANDBOX_FLAGS=()
if [ "${DISABLE_SANDBOX:-0}" = "1" ]; then
    SWIFT_SANDBOX_FLAGS+=(--disable-sandbox)
fi

echo "▶ 运行测试（启用覆盖率采集）..."
# 测试输出先落日志、按结果决定回显多少：
# 原先写成 `swift test ... | tail -3`，成功时省事，但**失败时只剩最后 3 行**，
# CI 上看到的就只有 `56 tests in 9 suites failed with 4 issues` 这一句，
# 4 个失败的具体断言全被吞掉，排查只能靠猜（本项目 2026-09-12 实际踩过）。
# 顺带也绕开了 `cmd | tail` 让 `$?` 变成 tail 状态的老坑——这里靠 pipefail 兜底，
# 但用日志文件表达意图更明确。
TEST_LOG="$(mktemp -t diskejector-tests)"
trap 'rm -f "$TEST_LOG"' EXIT

if ! swift test --enable-code-coverage \
    ${SWIFT_SANDBOX_FLAGS[@]+"${SWIFT_SANDBOX_FLAGS[@]}"} > "$TEST_LOG" 2>&1; then
    echo "   ✗ 测试未通过，完整输出如下："
    sed 's/^/     /' "$TEST_LOG"
    exit 1
fi
sed 's/^/     /' "$TEST_LOG" | tail -3

# 不同 Swift 版本的构建产物路径不同（.build/debug 或 .build/<triple>/debug），
# 因此用 find 定位而不是硬编码。
#
# **`-perm -111` 而不是 `-perm +111`**：`+111`（"任一执行位"）是已废弃的旧写法，
# 当前 macOS 自带的 find 直接报 `find: bad mode '+111'` 并返回空 ——
# 而这里带 `2>/dev/null || true`，错误被吞掉后只剩一个空字符串，
# 表面症状是「找不到覆盖率产物」，实际与覆盖率毫无关系（2026-09-15 踩到）。
# `-111`（"三个执行位都要有"）语义清晰且被所有版本接受。
# 这个 `-perm` 不只是过滤可执行文件：`.dSYM` 子目录也嵌在 `Contents/MacOS/` 下，
# 不加它会把 DWARF 调试文件当成测试二进制。
PROFDATA="$(find .build -name 'default.profdata' -print -quit 2>/dev/null || true)"
BINARY="$(find .build -path '*PackageTests.xctest/Contents/MacOS/*' -type f -perm -111 -print -quit 2>/dev/null || true)"

if [[ -z "$PROFDATA" || -z "$BINARY" ]]; then
    echo "✗ 找不到覆盖率产物（profdata='$PROFDATA', binary='$BINARY'）" >&2
    exit 1
fi

echo
echo "▶ 核心逻辑覆盖率（排除 Views/ 与 App 入口）..."
REPORT="$(xcrun llvm-cov report "$BINARY" \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='\.build|/Tests/|Views/|Sources/DiskEjectorApp/')"

echo "$REPORT"

# TOTAL 行第 10 列为行覆盖率（Filename Regions MissedRegions Cover Functions
# MissedFunctions Executed Lines MissedLines Cover ...）
LINE_COVER="$(echo "$REPORT" | awk '/^TOTAL/ {print $10}')"

if [[ -z "$LINE_COVER" ]]; then
    echo "✗ 未能从覆盖率报告中提取 TOTAL 行" >&2
    exit 1
fi

PERCENT="${LINE_COVER%\%}"
echo
echo "   行覆盖率: $LINE_COVER   门槛: ${MIN_COVERAGE}%"

# awk 做浮点比较，避免依赖 bc
if awk -v c="$PERCENT" -v m="$MIN_COVERAGE" 'BEGIN { exit !(c >= m) }'; then
    echo "✅ 覆盖率达标"
    exit 0
else
    echo "✗ 覆盖率未达标：当前 ${LINE_COVER} < 门槛 ${MIN_COVERAGE}%" >&2
    echo "  提示：若为新增未覆盖代码，请补充测试；" >&2
    echo "        若确属难以测试的代码，请调整门槛并在提交信息中说明理由。" >&2
    exit 1
fi
