#!/bin/bash
# =============================================================
# DiskEjector — 一键生成 .app 脚本
# 用法：
#   ./build_app.sh                      # 默认版本 1.0.0
#   VERSION=2.1.0 ./build_app.sh        # 指定版本
#   OUTPUT_DIR=/tmp ./build_app.sh      # 指定输出目录（默认 dist/）
# 产物：dist/DiskEjector.app（可拖入 /Applications 或双击运行）
# 图标：默认取 Resources/AppIcon.png 生成 icns；
#       如需高清图标，把 1024x1024 的 PNG 替换到该路径即可。
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
ICON_SOURCE="$PACKAGE_DIR/Resources/AppIcon.png"

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

echo "▶ [3/4] 生成应用图标 ..."
if [ -f "$ICON_SOURCE" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    for spec in \
        "16:icon_16x16" \
        "32:icon_16x16@2x" \
        "32:icon_32x32" \
        "64:icon_32x32@2x" \
        "128:icon_128x128" \
        "256:icon_128x128@2x" \
        "256:icon_256x256" \
        "512:icon_256x256@2x" \
        "512:icon_512x512" \
        "1024:icon_512x512@2x"; do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/$name.png" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "   ✓ AppIcon.icns 已生成（如需高清图标，替换 Resources/AppIcon.png 为 1024x1024）"
else
    echo "   ⚠ 未找到 $ICON_SOURCE，跳过图标"
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
