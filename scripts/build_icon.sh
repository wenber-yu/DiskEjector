#!/usr/bin/env bash
# =============================================================================
# build_icon.sh — 把一张源图标转成 .app 可用的 AppIcon.icns（独立转换工具）。
#
# 设计（对齐同目录 FCPX2AAF 项目）：图标是「预先生成的静态资产」，
# 打包脚本 build_app.sh 只负责复制使用，绝不在打包时生成图标。
#
# 目录约定：
#   Design/app-icon/             <- 图标源图专用目录（你自己放图片）
#   Resources/AppIcon.icns    <- 生成的图标资产（构建时直接复制）
#
# 用法:
#   ① 方式 A（推荐，不用手动改名）：把一张图片复制进 Design/app-icon/，直接运行：
#        sh scripts/build_icon.sh
#      脚本会自动识别这张图片，规范化为 app_icon_source.png 后生成图标。
#   ② 方式 B（显式指定源图路径）：
#        sh scripts/build_icon.sh /path/to/my_icon.png
#
#   源图建议：≥1024×1024 的正方形 PNG（支持 png/jpg/jpeg/heic/tiff/webp/bmp/gif）。
#   生成后重新运行 ./build_app.sh 打包即带上新图标。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"   # 本脚本位于 scripts/，项目根为上一级

ICONS_DIR="$PROJECT_DIR/Design/app-icon"
CANONICAL="$ICONS_DIR/app_icon_source.png"   # 规范源图（脚本自动维护，无需手动改名）
OUT_ICNS="$PROJECT_DIR/Resources/AppIcon.icns"

# ---------- 确定源图 ----------
if [ "$#" -ge 1 ]; then
    # 方式 B：显式指定源图
    SRC="$1"
    if [ ! -f "$SRC" ]; then
        echo "❌ 源图不存在: $SRC" >&2
        exit 1
    fi
else
    # 方式 A：自动在 Design/app-icon/ 里查找源图
    mkdir -p "$ICONS_DIR"
    NEW_IMAGES="$(find "$ICONS_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.tiff' -o -iname '*.tif' -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \) ! -name 'app_icon_source.png' 2>/dev/null)"
    if [ -z "$NEW_IMAGES" ]; then
        NEW_COUNT=0
    else
        NEW_COUNT="$(printf '%s\n' "$NEW_IMAGES" | grep -c .)"
    fi

    if [ "$NEW_COUNT" -eq 0 ]; then
        # 没有新图：沿用已有的规范源图重新生成
        if [ -f "$CANONICAL" ]; then
            SRC="$CANONICAL"
            echo "ℹ️  未发现新图片，使用现有源图重新生成"
        else
            echo "❌ Design/app-icon/ 内没有可用的源图。" >&2
            echo "   请把一张图片（建议 ≥1024×1024 的正方形 PNG）复制进：$ICONS_DIR" >&2
            echo "   然后重新运行： sh scripts/build_icon.sh" >&2
            exit 1
        fi
    elif [ "$NEW_COUNT" -eq 1 ]; then
        # 恰好一张新图：规范化为 app_icon_source.png
        NEW_IMG="$(printf '%s' "$NEW_IMAGES" | head -n 1)"
        echo "🔎 检测到新图片: $NEW_IMG"
        ext="${NEW_IMG##*.}"
        if printf '%s' "$ext" | grep -iq '^png$'; then
            mv -f "$NEW_IMG" "$CANONICAL"
        else
            sips -s format png "$NEW_IMG" --out "$CANONICAL" >/dev/null
            rm -f "$NEW_IMG"
        fi
        SRC="$CANONICAL"
        echo "✅ 已规范化为源图: $CANONICAL"
    else
        echo "❌ Design/app-icon/ 里发现多张候选图片，无法自动判断用哪一张：" >&2
        printf '%s\n' "$NEW_IMAGES" | sed 's/^/     - /' >&2
        echo "   请只保留一张，或用方式 B 指定： sh scripts/build_icon.sh <图片路径>" >&2
        exit 1
    fi
fi

# ---------- 生成图标资产 ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 统一为 1024×1024 PNG 基准
BASE="$TMP/base.png"
sips -s format png "$SRC" --out "$BASE" >/dev/null
sips -z 1024 1024 "$BASE" --out "$BASE" >/dev/null

# 标准 .iconset 命名（macOS /bin/bash 3.2 不支持关联数组，用"尺寸:文件名"列表兼容）
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in \
    16:icon_16x16 \
    32:icon_16x16@2x \
    32:icon_32x32 \
    64:icon_32x32@2x \
    128:icon_128x128 \
    256:icon_128x128@2x \
    256:icon_256x256 \
    512:icon_256x256@2x \
    512:icon_512x512 \
    1024:icon_512x512@2x; do
    s="${spec%%:*}"
    f="${spec##*:}"
    sips -z "$s" "$s" "$BASE" --out "$ICONSET/$f.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo "✅ 图标资产已生成: $OUT_ICNS ($(du -h "$OUT_ICNS" | cut -f1))"
echo "   重新运行 ./build_app.sh 打包时自动带上该图标。"
