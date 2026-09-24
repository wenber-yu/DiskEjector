#!/usr/bin/env bash
# =============================================================
# 冒烟：`Scripts/lib/find_git.sh` 的核心契约 ——
# **「git 跑不跑得起来」只能靠试跑看输出判，不能靠存在性/可执行位/退出码。**
#
# 【为什么这条契约必须被守】
# 本环境（Xcode 许可未接受）实测：`/usr/bin/git` **存在**（`[ -x ]` 为真、
# `command -v git` 也返回它），但它是 `xcrun` 桩 —— 跑起来只打印一句
# 「You have not agreed to the Xcode license agreements」、**退出码仍是 0**、
# **标准输出为空**。2026-09-21 就是这么被带偏的：
#   - `ci_status.sh` 的三处 `git rev-parse` 静默拿到**空串** ⇒ 回显
#     「等提交␣␣的 run 出现」（短号位置是空的）、拿 `--commit ""` 去查
#     ⇒ **看起来像「run 还没创建」，实际是自家工具坏了**；
#   - `git status --porcelain | wc -l` 更坏：退出码被 `wc` 吃掉 ⇒ 打印 `0`
#     ⇒ 与「工作区干净」**逐字相同**。
#
# 【判据为什么是「一对正负」而不是「一条」】
# 只断言「对真 git 返回 0」守不住它 —— 那个断言在
# `git_usable() { [ -x "$1" ]; }` 这种实现上**同样通过**（而那种实现正是
# 本次要修掉的坏法）。⇒ 必须配**阴性对照**：一个「存在、可执行、退出码 0、
# 但不干活」的桩，必须被判为**不可用**。两条一起才说明：
# **是「试跑」在起作用**，而不是「碰巧存在」。
#
# 【本脚本不依赖机器上有没有可用的 git】
# 阳性/阴性对照全部用**自造的假 git**（本目录下现写现用）⇒ 装置是确定的。
# 只有最后那条端到端用例需要机器上真有一份可用 git；找不到时**判红并说清**
# （与 `stamp_lines_smoke.sh` 找不到 python3 时同款），**不许静默通过**。
#
# 【用法】Scripts/test/find_git_smoke.sh
# 退出码：0 = 通过；1 = 未通过。
# =============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO_ROOT/Scripts/lib/find_git.sh"
if [ ! -f "$LIB" ]; then
    echo "   ✗ 找不到 $LIB"
    exit 1
fi
# ⚠️ source 而不是执行：本文件要测的就是那两个函数（它们靠全局变量传结果）。
# shellcheck source=Scripts/lib/find_git.sh
. "$LIB"

TMP="$(mktemp -d -t find-git-smoke)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() {
    echo "   ✗ $1"
    FAILS=$((FAILS + 1))
}

# ---- 造三个假 git（都**存在且可执行**，区别只在跑起来干什么）----
# ① 能干活的：输出一个正常的 `rev-parse --git-dir` 结果
cat > "$TMP/good-git" <<'SH'
#!/bin/bash
case "${1:-}" in
    rev-parse) echo ".git" ;;
    *) echo ".git" ;;
esac
exit 0
SH
# ② xcrun 桩的坏法：打印许可警告、**退出码 0**
cat > "$TMP/license-stub" <<'SH'
#!/bin/bash
echo "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license'." >&2
echo "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license'."
exit 0
SH
# ③ 另一种坏法：什么都不打印、退出码 0（只按退出码判的实现会把它当好的）
cat > "$TMP/silent-stub" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$TMP/good-git" "$TMP/license-stub" "$TMP/silent-stub"

# ---- 装置自证：三个假 git 的**存在性**必须都为真 ----
# 否则下面「判为不可用」可能只是因为文件没造出来（与「判据生效」逐字相同）。
for f in good-git license-stub silent-stub; do
    if [ ! -x "$TMP/$f" ]; then
        echo "   ✗ 装置坏了：$TMP/$f 不存在或不可执行 ⇒ 本次结论作废"
        exit 1
    fi
done
echo "   [自证] 三个假 git 都已造出且可执行（${TMP}）"
echo "   [自证] 许可桩的原始输出（前两行）："
"$TMP/license-stub" 2>&1 | head -2 | sed 's/^/          /'
echo "   [自证] 许可桩的退出码：$("$TMP/license-stub" >/dev/null 2>&1; echo $?)（⚠️ 是 0 —— 所以退出码判不出来）"

