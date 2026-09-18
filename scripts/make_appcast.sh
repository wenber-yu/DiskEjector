#!/bin/bash
# =============================================================
# 由 dist/ 里的分发产物生成 Sparkle 的 appcast.xml
#
# 用法：
#   PACKAGE=1 ./build_app.sh            # 先出 dmg / zip
#   ./scripts/make_appcast.sh           # 版本取最近的 tag
#   VERSION=2026.09.18.1 ./scripts/make_appcast.sh
#   SPARKLE_PRIVATE_KEY="$(cat ~/.sparkle/ed25519.pem)" ./scripts/make_appcast.sh
#
# 产出：dist/updates/appcast.xml
#   把它**提交进仓库**（或推 gh-pages），SUFeedURL 指向它的 raw 地址：
#   https://raw.githubusercontent.com/wenber-yu/DiskEjector/master/appcast.xml
#
# 私钥的三种给法（优先级从高到低）：
#   1) SPARKLE_PRIVATE_KEY 环境变量 —— 走 stdin，不落盘，CI 里从 secret 注入
#   2) 钥匙串里已有的 Sparkle 私钥（generate_keys 默认存这儿）—— 本机交互用
#   3) 都不给 —— 仍然生成 appcast，但**没有 edSignature**，配合 Info.plist 里
#      没写 SUPublicEDKey 时更新照样能装（不验签）。正式发布不要这样。
#
# 为什么不能把 SUFeedURL 直接指向 GitHub 的 /releases/latest：
#   那个链接给的是 HTML 页面 / atom 源，Sparkle 解析不了 —— 它要的是带
#   sparkle: 命名空间的 RSS，下载地址写在每个 item 的 enclosure 里。
#   GitHub Releases 只是**文件的托管处**，不是 feed。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKAGE_DIR/dist}"
UPDATES_DIR="$OUTPUT_DIR/updates"
APP_NAME="DiskEjector"
REPO_URL="https://github.com/wenber-yu/DiskEjector"

VERSION="${VERSION:-$(git -C "$PACKAGE_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
if [ -z "$VERSION" ]; then
    echo "❌ 取不到版本号：先打一个 tag（git tag -a v2026.09.18.1），或用 VERSION=… 显式指定" >&2
    exit 1
fi

# generate_appcast 在 SwiftPM 解包的 Sparkle 产物里（不是仓库自带的二进制）
# ⚠️ 不要加 `-perm +111`：那是 GNU find 的写法，macOS 的 BSD find 不认，
# 实测直接返回空（脚本就变成「永远找不到工具」）。
GEN_APPCAST="$(find "$PACKAGE_DIR/.build/artifacts" -type f -name generate_appcast -print -quit 2>/dev/null || true)"
if [ -z "$GEN_APPCAST" ]; then
    echo "❌ 找不到 generate_appcast（.build/artifacts 下没有 Sparkle 产物）" >&2
    echo "   先跑一次 swift build，让 SwiftPM 下载并解包 Sparkle 二进制包。" >&2
    exit 1
fi

# 更新归档：dmg 优先（Sparkle 支持 dmg/zip，同版本放两个会生成两条重复的 item）
ARCHIVE=""
for candidate in "$OUTPUT_DIR/$APP_NAME.dmg" "$OUTPUT_DIR/$APP_NAME.zip"; do
    if [ -f "$candidate" ]; then ARCHIVE="$candidate"; break; fi
done
if [ -z "$ARCHIVE" ]; then
    echo "❌ 没有找到分发产物：$OUTPUT_DIR/$APP_NAME.dmg 或 .zip" >&2
    echo "   先跑：PACKAGE=1 ./build_app.sh" >&2
    exit 1
fi

rm -rf "$UPDATES_DIR"
mkdir -p "$UPDATES_DIR"
# ⚠️ 上传时用的文件名**必须**与 appcast 里 enclosure 的末段逐字相同 ——
# 下方「回读」里有一条守卫专门比对这两者（2026-09-18 加：此前脚本的
# 指引写的是 `DiskEjector.dmg`，而 enclosure 是 `DiskEjector-<版本>.dmg`，
# 照指引做 = 用户点「安装更新」时 404，而 appcast 本身不报任何错）。
ARCHIVE_EXT="$(basename "$ARCHIVE" | awk -F. '{print $NF}')"
UPLOAD_ASSET="$UPDATES_DIR/$APP_NAME-$VERSION.$ARCHIVE_EXT"
cp "$ARCHIVE" "$UPLOAD_ASSET"

