#!/bin/bash
# =============================================================
# DiskEjector — 一键启动脚本
# 用法：./run.sh   （或 bash run.sh）
# 说明：在源码目录编译并启动 DiskEjector（菜单栏 App）。
#       可额外透传参数给程序本身，例如 ./run.sh --reset
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/DiskEjectorApp"

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

cd "$PACKAGE_DIR"
echo "▶ 启动 DiskEjector ..."
# exec 让程序直接接管当前终端进程，Ctrl+C 即可退出
exec swift run DiskEjectorApp "$@"
