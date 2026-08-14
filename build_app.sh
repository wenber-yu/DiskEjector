#!/bin/bash
# =============================================================
# DiskEjector — 一键生成 .app 脚本
# 用法：
#   ./build_app.sh                      # 默认版本 1.0.0
#   VERSION=2.1.0 ./build_app.sh        # 指定版本
#   OUTPUT_DIR=/tmp ./build_app.sh      # 指定输出目录（默认 dist/）
# 产物：dist/DiskEjector.app（可拖入 /Applications 或双击运行）
# 图标：复制预先生成的 DiskEjectorApp/Resources/AppIcon.icns（打包时不生成图标）；
#       图标由独立脚本生成：把源图放进 assets/icons/ 后运行
#         sh scripts/build_icon.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/DiskEjectorApp"

APP_NAME="DiskEjector"
EXECUTABLE="DiskEjectorApp"                 # SPM 可执行 target 名
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ICON_SOURCE="$PACKAGE_DIR/Resources/AppIcon.icns"

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

cd "$PACKAGE_DIR"

echo "▶ [1/4] Release 构建 ..."
swift build -c release --product "$EXECUTABLE"
BIN_PATH="$(swift build -c release --show-bin-path)/$EXECUTABLE"

echo "▶ [2/4] 组装 $APP_NAME.app ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleExecutable</key>
	<string>$EXECUTABLE</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.diskejector.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "▶ [3/4] 复制应用图标 ..."
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/"
    echo "   ✓ AppIcon.icns（来自 ${ICON_SOURCE}）"
else
    echo "   ⚠ 未找到 ${ICON_SOURCE}，将使用系统默认图标"
    echo "     生成图标：把源图放进 assets/icons/ 后运行 sh scripts/build_icon.sh"
fi

echo "▶ [4/4] 签名（ad-hoc） ..."
if codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "   ✓ ad-hoc 签名完成"
else
    echo "   ⚠ 签名跳过（本机运行不受影响）"
fi

echo ""
echo "=================================================="
echo " ✅ 应用已生成：$APP_BUNDLE"
echo "--------------------------------------------------"
echo " 运行：        open \"$APP_BUNDLE\""
echo " 安装到系统：  cp -R \"$APP_BUNDLE\" /Applications/"
echo "=================================================="