# 发布说明：同名（扩展名不同）的 .md / .html 会被 generate_appcast 自动捡走
if [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    cp "$RELEASE_NOTES_FILE" "$UPDATES_DIR/$APP_NAME-$VERSION.md"
fi

echo "▶ 生成 appcast（版本 $VERSION，归档 $(basename "$ARCHIVE")）..."
GEN_ARGS=(--link "$REPO_URL")
# GitHub Release 的资产地址：https://github.com/OWNER/REPO/releases/download/TAG/FILE
#
# ⚠️ 结尾的斜杠**不能省**（实测 2026-09-18）：不带斜杠时 generate_appcast 会把前缀最后一段
# 当成文件名替换掉，产出 `.../download/DiskEjector-1.2.3.dmg` —— tag 那一段没了，
# 而它**不报错**，只在用户点「安装更新」时 404。带斜杠才得到
# `.../download/v1.2.3/DiskEjector-1.2.3.dmg`。
GEN_ARGS+=(--download-url-prefix "$REPO_URL/releases/download/v$VERSION/")

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    # '-' = 从 stdin 读私钥（工具文档推荐的做法，私钥不落盘）
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GEN_APPCAST" --ed-key-file - "${GEN_ARGS[@]}" "$UPDATES_DIR"
else
    "$GEN_APPCAST" "${GEN_ARGS[@]}" "$UPDATES_DIR"
fi

APPCAST="$UPDATES_DIR/appcast.xml"
[ -f "$APPCAST" ] || { echo "❌ generate_appcast 没有产出 appcast.xml" >&2; exit 1; }

# ---------------------------------------------------------------
# 回读：enclosure 的地址必须真的能下载到
#
# generate_appcast 的 --download-url-prefix 拼接规则没有写在文档里，
# 拼错（少一个斜杠 / 多一个斜杠）不会报错，只会产出一个永远 404 的 feed ——
# 用户点「安装更新」才开始失败，那时已经发了版本了。
# ---------------------------------------------------------------
ENCLOSURE_URL="$(sed -n 's/.*<enclosure[^>]*url="\([^"]*\)".*/\1/p' "$APPCAST" | head -1)"
if [ -z "$ENCLOSURE_URL" ]; then
    echo "❌ appcast 里没有 enclosure，更新无法下载" >&2
    exit 1
fi
echo ""
echo "   enclosure: $ENCLOSURE_URL"
# 必须含 tag 那一段：少了它就是「前缀没带斜杠」那个坑，而那个坑不报错、只 404。
if ! printf '%s' "$ENCLOSURE_URL" | grep -q "releases/download/v$VERSION/"; then
    echo "❌ enclosure 里没有 releases/download/v$VERSION/ 这一段 —— 下载地址会 404" >&2
    echo "   检查 --download-url-prefix 是否以斜杠结尾（generate_appcast 不带斜杠会吃掉最后一段）。" >&2
    exit 1
fi
# 文件名也要对：enclosure 的末段必须与「我们要你上传的那个文件」同名。
# 这一条防的是「指引里写一个名字、enclosure 里写另一个名字」这种
# **两边各写一次、却没人比对**的分叉 —— 传上去也 404，而且不报错。
if [ "$(basename "$ENCLOSURE_URL")" != "$(basename "$UPLOAD_ASSET")" ]; then
    echo "❌ enclosure 的文件名（$(basename "$ENCLOSURE_URL")）与待上传文件（$(basename "$UPLOAD_ASSET")）不一致" >&2
    echo "   照现在的 enclosure 传上去也下不到；两者必须逐字相同。" >&2
    exit 1
fi
echo "   待上传：$UPLOAD_ASSET"
echo "   （文件名必须与上面 enclosure 的末段逐字相同，改名即 404）"
if printf '%s' "$ENCLOSURE_URL" | grep -q 'download//'; then
    echo "⚠️  enclosure 里出现了 download//（重复斜杠），请人工核对" >&2
fi
if ! grep -q "sparkle:edSignature" "$APPCAST"; then
    echo "⚠️  appcast 里没有 edSignature —— 这次没有签名（私钥未给 / 钥匙串里没有）。" >&2
    echo "    配合 Info.plist 里未写 SUPublicEDKey 时更新仍可安装，但**不验签**。" >&2
fi

cat <<NEXT

✅ 已生成：$APPCAST

下一步（三步，顺序不能反）：
  1) 创建 GitHub Release：tag 必须是 v$VERSION，并把
     $UPLOAD_ASSET
     作为资产上传 —— **文件名不能改**：appcast 的 enclosure 写的就是它，
     改名 = 用户点「安装更新」时 404，而 appcast 本身不会报任何错。
  2) 把 appcast.xml 提交并推送（SUFeedURL 读的是它的 raw 地址，推送后才生效）。
  3) 老版本应用启动 → 检查更新 → 应当看到 $VERSION。
NEXT
