#!/bin/bash
# =============================================================
# 看**当前 HEAD 对应**的 CI 结论 —— 「推送之后」那一半（与 `run.sh check` 配对）
#
# 用法：
#   ./run.sh ci                 # 等当前 HEAD 的 run 跑完，回显结论（最多等 90s 出现）
#   ./run.sh ci --no-wait       # 只看当前状态，不等待
#   ./run.sh ci <run-id>        # 看指定的一次（可以是任意提交）
#
# 退出码：0 = 绿 ／ 1 = 红 ／ 2 = 没拿到结论
#         ⚠️ 2 **不等于**绿 —— 这条是本脚本存在的意义之一，见下。
#         （`cancelled` / `skipped` 也归到 2：被后续推送取代**不是失败**）
#
# 为什么需要它（2026-09-20）：CI 曾**连续 76 次红**（约 2.5 天）而没人看 ——
# 本地门槛每轮都报「4 道门槛全绿」，于是「推完就走」这件事没有任何落点。
# 本地门槛 ≠ CI（本地中文 / runner 英文）⇒ **验收是 CI 自己**。
#
# 设计上刻意避开的六个坑（都实测踩过）：
#   ① `gh` 不在 PATH 里（本环境 PATH 无 /opt/homebrew/bin）→ 绝对路径兜底
#   ② api.github.com 常见 `unexpected EOF`（约 2/3）→ 每次调用重试 3 次
#   ③ **「没找到 run」与「绿」在朴素写法下长得一样** → 单列一个退出码 2
#   ④ 「我看的是哪一次」必须自证 → 回显 run 的提交并与本地 HEAD 对比
#   ⑤ ⚠️ **「最近一次 run」未必是「刚推的那次」**：刚推完时 GitHub 可能还没创建
#      run，于是取到的是**上一个提交**的结论 ⇒ **假绿**（2026-09-20 实测撞到，
#      当时它报「✅ CI 绿」而那个绿属于上一次提交）。
#      ⇒ 无参数时按 `--commit <HEAD>` 查，并给它一段时间出现。
#   ⑥ ⚠️ **不要用「TAB 分隔 + read」解析字段**：空字段会**静默错位**。
#      TAB 属于 IFS 的**空白类**字符 ⇒ 连续两个 TAB 被合并成一个分隔符。
#      2026-09-20 实测：run 未完成时 `conclusion` 是**空字符串**（不是 null，
#      所以 `// "-"` 对它不生效）⇒ 少一个字段 ⇒ 后面每个字段都错位一格
#      （`提交` 位置显示的是分支名），而脚本**照常打印表格**、看不出坏。
#      ⇒ 改成 `--jq` 输出**多行**（一字段一行）+ 逐行 read：空行也是行，不会合并。
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
# ⚠️ 失败时把错误写进 `GH_ERR`，**不输出到 stdout**：否则错误文本会被当成「字段值」
#    读进去。2026-09-20 实测（用假 gh 复现）：`run view` 网络失败时
#    `failed to get run: … EOF` 被读成了 `id` ⇒ 表格里「run」栏显示错误文本、
#    其余栏全空，还触发了下面那条**方向错误**的警告。
# ⚠️ 输出走**全局变量** `GH_OUT`（不是 stdout）—— 因为调用方若写成
#    `info="$(gh_retry …)"`，命令替换会开**子 shell**，函数里的全局赋值**出不来**
#    （2026-09-20 实测：`X=""; f(){ X=hello; }; y="$(f)"; echo $X` ⇒ 空；
#    换成 `if f; then …` 才有值）。⇒ 调用方一律用 `if gh_retry …; then info="$GH_OUT"; …`。
GH_OUT=""
GH_ERR=""
gh_retry() {
    local i out
    for i in 1 2 3; do
        out="$("$GH" "$@" 2>&1)" && { GH_OUT="$out"; GH_ERR=""; return 0; }
        [ "$i" -lt 3 ] && sleep 1
    done
    GH_OUT=""
    GH_ERR="$out"
    return 1
}

FIELDS='databaseId,status,conclusion,headSha,headBranch,displayTitle'
# --- ⑥ 一字段一行（不用 TAB 分隔）---
JQ_FIELDS='(.databaseId // ""), (.status // ""), (.conclusion // ""), (.headSha[0:7] // ""), (.headBranch // ""), (.displayTitle // "")'

read_fields() {
    id=""; status=""; conclusion=""; sha=""; branch=""; title=""
    { read -r id; read -r status; read -r conclusion; read -r sha; read -r branch; read -r title; } <<<"$1" || true
}

# ⚠️ 这些变量在**所有**分支都必须先有值：`set -u` 下缺一个就报 `unbound variable`，
# 而 shell 因此退出时**退出码是 1** —— 与「CI 红」的退出码**相同** ⇒ 会被误读成「CI 红」。
id=""; status=""; conclusion=""; sha=""; branch=""; title=""

HEAD_FULL="$(git rev-parse HEAD)"
HEAD_SHORT="$(git rev-parse --short=7 HEAD)"

