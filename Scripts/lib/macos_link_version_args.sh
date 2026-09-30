#!/bin/bash
# =============================================================
# macos_link_version_args.sh — 修正 LC_BUILD_VERSION 的 sdk 戳（macOS 26 外观门控）
#
# 用法：`source "$SCRIPT_DIR/Scripts/lib/macos_link_version_args.sh" "$PACKAGE_DIR"`，
# 之后把 `${MACOS_LINK_VERSION_ARGS[@]+"${MACOS_LINK_VERSION_ARGS[@]}"}` 插进
# swift build / swift run 的参数里。
#
# ## 为什么需要（2026-09-30 实证，勿凭猜测改写）
#
# SwiftPM 的 XCBuild 路径把主可执行文件 LC_BUILD_VERSION 的 `sdk` 字段错钉成
# **部署目标**（`Package.swift` platforms `.macOS(.v14)` ⇒ sdk=14.0）。
# 而 AppKit / SwiftUI 的代际外观（macOS 26 Liquid Glass：侧栏浮岛、玻璃材质、
# 行 hover 高亮）按「**链接时 SDK 版本**」门控 —— sdk=14.0 的进程整体退回
# macOS 26 以前的旧观感，**与运行系统版本无关**。这正是「v3 主窗口侧栏浮岛
# 从未在真机出现」的根因（`vtool -show-build <产物>` 可复核 sdk 字段）。
#
# 修法：用 ld 的 `-platform_version <platform> <minos> <sdk>` 显式给一遍正确值：
# - `minos` 仍取 Package.swift 的部署目标（那里是唯一真相，不许在这里写死）；
# - `sdk` 取当前工具链 SDK 的真实版本（`xcrun --show-sdk-version`）。
#
# 验证方法：构建后 `vtool -show-build <产物>` 应看到
# `minos 14.0 / sdk 27.0`（sdk 随工具链走，不再等于 minos）。
# =============================================================

# $1 = 包根（Package.swift 所在目录）。
_macos_pkg_root="${1:-}"
if [ -z "${_macos_pkg_root}" ] || [ ! -f "${_macos_pkg_root}/Package.swift" ]; then
    echo "错误：macos_link_version_args.sh 需要包根路径作第一个参数（找不到 Package.swift）。" >&2
    return 1
fi

_macos_minos_major="$(grep -oE '\.macOS\(\.v[0-9]+' "${_macos_pkg_root}/Package.swift" \
    | head -1 | grep -oE '[0-9]+' | head -1)"
_macos_sdk_version="$(xcrun --show-sdk-version 2>/dev/null)"

if [ -z "${_macos_minos_major}" ] || [ -z "${_macos_sdk_version}" ]; then
    echo "错误：无法确定部署目标（Package.swift 的 .macOS(.vNN)）或 SDK 版本（xcrun）。" >&2
    return 1
fi

# bash 3.2 数组；消费方用 ${ARR[@]+"${ARR[@]}"} 展开（空数组守卫，见 preflight 同款写法）。
MACOS_LINK_VERSION_ARGS=(
    -Xlinker -platform_version
    -Xlinker macos
    -Xlinker "${_macos_minos_major}.0"
    -Xlinker "${_macos_sdk_version}"
)
