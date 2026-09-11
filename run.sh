#!/bin/bash
# =============================================================
# DiskEjector — 一键启动脚本
# 用法：
#   ./run.sh                # 编译并启动（菜单栏 App）
#   ./run.sh --reset        # 透传参数给程序本身
#   ./run.sh check          # 不启动，只过 CI 的两道严格门槛
#                           #   （-warnings-as-errors + swift-format --strict）
#   ./run.sh check --with-tests   # 追加测试与覆盖率门槛
# 说明：在源码目录编译并启动 DiskEjector（菜单栏 App）。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根 == SPM 包根
PACKAGE_DIR="$SCRIPT_DIR"

# 子命令 check：改完代码先过 CI 门槛的最短路径。
# 与 CI 调用同一个脚本（scripts/preflight.sh），确保本地判据与 CI 完全一致。
if [ "${1:-}" = "check" ]; then
    shift
    exec "$SCRIPT_DIR/scripts/preflight.sh" "$@"
fi

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

cd "$PACKAGE_DIR"
echo "▶ 启动 DiskEjector ..."
# exec 让程序直接接管当前终端进程，Ctrl+C 即可退出
exec swift run DiskEjectorApp "$@"