# --- 定位 run ---
if [ -n "$RUN_ID" ]; then
    # 显式指定：用户知道自己在看哪一次（可能是别的提交）
    if gh_retry run view "$RUN_ID" --json "$FIELDS" --jq "$JQ_FIELDS"; then
        info="$GH_OUT"
    else
        echo "错误：拿不到 run $RUN_ID 的信息（id 不对或网络）" >&2
        echo "  gh 原始输出：$GH_ERR" >&2
        exit 2
    fi
    read_fields "$info"
else
    # --- ⑤ 按**当前 HEAD 的提交**查，不是「最近一次」 ---
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$WAIT" -eq 1 ]; then LIMIT=90; else LIMIT=0; fi

    waited=0
    last_err=""
    while :; do
        if gh_retry run list --branch "$BRANCH" --commit "$HEAD_FULL" --limit 1 \
                    --json "$FIELDS" --jq ".[0] // {} | $JQ_FIELDS"; then
            info="$GH_OUT"; last_err=""
        else
            last_err="$GH_ERR"; info=""
        fi
        read_fields "$info"
        [ -n "${id:-}" ] && break

        if [ "$waited" -ge "$LIMIT" ]; then
            echo "⚠️ 没拿到提交 $HEAD_SHORT 的 CI 结论 —— **这不等于绿**。" >&2
            [ -n "$last_err" ] && echo "   最后一次 gh 输出：$last_err" >&2
            echo "   可能：run 还没创建（刚推完，稍后再跑）/ 该提交不触发 CI / 网络。" >&2
            exit 2
        fi
        [ "$waited" -eq 0 ] && echo "⏳ 等提交 $HEAD_SHORT 的 run 出现…（最多 ${LIMIT}s）"
        sleep 5
        waited=$((waited + 5))
    done
fi

# --- 等它跑完 ---
if [ "$status" != "completed" ] && [ "$WAIT" -eq 1 ]; then
    echo "⏳ run $id 还在跑（$status），等它结束…（Ctrl+C 可中断；之后用 ./run.sh ci --no-wait 看状态）"
    "$GH" run watch "$id" >/dev/null 2>&1 || true
    # 等完**重新取一次**状态：watch 的退出码不作为判据
    if gh_retry run view "$id" --json "$FIELDS" --jq "$JQ_FIELDS"; then
        info="$GH_OUT"
        read_fields "$info"
    else
        # ⚠️ **「查询失败」不能说成「还没跑完」**（2026-09-20 实测）：
        # 两者都退出码 2，但一个是「网络没回来」、一个是「CI 还在跑」——
        # 看的人会据此决定「要不要再等」，诊断方向完全不同。
        echo "⚠️ run $id 的状态**查询失败**（不是「还没跑完」，也不是绿）。" >&2
        echo "   最后一次 gh 输出：$GH_ERR" >&2
        echo "   网络恢复后重跑：./run.sh ci" >&2
        exit 2
    fi
fi

# --- ④ 自证：我看的是哪一次？ ---
echo "───────────────────────────────────────────────"
echo "run     $id"
echo "提交    $sha   （本地 HEAD $HEAD_SHORT）"
echo "分支    $branch"
echo "标题    $title"
echo "状态    $status ／ 结论 ${conclusion:--}"
echo "───────────────────────────────────────────────"

# ⚠️ 空 sha 与「不匹配」是两件事：前者是**没拿到**，后者才是「验了别的提交」。
# 2026-09-20 实测：查询失败时空 sha 被报成「它验的不是你刚改的代码」——方向完全错。
if [ -z "$sha" ]; then
    echo "⚠️ 没拿到这次 run 的提交号（字段查询不完整）—— **别**把它读成「验了别的提交」。" >&2
elif [ "$sha" != "$HEAD_SHORT" ]; then
    echo "⚠️ 这次 run 对应的提交（$sha）**不是**本地 HEAD（$HEAD_SHORT）"
    echo "   ⇒ 它验的不是你刚改的代码（显式指定别的 run-id 时就会这样）。"
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
    cancelled|skipped)
        # ⚠️ `cancelled` 是「被后续推送取代」，**不是失败** —— 报成「❌ CI 红」会误导
        # （2026-09-20 实测撞到：指定一个被取代的 run 时它报「❌ CI 红：cancelled」）。
        # 归到「没拿到有效结论」（退出码 2），与「绿」「红」都分开。
        echo "⏹ CI $conclusion —— **不是失败**：这次 run 被后续推送取代了（或没跑）。"
        echo "   要看结论请跑最新的那次：./run.sh ci"
        exit 2
        ;;
    *)
        echo "❌ CI 红：${conclusion:-(无结论字段)}"
        echo
        echo "── 失败详情（$GH run view $id --log-failed）──"
        if ! "$GH" run view "$id" --log-failed 2>&1; then
            echo "（取日志失败 —— 本环境网络不稳，重跑：$GH run view $id --log-failed）"
        fi
        exit 1
        ;;
esac