# ---- ① 阳性：能干活的必须判为可用 ----
if git_usable "$TMP/good-git"; then
    echo "   [阳性] 能干活的假 git → 可用 ✓"
else
    fail "能干活的假 git 被判成了不可用 ⇒ 判据过严，会把好 git 也挡掉"
fi

# ---- ② 阴性：三种「看起来有、实际不干活」的必须判为不可用 ----
for case_spec in "license-stub:打印许可警告（xcrun 桩的坏法）" \
    "silent-stub:零输出（只按退出码判的实现会放过它）" \
    "nope-does-not-exist:根本不存在"; do
    name="${case_spec%%:*}"
    desc="${case_spec#*:}"
    if git_usable "$TMP/$name"; then
        fail "「${desc}」被判成了可用 ⇒ 判据没在**试跑**（本目录下 ${name}）"
    else
        echo "   [阴性] 「${desc}」→ 不可用 ✓"
    fi
done

# ---- ③ 端到端：坏 git 排在 PATH 最前时，find_usable_git 必须绕过它 ----
# 这一条测的是**本文件存在的理由**：`command -v git` 拿到的是坏的，
# 而函数要能继续往下找到一份真的，并把它的目录放进 PATH（`gh` 只认 PATH）。
#
# ⚠️ 判据是「**`command -v git` 解析到哪一份**」，不是「PATH 字符串里有没有它」：
#    `gh` 内部就是 `command -v git` 取**第一个**。2026-09-21 门槛 9 实测判红
#    （我的 shell 里恰好已经含了好的那份目录）⇒ 暴露出旧实现的漏洞：
#    它写成「PATH 里已经有这个目录就跳过前置」⇒ 好的那份排在坏桩**后面**时，
#    跳过 = **什么都没修**，而「有没有前置」这个较松的判据还会报绿。
#    ⇒ 实现改成「先摘掉全部旧出现位置、再前置」，判据也收紧到「解析到哪一份」。
ln -sfn "$TMP/license-stub" "$TMP/git"
OLD_PATH="$PATH"
PATH="$TMP:$PATH"
if find_usable_git; then
    if [ "$GIT_BIN" = "$TMP/git" ]; then
        fail "find_usable_git 选中了坏的桩（${GIT_BIN}）⇒ 绕过逻辑没生效"
    else
        echo "   [端到端] 绕过坏桩，选中：$GIT_BIN"
        RESOLVED="$(command -v git)"
        if [ "$RESOLVED" = "$GIT_BIN" ]; then
            echo "   [端到端] \`command -v git\` 解析到它（gh 的取法）✓"
        else
            fail "\`command -v git\` 解析到 ${RESOLVED}，而不是 ${GIT_BIN} ⇒ gh 仍会用坏的 git"
        fi
        case "$PATH" in
            "$(dirname "$GIT_BIN")":*)
                echo "   [端到端] PATH 已前置它的目录 ✓"
                ;;
            *)
                fail "PATH 没有被前置 $(dirname "$GIT_BIN")"
                ;;
        esac
        if [ -n "$("$GIT_BIN" rev-parse HEAD 2>/dev/null)" ]; then
            echo "   [端到端] 用它取到了 HEAD：$("$GIT_BIN" rev-parse --short=7 HEAD 2>/dev/null) ✓"
        else
            fail "选中的 git 取不到 HEAD ⇒ 「可用」的判据太松"
        fi
    fi
else
    echo "   ✗ 本机找不到任何**真能跑**的 git（候选都试跑过了）——"
    echo "     本次端到端用例**未执行**。⚠️ 这不是「代码问题」："
    echo "     正解是 sudo xcodebuild -license（需要你自己敲一次），"
    echo "     或装 Command Line Tools。"
    FAILS=$((FAILS + 1))
fi
PATH="$OLD_PATH"

