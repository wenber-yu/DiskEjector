#!/bin/bash
# =============================================================
# DiskEjector — 一键生成 .app 脚本
# 用法：
#   ./build_app.sh                              # 版本与构建号从 git 自动派生（默认 direct 直发渠道）
#   BUILD_CHANNEL=direct ./build_app.sh         # 官网直发版（Developer ID，不开沙盒，可列出占用进程）
#   NOTARIZE=1 ./build_app.sh                   # 构建后自动公证 + 打包 DiskEjector.dmg（需 Developer ID 签名）
#   VERSION=2.1.0 ./build_app.sh                # 显式指定版本
#   BUILD_NUMBER=42 ./build_app.sh              # 显式指定构建号
#   OUTPUT_DIR=/tmp ./build_app.sh              # 指定输出目录（默认 dist/）
#   STRICT_CI=1 ./build_app.sh                  # 打包前先过 CI 的两道严格门槛
#                                               #   （-warnings-as-errors + swift-format --strict）
# 产物：dist/DiskEjector.app（可拖入 /Applications 或双击运行）
# 图标：复制预先生成的 Resources/AppIcon.icns（打包时不生成图标）；
#       图标由独立脚本生成：把源图放进 assets/icons/ 后运行
#         sh scripts/build_icon.sh
#
# ---------------------------------------------------------------
# 分发渠道（BUILD_CHANNEL）
#   mas    —— Mac App Store。强制 App Sandbox，占用进程检测降级为「无法检测」。
#   direct —— 官网 / GitHub 直发。Developer ID 签名、不开沙盒，lsof 可列出占用进程
#            （本应用核心价值所在）。用户需在「系统设置 › 隐私与安全性 › 完全磁盘访问」
#            中授权后检测才生效。
#
# 签名身份（SIGN_IDENTITY，可选）
#   mas    → "Apple Distribution: <Team Name> (<Team ID>)"
#   direct → "Developer ID Application: <Team Name> (<Team ID>)"
#   未设置时自动探测钥匙串，三档优先级依次回退：
#     1) Developer ID Application   —— 可公证、可正式分发
#     2) 任意其他稳定代码签名身份（如本机自签）—— 能保住 TCC 授权，但**无法公证/上架 MAS**
#     3) ad-hoc（"-"）              —— 仅供本机验证；且 TCC 授权每次重建都会失效
#   构建结束的摘要会明确标注当前用的是哪一档，不要把自签误认成 Developer ID。
#
# 正式分发（direct 渠道）还需公证，否则 Gatekeeper 拦截：
#   xcrun notarytool submit dist/DiskEjector.app --keychain-profile "<profile>" --wait
#   xcrun stapler staple dist/DiskEjector.app
# 之后打包 dmg：
#   hdiutil create -fs HFS+ -srcfolder dist -volname DiskEjector DiskEjector.dmg
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库根 == SPM 包根（Package.swift 位于仓库根目录，与 FCPX2AAF / ProxyGenerator 布局一致）
PACKAGE_DIR="$SCRIPT_DIR"

APP_NAME="DiskEjector"
EXECUTABLE="DiskEjectorApp"                 # SPM 可执行 target 名
# ---------------------------------------------------------------
# 版本号自动派生
#
# 优先取环境变量（CI 或手工发布时可精确指定）；未指定时从 git 派生：
#   VERSION      ← 最近的 tag（如 v1.2.0 → 1.2.0），无 tag 时回退 1.0.0
#   BUILD_NUMBER ← 提交总数，天然单调递增，不会像硬编码那样忘记改
#
# 仍保留显式覆盖能力，因为「从 tag 派生」在 hotfix 分支上可能取到不想要的 tag。
# ---------------------------------------------------------------
git_tag_version() {
    git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true
}
git_commit_count() {
    git rev-list --count HEAD 2>/dev/null || true
}

DERIVED_VERSION="$(git_tag_version)"
DERIVED_BUILD="$(git_commit_count)"

VERSION="${VERSION:-${DERIVED_VERSION:-1.0.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-${DERIVED_BUILD:-1}}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ICON_SOURCE="$PACKAGE_DIR/Resources/AppIcon.icns"

