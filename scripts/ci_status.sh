#!/bin/bash
# =============================================================
# 看最近一次 CI 的结论 —— 「推送之后」那一半（与 `run.sh check` 配对）
#
# 用法：
#   ./run.sh ci                 # 等最近一次 run 跑完，回显结论
#   ./run.sh ci --no-wait       # 只看当前状态，不等待
#   ./run.sh ci <run-id>        # 看指定的一次
#
# 退出码：0 = 绿 ／ 1 = 红 ／ 2 = 没拿到结论
#         ⚠️ 2 **不等于**绿 —— 这条是本脚本存在的意义之一，见下。
#
# 为什么需要它（2026-09-20）：CI 曾**连续 76 次红**（约 2.5 天）而没人看 ——
# 本地门槛每轮都报「4 道门槛全绿」，于是「推完就走」这件事没有任何落点。
# 本地门槛 ≠ CI（本地中文 / runner 英文）⇒ **验收是 CI 自己**。
#
# 设计上刻意避开的四个坑（都实测踩过）：
#   ① `gh` 不在 PATH 里（本环境 PATH 无 /opt/homebrew/bin）→ 绝对路径兜底
#   ② api.github.com 常见 `unexpected EOF`（约 2/3）→ 每次调用重试 3 次
#   ③ **「没找到 run」与「绿」在朴素写法下长得一样** → 单列一个退出码 2
#   ④ 「我看的是哪一次」必须自证 → 回显 run 的提交并与本地 HEAD 对比
# =============================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 2

# --- ① gh 定位 ---
GH="$(command -v gh 2>/dev/null || true)"
[ -n "$GH" ] || GH=/opt/homebrew/bin/gh
if [ ! -x "$GH" ]; then
    echo "错误：找不到 gh（PATH 与 /opt/homebrew/bin/gh 都试过了）" >&2
    exit 2
fi

# --- 参数 ---
WAIT=1
RUN_ID=""
for a in "$@"; do
    case "$a" in
        --no-wait) WAIT=0 ;;
        -*) echo "未知参数：$a" >&2; exit 2 ;;
        *)  RUN_ID="$a" ;;
    esac
done

# --- ② 带重试的 gh ---
gh_retry() {
    local i out
    for i in 1 2 3; do
        out="$("$GH" "$@" 2>&1)" && { printf '%s' "$out"; return 0; }
        [ "$i" -lt 3 ] && sleep 1
    done
    printf '%s' "$out"
    return 1
}

FIELDS='databaseId,status,conclusion,headSha,headBranch,displayTitle'
JQ_ROW='"\(.databaseId)\t\(.status)\t\(.conclusion // "-")\t\(.headSha[0:7])\t\(.headBranch)\t\(.displayTitle)"'

# --- 定位 run ---
if [ -n "$RUN_ID" ]; then
    info="$(gh_retry run view "$RUN_ID" --json "$FIELDS" --jq "$JQ_ROW")" || {
        echo "错误：拿不到 run $RUN_ID 的信息（id 不对或网络）" >&2
        echo "  gh 原始输出：$info" >&2
        exit 2
    }
else
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    info="$(gh_retry run list --branch "$BRANCH" --limit 1 --json "$FIELDS" \
        --jq ".[0] | $JQ_ROW")" || {
        echo "错误：拿不到分支 $BRANCH 的 run 列表（网络）" >&2
        echo "  gh 原始输出：$info" >&2
        exit 2
    }
fi

IFS=$'\t' read -r id status conclusion sha branch title <<<"$info" || true

# --- ③ 「查不到」必须与「绿」分开 ---
if [ -z "${id:-}" ] || [ "$id" = "null" ]; then
    echo "⚠️ 没找到任何 run —— **这不等于绿**。" >&2
    echo "   可能：还没推送过 / 分支名不对 / 刚刚推送、run 还没创建出来。" >&2
    exit 2
fi

# --- 等它跑完 ---
if [ "$status" != "completed" ] && [ "$WAIT" -eq 1 ]; then
    echo "⏳ run $id 还在跑（$status），等它结束…（Ctrl+C 可中断；之后用 ./run.sh ci --no-wait 看状态）"
    "$GH" run watch "$id" >/dev/null 2>&1 || true
    # 等完**重新取一次**状态：watch 的退出码不作为判据
    info="$(gh_retry run view "$id" --json "$FIELDS" --jq "$JQ_ROW")" || true
    IFS=$'\t' read -r id status conclusion sha branch title <<<"$info" || true
fi

# --- ④ 自证：我看的是哪一次？ ---
head_sha="$(git rev-parse --short=7 HEAD)"
echo "───────────────────────────────────────────────"
echo "run     $id"
echo "提交    $sha   （本地 HEAD $head_sha）"
echo "分支    $branch"
echo "标题    $title"
echo "状态    $status ／ 结论 ${conclusion:-?}"
echo "───────────────────────────────────────────────"

if [ "$sha" != "$head_sha" ]; then
    echo "⚠️ 这次 run 对应的提交（$sha）**不是**本地 HEAD（$head_sha）"
    echo "   ⇒ 它验的不是你刚改的代码。刚推的话，等几十秒让新 run 出现，再跑一次。"
fi

if [ "$status" != "completed" ]; then
    echo "⏳ 还没跑完（$status）—— **这不等于绿**。稍后再跑：./run.sh ci"
    exit 2
fi

case "$conclusion" in
    success)
        echo "✅ CI 绿"
        exit 0
        ;;
    *)
        echo "❌ CI 红：$conclusion"
        echo
        echo "── 失败详情（$GH run view $id --log-failed）──"
        if ! "$GH" run view "$id" --log-failed 2>&1; then
            echo "（取日志失败 —— 本环境网络不稳，重跑：$GH run view $id --log-failed）"
        fi
        exit 1
        ;;
esac
