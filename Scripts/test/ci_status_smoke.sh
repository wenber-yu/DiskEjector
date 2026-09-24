#!/bin/bash
# =============================================================
# `ci_status.sh` 的冒烟测试 —— 把「几条关键路径」变成**一条命令**
#
# 为什么需要它（2026-09-20，见 SPEC §8.107）：
# 改一次 `gh_retry` 的接口，就得手工把几条路径各跑一遍（§8.107 的回归表就是这么来的）；
# 而其中**最关键的一条只能靠等网络抖动**才能出现 ⇒ 用假 gh（`Scripts/test/fake-gh/gh`）
# 把它变成确定性样本。
#
# 用法：./Scripts/test/ci_status_smoke.sh            # 全跑（含真 gh，看当前 HEAD 的结论）
#       ./Scripts/test/ci_status_smoke.sh --offline  # **只跑确定性用例**，不碰网络
# 退出码：0 = 确定性用例全部符合预期；1 = 有不符合；2 = 参数错误
#
# ⚠️ **`--offline` 是给门槛用的那一档**（`Scripts/preflight.sh` 用 `--offline` 调本脚本）：
#    CI 上不该因为「网络抖了」而红，也不该让一次门槛多花十几秒去等 `gh`。
#    默认（不带参数）那档是给人看的：多打几行当前 CI 结论，**不作为判据**。
#
# ⚠️ **判据是「退出码 + 输出里的关键串」两样都要对**：只看退出码的话，
#    「查询失败」与「还没跑完」都是 2 ⇒ 两者分不开 —— 那正是 §8.107 要修的毛病。
#
# ⚠️ 真 gh 的那几条（当前 HEAD）**故意不给期望值**：结果取决于 CI 与网络，
#    硬编码期望只会制造 flaky。这里只**打印**，供人眼看。
#
# ✅ **本装置「有牙」的证明**（2026-09-20，见 SPEC §8.107）：把 `ci_status.sh` 的
#    「查询失败」那一段**整块**退回修复前的写法 ⇒ 本脚本**红**（退出码 1），
#    且红在**对的那条**用例上，并把错误输出（「还没跑完」而非「查询失败」）打了出来。
#
# ✅ 2026-09-21 追加一条：**假 git 取不到 HEAD ⇒ 必须大声报错**。
#    它守的是 `ci_status.sh` ⓪ 段（找一份真能跑的 git）与「空 HEAD / 空分支名报错」，
#    背景见 `Scripts/lib/find_git.sh`。⚠️ 它与「假 gh：自动路径 ⇒ 查询失败」
#    构成**正负对照**：那条走「HEAD 拿到了、卡在 gh」，这条走「HEAD 就没拿到」——
#    少了任一条，都分不出坏在哪一环。
# ⚠️ 做这个变异时有个陷阱（我踩过一次）：把 `if gh_retry …; then A else B fi` 改成
#    `info="$(gh_retry …)" || true; …; if false; then A else B fi` **不是**模拟旧行为
#    —— `if false` ⇒ 走 `else`，**保留的正是新行为** ⇒ 变异会「假绿」，
#    而症状与「装置没牙」逐字相同。要模拟旧行为必须**整块替换**。
# =============================================================
set -uo pipefail

OFFLINE=0
for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        -h | --help)
            # ⚠️ **别写死行号区间**（原来是 `sed -n '3,30p'`）：抬头一改，`--help`
            #    就会**静默截断**（2026-09-21 在抬头加了两段才发现 —— 而截断后的
            #    帮助文本看起来仍然「像一份完整的帮助」）。改成「从第 3 行打到第一个非注释行」。
            awk 'NR >= 3 { if ($0 !~ /^#/) exit; print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "未知参数：${arg}" >&2
            echo "用法：./Scripts/test/ci_status_smoke.sh [--offline]" >&2
            exit 2
            ;;
    esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAKE="$REPO/Scripts/test/fake-gh"
GH="$(command -v gh 2>/dev/null || true)"
[ -n "$GH" ] || GH=/opt/homebrew/bin/gh

pass=0
fail=0

run_case() {
    local name="$1" want_code="$2" want_text="$3"
    shift 3
    local out code
    out="$("$@" 2>&1)"
    code=$?
    if [ "$code" != "$want_code" ]; then
        echo "✘ ${name}：期望退出码 ${want_code}，实得 $code"
        printf '%s\n' "$out" | tail -4 | while IFS= read -r l; do echo "      $l"; done
        fail=$((fail + 1))
        return
    fi
    case "$out" in
        *"$want_text"*)
            echo "✓ ${name}（退出码 ${code}）"
            pass=$((pass + 1))
            ;;
        *)
            echo "✘ ${name}：退出码对（${code}），但输出里没有「${want_text}」"
            printf '%s\n' "$out" | tail -4 | while IFS= read -r l; do echo "      $l"; done
            fail=$((fail + 1))
            ;;
    esac
}

echo "── 确定性用例（用假 gh，不需要网络）──"
run_case "假 gh：自动路径 ⇒ 查询失败" 2 "查询失败" \
    env PATH="$FAKE:$PATH" "$REPO/run.sh" ci
run_case "假 gh：显式 run-id ⇒ 拿不到 run" 2 "拿不到 run" \
    env PATH="$FAKE:$PATH" "$REPO/run.sh" ci 999999999
run_case "未知参数" 2 "未知参数" "$REPO/run.sh" ci --definitely-not-a-flag

# ---- git 取不到 HEAD 时必须**大声报错**，不能说成「run 还没创建」----
# 2026-09-21 实测：本环境 `/usr/bin/git` 是 `xcrun` 桩（存在、可执行、退出码 0、
# 无输出）⇒ 三处 `git rev-parse` 静默拿到空串 ⇒ 回显「等提交␣␣的 run 出现」
# （短号位置是空的）、拿 `--commit ""` 去查 —— **看起来像「run 还没创建」**。
# ⚠️ 与上面第一条用例构成**正负对照**：上面那条走的是「HEAD 拿到了、卡在 gh」，
#    这一条走的是「HEAD 就没拿到」。少了任一条，都分不出是哪一环坏的。
FAKE_GIT="$REPO/Scripts/test/fake-git-headless"
if [ -x "$FAKE_GIT/git" ]; then
    run_case "假 git：取不到 HEAD ⇒ 大声报错（不是「等 run 出现」）" 2 "取不到本地 HEAD" \
        env PATH="$FAKE_GIT:$FAKE:$PATH" "$REPO/run.sh" ci
else
    echo "✘ 找不到 $FAKE_GIT/git —— 这条用例**未执行**（跳过 ≠ 通过）"
    fail=$((fail + 1))
fi

echo
if [ "$OFFLINE" = "1" ]; then
    echo "⏭ --offline：跳过真 gh 那几条（它们只打印、本来就不作判据）。"
elif [ -x "$GH" ] && "$GH" run list --limit 1 >/dev/null 2>&1; then
    echo "── 真 gh（只打印，不给期望值：结果取决于 CI 与网络）──"
    "$REPO/run.sh" ci --no-wait 2>&1 | tail -8 | while IFS= read -r l; do echo "   $l"; done
else
    echo "⏭ 真 gh 那几条**跳过**（没登录 / 没网络）—— 跳过**不等于**通过。"
fi

echo
echo "── 合计：$pass 通过 / $fail 不符合 ──"
[ "$fail" -eq 0 ] || exit 1
exit 0