# ---------------------------------------------------------------
# 分发渠道 → 选择对应 entitlements
#   mas    : 强制 App Sandbox（MAS 要求）
#   direct : 不开沙盒，保留 Hardened Runtime（由 codesign --options runtime 提供）
# ---------------------------------------------------------------
# 主分发渠道为官网直发（保留 mas 分支仅供沙盒参考；MAS 会废掉「列出占用进程」的核心价值）。
BUILD_CHANNEL="${BUILD_CHANNEL:-direct}"
if [ "$BUILD_CHANNEL" = "direct" ]; then
    ENTITLEMENTS="$PACKAGE_DIR/Resources/DiskEjector.direct.entitlements"
else
    ENTITLEMENTS="$PACKAGE_DIR/Resources/DiskEjector.entitlements"
fi
# 签名身份：
#   显式设置 SIGN_IDENTITY 时直接使用；未设置则自动探测钥匙串里的
#   「Developer ID Application」证书——有了就自动采用（便于日后直接 NOTARIZE=1），
#   没有就回退 ad-hoc（"-"，仅供本机验证，无法公证/分发）。
#
# 无论身份来自哪里，都用 IDENTITY_KIND 记下它的**类型**，供后续文案与 NOTARIZE 前置检查使用。
# 为什么必须区分：自签身份（如 "DiskEjector Dev Signing"）同样能签出有效签名、保住 TCC 授权，
# 但它**无法公证、无法上架 MAS**。若一律显示成「Developer ID 证书」，使用者会误判自己
# 已经具备分发条件——这正是本项目曾出现的文案缺陷。
#   developer-id —— Apple 签发的 Developer ID Application：可公证、可正式分发
#   self-signed  —— 本机自签：开发期用来稳住 TCC 授权
#   adhoc        —— 无任何身份，仅供本机验证
#   explicit     —— 用户显式指定且类型未知
IDENTITY_KIND="explicit"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    case "$SIGN_IDENTITY" in
        "-") IDENTITY_KIND="adhoc" ;;
        *"Developer ID"*) IDENTITY_KIND="developer-id" ;;
        *) IDENTITY_KIND="explicit" ;;
    esac
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
    # 优先级 1：Developer ID Application（可公证、可正式分发）
    # **bash 管道坑**：`|` 的优先级高于 `||`。
    # 写成 `A | grep X || true | head | sed` 会被解析成 `(A|grep X) || (true|head|sed)`，
    # 即 grep 成功时后面的 `head | sed` **完全不执行**，导致提取到的还是整行原始输出。
    # 必须把 `|| true` 放到**整个管道的外层**。
    AUTO_ID="$(security find-identity -p codesigning -v 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*\) "([^"]+)".*/\1/' || true)"
    if [ -n "$AUTO_ID" ]; then
        SIGN_IDENTITY="$AUTO_ID"
        IDENTITY_KIND="developer-id"
        echo "   自动选用 Developer ID 证书: $SIGN_IDENTITY"
    else
        # 优先级 2：钥匙串里**任意**其他有效代码签名身份（例如本机自签的
        # "DiskEjector Dev Signing"）。
        #
        # **为什么必须有这一档**：TCC（完全磁盘访问）授权绑定的是代码签名身份。
        # ad-hoc（"-"）签名没有 Team ID，且 CDHash 随每次重建变化 → 系统视为另一个 app
        # → 用户刚在系统设置里授予的 FDA 立刻失效，横幅又冒出来。
        # 用带固定 Team ID（证书 OU 字段）的稳定身份签名后，TCC 按 TEAMID.bundle_id
        # 匹配，重建二进制也能保住授权。
        # `-v` 输出格式：`  1) 4C8302... "DiskEjector Dev Signing"`，
        # 身份行以「空格+序号+)」开头，汇总行（"1 valid identities found"）不匹配此模式。
        # certificate 名里有空格，取**最后一对引号**里的内容。
        # `|| true` 同样必须放在管道外层（见上方 bash 优先级说明）。
        AUTO_ID="$(security find-identity -p codesigning -v 2>/dev/null \
            | grep -E '^[[:space:]]+[0-9]+\)' \
            | grep -v 'Developer ID Application' \
            | head -1 \
            | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        if [ -n "$AUTO_ID" ]; then
            SIGN_IDENTITY="$AUTO_ID"
            IDENTITY_KIND="self-signed"
            echo "   自动选用稳定代码签名身份（自签）: $SIGN_IDENTITY"
            echo "         ⓘ 自签可保住 TCC 授权，但无法公证 / 无法上架 MAS"
        else
            SIGN_IDENTITY="-"
            IDENTITY_KIND="adhoc"
            echo "   警告：未找到任何代码签名身份，回退 ad-hoc"
            echo "         ad-hoc 下 TCC 授权每次重建都会失效（FDA 横幅反复出现）"
        fi
    fi
fi

if [ ! -f "$PACKAGE_DIR/Package.swift" ]; then
    echo "错误：找不到 $PACKAGE_DIR/Package.swift" >&2
    exit 1
fi

# ---------------------------------------------------------------
# STRICT_CI=1：打包前先过 CI 的两道严格门槛
#
# **为什么默认关闭**：这两道门槛比打包本身严格得多，日常迭代反复跑会拖慢节奏；
# 但它们恰恰是 CI 会拦下来的东西，而本脚本的 release 构建**不带**这些 flag，
# 所以「打包成功」不能推出「CI 会绿」。发布 / 提交 PR 前应显式开启：
#     STRICT_CI=1 ./build_app.sh
# 门槛实现见 scripts/preflight.sh（本地与 CI 共用同一文件，避免逻辑分叉）。
# ---------------------------------------------------------------
if [ "${STRICT_CI:-0}" = "1" ]; then
    echo "▶ [0/4] 严格门槛预检（STRICT_CI=1）..."
    "$SCRIPT_DIR/scripts/preflight.sh"
fi

# 注意：此处**不使用 shell 内建 `cd`** 切换目录。部分执行环境（带 brokered 沙盒的 shell）
# 在 `cd` 后会把脚本剩余部分放到一个不继承前面变量定义的新上下文里执行，导致后续步骤
# 报「未绑定变量」。改用 `env -C` 仅对 swift 构建命令临时切换工作目录（走 chdir 系统调用，
# 不被上述 broker 拦截），其余步骤一律使用绝对路径（$APP_BUNDLE 等），彻底规避该问题。
echo "▶ [1/4] Release 构建（渠道=${BUILD_CHANNEL}）..."
env -C "$PACKAGE_DIR" swift build -c release --product "$EXECUTABLE"
BIN_PATH="$(env -C "$PACKAGE_DIR" swift build -c release --show-bin-path)/$EXECUTABLE"

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
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
		<string>zh-Hant</string>
	</array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <!-- App Store Connect 要求声明是否使用非豁免加密；本应用不涉及加密，必须显式声明 false，
         否则每次上传都会被标记为「缺失合规信息」。 -->
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Wenbo. All rights reserved.</string>
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

echo "▶ [4/4] 签名（Hardened Runtime，渠道=${BUILD_CHANNEL}）..."
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "   ❌ 缺少 entitlements: $ENTITLEMENTS" >&2
    exit 1
fi

# --options runtime 启用 Hardened Runtime；--deep 覆盖嵌套内容。
if codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE" >/dev/null 2>&1; then
    case "$IDENTITY_KIND" in
        adhoc)
            echo "   ✓ ad-hoc 签名完成（未检测到任何代码签名身份，仅供本机验证，无法公证/分发）"
            ;;
        developer-id)
            echo "   ✓ Developer ID 签名完成: $SIGN_IDENTITY"
            echo "     ⓘ 可公证、可正式分发"
            ;;
        self-signed)
            echo "   ✓ 自签身份签名完成: $SIGN_IDENTITY"
            echo "     ⓘ 自签能保住 TCC 授权，但无法公证、无法上架 MAS"
            ;;
        *)
            echo "   ✓ 使用指定签名身份签名完成: $SIGN_IDENTITY"
            ;;
    esac
