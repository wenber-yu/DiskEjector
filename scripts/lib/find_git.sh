#!/bin/bash
# =============================================================
# scripts/lib/find_git.sh —— 找一份**真能跑**的 git，并把它的目录放进 PATH。
#
# 用法（**必须 source，不能直接执行**）：
#
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/find_git.sh"
#     find_usable_git || exit 2      # 成功后：$GIT_BIN 有值、PATH 已修好
#     HEAD="$(git rev-parse HEAD)"   # 之后照常写 `git` 也行（PATH 里那份是好的）
#
# ⚠️ **不要在 `$( )` 里调 `find_usable_git`**：命令替换会开子 shell，
#    函数里设的 `GIT_BIN` / `PATH` **出不来**（本仓库已踩过同款，见 ci_status.sh 里
#    `gh_retry` 那段注释）。要「函数写全局」就用 `if find_usable_git; then …`。
#
# ## 为什么不能写 `GIT="$(command -v git)"`
#
# 本环境实测（2026-09-21）：`/usr/bin/git` **存在且可执行**（`[ -x ]` 为真、
# `command -v git` 也返回它），但它是 `xcrun` 桩 —— Xcode 许可未接受时它
# 只打印一句「You have not agreed to the Xcode license agreements」、
# **退出码仍是 0**、**标准输出为空**。于是：
#
#   - `HEAD="$(git rev-parse HEAD)"` 拿到**空串**，而脚本照常往下跑。
#     `ci_status.sh` 的症状：打印「等提交␣␣的 run 出现」（短号位置是空的）、
#     拿 `--commit ""` 去查 ⇒ **看起来像「run 还没创建」，实际是自家工具坏了**。
#   - `git status --porcelain | wc -l` 更坏：退出码被 `wc` 吃掉 ⇒ 打印 `0`
#     ⇒ 与「工作区干净」**逐字相同**（`build_app.sh` 的版本派生就在这条路上，
#     见本文件末尾的「已知未修的消费者」）。
#
# ⇒ 判据只能是**试跑看输出**（与 `tools/clt_swift_env.sh` 里那句
#   `xcrun --find` 同款）。`[ -x ]`、`command -v`、退出码 —— **三条都判不出来**。
#
# ⚠️ 找到的那份还要**放进 PATH**，不能只在本脚本里用变量记着：
#    `gh` 自己也要调 `git`，否则报
#    `failed to determine base repo: failed to run git: …license…`。
#
# ## 已知未修的消费者（2026-09-21 扫描所得）
#
# `build_app.sh:73-85` 的四个 `git_*` 函数（`2>/dev/null || true`）同样取不到值，
# 症状是**静默**产出 `VERSION=1.0.0 / BUILD_NUMBER=1 / commit=unknown / dirty=0`
# 的包，且因为 `dirty=0` 而**不打印任何告警**。
# 它没跟着改，是因为它的语义与本文件不同：那里的注释明说「非 git 环境返回空」
# 是**有意**的（支持从 tarball 构建）⇒ 要修必须先分清
# 「真的没有 git（容忍）」与「有 git 但它坏了（必须报错）」两种情形，另起一轮。
# =============================================================

# ⚠️ **不要 `set -e` / `set -u`**：本文件是 source 用的，`set` 会**泄漏给调用方**
# 的 shell —— 后面随便哪条命令碰到未定义变量就炸，症状与「环境没配好」逐字相同。
# 需要的地方一律写 `${VAR:-}`。

# 判据：这份 git 能不能**真的干活**。
# 只问 `rev-parse --git-dir`（在仓库里必然有输出，且与「HEAD 是否 detached」无关，
# 比问 HEAD 更适合当探针）。
git_usable() {
    local out
    out="$("$1" rev-parse --git-dir 2>&1)" || return 1
    [ -n "$out" ] || return 1
    # 桩的坏法：把许可警告当输出（退出码仍是 0）⇒ 按文案挡掉
    case "$out" in
        *license* | *License*) return 1 ;;
    esac
    return 0
}

# 逐个候选**试跑**，第一个能干的胜出。
# 成功：`GIT_BIN` 有值、`PATH` 已含它的目录、返回 0；失败返回 1（**不** exit，
# 由调用方决定怎么说这句话 —— 报错文案要贴调用方的上下文）。
find_usable_git() {
    GIT_BIN=""
    local c
    # ⚠️ 候选按「越通用越靠前」排：PATH 里那份若正常，本函数就是个空操作。
    #    后两个是本环境（许可未接受）的兜底，都按**实际试跑**判，不按存在性判。
    for c in "$(command -v git 2>/dev/null || true)" \
        "$(xcode-select -p 2>/dev/null || true)/usr/bin/git" \
        /Applications/Xcode.app/Contents/Developer/usr/bin/git \
        /Library/Developer/CommandLineTools/usr/bin/git; do
        [ -n "$c" ] || continue
        if git_usable "$c"; then
            GIT_BIN="$c"
            break
        fi
    done
    [ -n "$GIT_BIN" ] || return 1

    # 放进 PATH（去重），给「内部还会再调 git」的工具（`gh`）用。
    local d
    d="$(dirname "$GIT_BIN")"
    case ":$PATH:" in
        *":$d:"*) ;;
        *)
            PATH="$d:$PATH"
            export PATH
            ;;
    esac
    return 0
}