# ---- ④ 端到端回归：**好的那份已经在 PATH 里，但排在坏桩后面** ----
# 这是 ③ 抓不到的那一半：③ 里好的那份原本**不在** PATH，所以「前置」必然成立。
# 真实场景是「PATH 里两份都有、坏的在前」⇒ 必须把好的**挪到最前**，
# 而不是「已经在 PATH 里了就跳过」。用同一对假 git 构造，判据同上。
if [ -n "${GIT_BIN:-}" ] && [ "$GIT_BIN" != "$TMP/git" ]; then
    PATH="$TMP:$(dirname "$GIT_BIN"):$OLD_PATH"   # 坏桩在前、好的在后
    if find_usable_git; then
        RESOLVED="$(command -v git)"
        if [ "$RESOLVED" = "$GIT_BIN" ]; then
            echo "   [回归] 好的那份原本排在坏桩后面 → 已挪到最前（gh 会取到它）✓"
        else
            fail "[回归] 好的那份已在 PATH 里但排在坏桩后面时没被挪前：\`command -v git\` → ${RESOLVED}"
        fi
    else
        fail "[回归] 装置异常：坏桩在前、好的在后时 find_usable_git 返回了失败"
    fi
    PATH="$OLD_PATH"
else
    echo "   [回归] 跳过（本机没有可用的真 git，③ 已判红）"
fi

# ---- ⑤ 回归：**PATH 重排不许连带顶掉同目录的别的工具** ----
# 2026-09-21 **CI 门槛 4 判红**抓到的（本地全绿）。CI runner 上 `git` 与 `gh`
# 同在 Homebrew 的 `/opt/homebrew/bin` ⇒ 当时那条「无条件摘掉旧位置再前置」的实现
# 把那个目录**整体挪到最前**，连带把 `ci_status_smoke.sh` 注入的**假 `gh` 顶掉了**
# ⇒ 门槛 4 判红（本地不红：本机 git 与 gh **不在**同一个目录）。
# ⇒ 判据：`command -v git` **已经**解析到它时，PATH 必须**一个字节都不改**。
SHARED="$TMP/shared"
mkdir -p "$SHARED" "$TMP/fakegh"
cp "$TMP/good-git" "$SHARED/git"
cat >"$SHARED/gh" <<'SH'
#!/bin/bash
echo "SHARED_GH"
SH
cat >"$TMP/fakegh/gh" <<'SH'
#!/bin/bash
echo "FAKE_GH"
SH
chmod +x "$SHARED/git" "$SHARED/gh" "$TMP/fakegh/gh"
if [ ! -x "$SHARED/git" ] || [ ! -x "$TMP/fakegh/gh" ]; then
    fail "装置坏了：⑤ 的假 git / 假 gh 没造出来 ⇒ 本次结论作废"
else
    PATH="$TMP/fakegh:$SHARED:$OLD_PATH"   # 假 gh 在前；同目录里同时有「好 git」和「真 gh」
    PATH_BEFORE="$PATH"
    if find_usable_git; then
        RESOLVED_GH="$(command -v gh)"
        if [ "$RESOLVED_GH" = "$TMP/fakegh/gh" ]; then
            echo "   [回归] 同目录的 \`gh\` 没被顶掉（仍解析到注入的那份）✓"
        else
            fail "[回归] PATH 重排把同目录的 \`gh\` 顶掉了：\`command -v gh\` → ${RESOLVED_GH}（期望 ${TMP}/fakegh/gh）—— 这会顶掉测试注入的假 gh（CI 门槛 4 就是这么红的）"
        fi
        if [ "$(command -v git)" = "$SHARED/git" ]; then
            echo "   [回归] \`command -v git\` 仍解析到那份能用的 ✓"
        else
            fail "[回归] \`command -v git\` → $(command -v git)，期望 $SHARED/git"
        fi
        # 自证：把「改没改 PATH」打出来 —— 只报「gh 没被顶掉」时，
        # 「没改」与「改了但恰好没影响」分不开（后者下次就会咬人）。
        if [ "$PATH" = "$PATH_BEFORE" ]; then
            echo "   [回归] PATH 未被改动（本来就解析正确 ⇒ 不该动它）✓"
        else
            # ⚠️ 只报**首项**：把整条 PATH 打出来会有几百个字符，淹掉真正的信息
            fail "[回归] PATH 被改了（本来就没坏，不该动）：首项 ${PATH_BEFORE%%:*} → ${PATH%%:*}"
        fi
    else
        fail "[回归] 装置异常：同目录里有能用的 git，find_usable_git 却返回失败"
    fi
    PATH="$OLD_PATH"
fi

if [ "$FAILS" -gt 0 ]; then
    echo "   ✗ 未通过（$FAILS 条）："
    exit 1
fi
echo "   ✓ 通过：判据是「试跑」而非「存在」；坏 git 会被绕过并接上可用的那份"