else
    echo "   ❌ 签名失败" >&2
    exit 1
fi

# 回读校验：按渠道确认沙盒 entitlement 状态符合预期，避免「以为签了其实没生效」。
echo "   校验签名："
if [ "$BUILD_CHANNEL" = "mas" ]; then
    codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
        && echo "     ✓ App Sandbox entitlement 已生效（MAS 必需）" \
        || { echo "     ❌ MAS 渠道必须包含 App Sandbox entitlement"; exit 1; }
else
    codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
        && { echo "     ❌ direct 渠道不应包含 App Sandbox entitlement（否则无法列出占用进程）"; exit 1; } \
        || echo "     ✓ 未启用 App Sandbox（直发版可枚举进程）"
fi

# ---------------------------------------------------------------
# 公证 + 打包（NOTARIZE=1 时启用，仅 direct 渠道需要）
#
# 公证是直发版绕开 Gatekeeper 拦截的强制步骤；MAS 走 App Store 审核，无需此步。
# 前置条件：
#   1) SIGN_IDENTITY 必须是 Developer ID Application（ad-hoc「-」无法公证）
#   2) 下列三者之一提供 notarytool 凭证：
#      a. NOTARY_KEYCHAIN_PROFILE="<profile>"          # 事先 xcrun notarytool store-credentials 存过
#      b. APP_STORE_CONNECT_API_KEY_ID / _ISSUER / _PATH # App Store Connect API 密钥（.p8 文件路径）
#      c. APPLE_ID / APPLE_APP_PASSWORD / APPLE_TEAM_ID  # Apple ID + 应用专用密码
# ---------------------------------------------------------------
if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ "$BUILD_CHANNEL" = "mas" ]; then
        echo "   ℹ️ MAS 渠道由 App Store 审核，无需公证，跳过 NOTARIZE"
    elif [ "$IDENTITY_KIND" != "developer-id" ]; then
        echo "   ❌ 公证需要 Developer ID Application 签名，当前身份「${SIGN_IDENTITY}」不被 notarytool 接受" >&2
        echo "      自签 / ad-hoc 签名均无法公证；请安装 Developer ID Application 证书后重试。" >&2
        exit 1
    else
        echo "▶ [5/5] 公证 + 打包 dmg ..."
        NOTARY_ARGS=()
        if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
            NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        elif [ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ] && [ -n "${APP_STORE_CONNECT_API_KEY_ISSUER:-}" ] && [ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]; then
            NOTARY_ARGS=(--key "$APP_STORE_CONNECT_API_KEY_PATH" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_API_KEY_ISSUER")
        elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
            NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
        else
            echo "   ❌ 未提供公证凭证：请设置 NOTARY_KEYCHAIN_PROFILE，或 App Store Connect API Key（APP_STORE_CONNECT_API_KEY_*），或 Apple ID（APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID）" >&2
            exit 1
        fi

        echo "   • 提交 .app 公证 ..."
        xcrun notarytool submit "$APP_BUNDLE" --wait "${NOTARY_ARGS[@]}" || { echo "   ❌ .app 公证失败"; exit 1; }
        xcrun stapler staple "$APP_BUNDLE"
        echo "   ✓ .app 已公证并钉入票根"

        DMG_PATH="$OUTPUT_DIR/DiskEjector.dmg"
        echo "   • 打包 dmg ..."
        hdiutil create -fs HFS+ -volname DiskEjector -srcfolder "$APP_BUNDLE" "$DMG_PATH"
        echo "   • 提交 dmg 公证 ..."
        xcrun notarytool submit "$DMG_PATH" --wait "${NOTARY_ARGS[@]}" || { echo "   ❌ dmg 公证失败"; exit 1; }
        xcrun stapler staple "$DMG_PATH"
        echo "   ✓ dmg 已公证并钉入票根：$DMG_PATH"
    fi
fi

echo ""
echo "=================================================="
echo " ✅ 应用已生成：$APP_BUNDLE"
echo "--------------------------------------------------"
if [ "$BUILD_CHANNEL" = "direct" ]; then
    echo " 渠道：官网直发（不开沙盒，可列出占用进程）"
    case "$IDENTITY_KIND" in
        adhoc)
            echo " 签名：ad-hoc（无代码签名身份，仅供本机验证，无法公证/分发）"
            ;;
        developer-id)
            echo " 签名：Developer ID（${SIGN_IDENTITY}）—— 可公证、可正式分发"
            ;;
        self-signed)
            echo " 签名：自签（${SIGN_IDENTITY}）—— 保 TCC 授权稳定"
            echo "        ⓘ 自签无法公证 / 无法上架 MAS；拿到 Developer ID 证书后本脚本会自动改用它"
            ;;
        *)
            echo " 签名：指定身份（${SIGN_IDENTITY}）"
            ;;
    esac
    echo " 注意：用户需在「系统设置 › 隐私与安全性 › 完全磁盘访问」授权后检测才生效"
    if [ "$IDENTITY_KIND" = "developer-id" ]; then
        echo " 正式分发：NOTARIZE=1 ./build_app.sh 自动公证并生成 DiskEjector.dmg"
    fi
else
    echo " 渠道：Mac App Store（强制沙盒，占用检测降级为「无法检测」）"
fi
echo " 运行：        open \"$APP_BUNDLE\""
echo " 安装到系统：  cp -R \"$APP_BUNDLE\" /Applications/"
echo "=================================================="
