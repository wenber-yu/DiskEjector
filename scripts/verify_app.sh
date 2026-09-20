#!/usr/bin/env bash
# =============================================================
# 产物自检：验证**打出来的 .app**（不是源码）具备上线的必要条件
#
# 【为什么要有它】2026-09-20：`ci.yml` 的「校验产物」只 `find` 了几个文件名，
# 于是「包能构建出来」被当成了「包是对的」。而下面每一条缺失时**打包都一路绿灯**：
#   - 没有 `SUPublicEDKey` ⇒ Sparkle **跳过验签**（中间人可推任意版本），且只在 stderr 打一行警告；
#   - 没有 `Contents/Frameworks/Sparkle.framework` ⇒ 一运行就崩（dyld 找不到）；
#   - `SUFeedURL` 丢了 ⇒ 「检查更新」永远成功、永远说「已是最新版本」（§8.94 那个病）。
#
# 【判据】读**产物**的 Info.plist 与目录结构（不是读 build_app.sh 的源码）——
#   拿源码跟自己比是「没牙」的守卫（§8.71）。
#
# 【用法】./scripts/verify_app.sh [app路径]      # 默认 dist/DiskEjector.app
# 【退出码】0 = 全部通过；1 = 有**必须修**的问题（缺 ED 公钥 / 缺框架 / 版本号空）
# =============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$REPO_ROOT/dist/DiskEjector.app}"

fail=0
note() { printf '   %s\n' "$1"; }
bad() {
    printf '   ❌ %s\n' "$1"
    fail=$((fail + 1))
}
good() { printf '   ✓ %s\n' "$1"; }

echo "产物自检：${APP}"

# ---------------------------------------------------------------
# 0. 包本身
# ---------------------------------------------------------------
if [ ! -d "$APP" ]; then
    echo "   ❌ 找不到 $APP —— 先跑 ./build_app.sh"
    exit 1
fi
good "包存在"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || {
    bad "缺 Contents/Info.plist"
    exit 1
}
good "Info.plist 存在"

# 只读一次，后面复用（PlistBuddy 每次调用都要重新解析，别重复付这个代价）
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }

# ---------------------------------------------------------------
# 1. Sparkle 框架**在包里**
#    缺了它：应用一启动就因 dyld 找不到框架而崩 —— 而构建**不会**失败。
# ---------------------------------------------------------------
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    good "Contents/Frameworks/Sparkle.framework 存在"
else
    bad "包内缺 Contents/Frameworks/Sparkle.framework（一运行就崩，而构建不会红）"
fi

# ---------------------------------------------------------------
# 2. 可执行文件存在且可执行
# ---------------------------------------------------------------
EXEC="$(pb CFBundleExecutable)"
if [ -z "$EXEC" ]; then
    bad "Info.plist 缺 CFBundleExecutable"
elif [ -x "$APP/Contents/MacOS/$EXEC" ]; then
    good "可执行文件 Contents/MacOS/${EXEC} 存在且可执行"
else
    bad "Contents/MacOS/${EXEC} 不存在或不可执行"
fi

# ---------------------------------------------------------------
# 3. 版本号（发行要用到，空了会让 appcast 比对出错）
# ---------------------------------------------------------------
VER="$(pb CFBundleShortVersionString)"
BUILD="$(pb CFBundleVersion)"
if [ -n "$VER" ] && [ -n "$BUILD" ]; then
    good "版本 ${VER}（build ${BUILD}）"
else
    bad "版本号不完整：CFBundleShortVersionString='${VER}' CFBundleVersion='${BUILD}'"
fi

# ---------------------------------------------------------------
# 4. SUFeedURL —— 丢了它「检查更新」会**永远成功且永远说已是最新版本**
# ---------------------------------------------------------------
FEED="$(pb SUFeedURL)"
if [ -n "$FEED" ]; then
    good "SUFeedURL = ${FEED}"
else
    bad "Info.plist 缺 SUFeedURL（『检查更新』会谎报『已是最新版本』，见 §8.94）"
fi

# ---------------------------------------------------------------
# 5. ⚠️ SUPublicEDKey —— 最重要的一条：没有它 Sparkle **跳过验签**
#    且与仓库里 build_app.sh 的默认值**同源**（防止哪天换了钥匙而产物还是旧的）
# ---------------------------------------------------------------
ED="$(pb SUPublicEDKey)"
DEFAULT_ED="$(
    sed -n 's/^DEFAULT_SPARKLE_PUBLIC_ED_KEY="\(.*\)"$/\1/p' "$REPO_ROOT/build_app.sh" | head -1
)"
if [ -z "$ED" ]; then
    bad "Info.plist 缺 SUPublicEDKey ⇒ **更新不验签**（中间人可推任意版本），而打包一路绿灯"
elif [ -n "$DEFAULT_ED" ] && [ "$ED" != "$DEFAULT_ED" ]; then
    bad "SUPublicEDKey 与 build_app.sh 的默认值不一致 ⇒ 产物=${ED} 仓库=${DEFAULT_ED}（换钥匙了吗？）"
else
    good "SUPublicEDKey 存在且与仓库同源（更新会被验签）"
fi

# ---------------------------------------------------------------
# 6. 签名自洽（**不**要求有正规身份 —— CI 上是 ad-hoc，那是正常的）
# ---------------------------------------------------------------
if SIGN_OUT="$(codesign --verify --deep "$APP" 2>&1)"; then
    good "codesign --verify 通过"
else
    note "codesign --verify 输出：$(printf '%s' "$SIGN_OUT" | head -2)"
    bad "codesign --verify 失败（签名不自洽 ⇒ 用户打开会被 Gatekeeper 拦）"
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo " ✅ 产物自检通过"
else
    echo " ✗ 产物自检有 ${fail} 项未通过"
fi
[ "$fail" -eq 0 ]
