#!/bin/bash
# =============================================================
# Scripts/lib/find_git.sh —— 找一份**真能跑**的 git，并把它的目录放进 PATH。
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
# ⇒ 判据只能是**试跑看输出**（与 `Tools/clt_swift_env.sh` 里那句
#   `xcrun --find` 同款）。`[ -x ]`、`command -v`、退出码 —— **三条都判不出来**。
#
# ⚠️ 找到的那份还要**放进 PATH**，不能只在本脚本里用变量记着：
#    `gh` 自己也要调 `git`，否则报
#    `failed to determine base repo: failed to run git: …license…`。
#
# ## 消费者
#
# - `Scripts/ci_status.sh` —— 本文件最初的动因（它那三处 `git rev-parse` 拿到空串后
#   会打印「等提交␣␣的 run 出现」，**看起来像「run 还没创建」**）。
# - `build_app.sh`（2026-09-21 接上）—— 它的四个 `git_*` 函数原先 `2>/dev/null || true`，
#   坏 git 下**静默**产出 `VERSION=1.0.0 / BUILD_NUMBER=1 / commit=unknown / dirty=0`
#   的包，且因为 `dirty=0` 而**不打印任何告警**（`dirty=0` 的意思是「工作区干净」，
#   而真相是「**不知道**」—— Swift 侧 `AppVersionInfo.dirtyCount` 的注释早就写明
#   「不要拿 0 代替缺失」）。
#   ⇒ 现在它**区分两种情形**：「一个可用 git 都没有」（容忍，写空）与
#     「有 git 但它取不到 HEAD」（**硬报错**，除非显式给了 `VERSION` + `BUILD_NUMBER`）。
#     判据与门见 `Scripts/test/build_app_version_smoke.sh`。
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
#
# ⚠️ 返回 1 时，调用方**还差一个信息**才能说对话：失败是「这台机器上没有 git」
#    还是「有 git，但它不干活」？两者**有意分开处理**（前者 = 从 tarball 构建，
#    是支持的用法；后者 = 环境坏了，必须大声）。⇒ 一并把
#    **`GIT_UNUSABLE_FOUND`**（0/1：候选里**存在**但没一个能干活）带出去。
#    这正是本仓库最贵的那个坑：**「没有」与「有但没用」在输出上逐字相同**。
find_usable_git() {
    GIT_BIN=""
    GIT_UNUSABLE_FOUND=0
    local c

    # ⚠️ **测试缝**（2026-09-21）：`FIND_GIT_ONLY` 设了就**只试这一个候选**。
    #    它存在的唯一理由是让「**一个可用 git 都没有**」这一档**可构造** ——
    #    否则那条判据永远没人验过（本机兜底候选里总有能跑的一份）。
    #    ⚠️ 生产路径**不设**它；别拿它当开关用。
    if [ -n "${FIND_GIT_ONLY:-}" ]; then
        if git_usable "$FIND_GIT_ONLY"; then
            GIT_BIN="$FIND_GIT_ONLY"
        else
            # 「存在但不可用」与「根本不存在」必须分开记
            if [ -e "$FIND_GIT_ONLY" ]; then GIT_UNUSABLE_FOUND=1; fi
            return 1
        fi
    else
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
            if [ -e "$c" ]; then GIT_UNUSABLE_FOUND=1; fi
        done
    fi
    [ -n "$GIT_BIN" ] || return 1

    # ---- 放进 PATH：给「内部还会再调 git」的工具（`gh`）用 ----
    #
    # ⚠️⚠️ **只在「`command -v git` 没解析到它」时才动 PATH**（2026-09-21 实测判红）。
    #    这是本文件最容易写错的一处，两个方向各踩过一次：
    #
    #    ① **旧写法「PATH 里已经有这个目录就跳过」**：好的那份**排在坏桩后面**时，
    #       跳过 = **什么都没修**（`gh` 用 `command -v git` 取第一个）。
    #    ② **改成「无条件摘掉旧位置再前置」之后**：那个目录**整体挪到最前**，
    #       连带把**同目录下的别的工具**也顶到最前 —— CI runner 上 `git` 与 `gh`
    #       同在 Homebrew 的 `/opt/homebrew/bin` ⇒ 把测试注入的**假 `gh` 顶掉了**
    #       （CI 门槛 4 `ci_status_smoke.sh` 判红，本地全绿：本机 git 与 gh 不同目录）。
    #
    #    ⇒ 正确的判据是**「现在的 `command -v git` 是不是就是它」**：
    #      - 是 ⇒ **什么都不用做**（绝大多数情况，包括 CI）—— 一个字节都不改 PATH；
    #      - 不是 ⇒ 才需要重排，此时前置那个目录（环境本来就已经错位，代价可接受）。
    #    ⚠️ 一般规则：**改共享环境变量（PATH）时要先问「同目录还有谁」。**
    if [ "$(command -v git 2>/dev/null || true)" = "$GIT_BIN" ]; then
        return 0
    fi

    local d
    d="$(dirname "$GIT_BIN")"
    PATH="$d:$PATH"
    export PATH
    return 0
}
