#!/bin/bash
# =============================================================
# `ci_status.sh` 的冒烟测试 —— 把「几条关键路径」变成**一条命令**
#
# 为什么需要它（2026-09-20，见 SPEC §8.107）：
# 改一次 `gh_retry` 的接口，就得手工把几条路径各跑一遍（§8.107 的回归表就是这么来的）；
# 而其中**最关键的一条只能靠等网络抖动**才能出现 ⇒ 用假 gh（`scripts/test/fake-gh/gh`）
# 把它变成确定性样本。
#
# 用法：./scripts/test/ci_status_smoke.sh
# 退出码：0 = 确定性用例全部符合预期；1 = 有不符合
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
# ⚠️ 做这个变异时有个陷阱（我踩过一次）：把 `if gh_retry …; then A else B fi` 改成
#    `info="$(gh_retry …)" || true; …; if false; then A else B fi` **不是**模拟旧行为
#    —— `if false` ⇒ 走 `else`，**保留的正是新行为** ⇒ 变异会「假绿」，
#    而症状与「装置没牙」逐字相同。要模拟旧行为必须**整块替换**。
# =============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAKE="$REPO/scripts/test/fake-gh"
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
        echo "✘ $name：期望退出码 $want_code，实得 $code"
        printf '%s\n' "$out" | tail -4 | while IFS= read -r l; do echo "      $l"; done
        fail=$((fail + 1))
        return
    fi
    case "$out" in
        *"$want_text"*)
            echo "✓ $name（退出码 $code）"
            pass=$((pass + 1))
            ;;
        *)
            echo "✘ $name：退出码对（$code），但输出里没有「$want_text」"
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

echo
if [ -x "$GH" ] && "$GH" run list --limit 1 >/dev/null 2>&1; then
    echo "── 真 gh（只打印，不给期望值：结果取决于 CI 与网络）──"
    "$REPO/run.sh" ci --no-wait 2>&1 | tail -8 | while IFS= read -r l; do echo "   $l"; done
else
    echo "⏭ 真 gh 那几条**跳过**（没登录 / 没网络）—— 跳过**不等于**通过。"
fi

echo
echo "── 合计：$pass 通过 / $fail 不符合 ──"
[ "$fail" -eq 0 ] || exit 1
exit 0
