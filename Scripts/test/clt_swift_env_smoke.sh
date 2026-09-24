#!/usr/bin/env bash
# =============================================================
# 冒烟：`Tools/clt_swift_env.sh` 被 **`set -e` 的调用方** source 时不许静默死掉。
#
# 【为什么必须有这条门】
# 2026-09-24 实测（本轮抓到的真 bug）：写验收脚本时按惯例开头 `set -euo pipefail`，
# 再 `source Tools/clt_swift_env.sh` ⇒ **零输出 + 退出码 69**，连 shim 自己那几行
# 自证都打不出来。症状与「脚本根本没被 source」「环境更烂了」**逐字相同**。
#
# 根因：shim 里那句
#     _probe="$(/usr/bin/xcrun --find swiftc 2>&1)"
# —— 许可未接受时 `xcrun` 的退出码是 **69**（与 `xcodebuild -version` 的 0 不同，
# 两个命令的结论不能互相套用）。而 **「变量赋值」也是简单命令** ⇒ `set -e` 下
# 这个非零状态直接终止整个脚本，且发生在 shim 的第一行 echo **之前**。
# 修法是给那条命令补 `|| true`（本意是「把输出当数据用」，不是「当状态用」）。
#
# 【这条门守什么】
# 守的就是那个 `|| true` —— 它**看起来像噪音**，最容易被当成冗余清理掉，
# 而清理掉之后：本机（许可未接受）**静默死**，CI（许可正常）**照样绿**
# ⇒ 只有本机能发现，且发现时症状指向别处。
#
# 【装置怎么做到有牙（双向对照，不靠「跑起来没报错」）】
#   · ① 真 shim：rc=0 **且** 输出里有 `[clt-swift]` 自证行（行数 ≥1）。
#     ⚠️ 只判 rc=0 不够：`exit 0` 在最前面也是 rc=0 —— 自证行数把这两者分开。
#   · ② 合成「好 shim」（只 echo 一行自证）⇒ 期望**通过**。这是**阳性对照**：
#     证明「通过」这条判据不是恒假（否则任何东西都会被判红）。
#   · ③ 合成「坏 shim」：逐字复刻失败形态 `_v="$(exit 69)"`（**不带** `|| true`）
#     ⇒ 期望**失败**（rc≠0 或零输出）。这是**阴性对照**：证明装置真能观测到那个形态。
#     ③ 若被判成「通过」⇒ 判**装置没牙**，直接红（不是「代码没问题」）。
#   · ④ 自证测的是哪份文件：打印绝对路径 + 行数 + sha256 前 12 位。
#     路径写错 ⇒ ① 会拿到空输出 ⇒ 也会红（但 ④ 让「测错了文件」一眼可见）。
#
# 【用法】Scripts/test/clt_swift_env_smoke.sh
# 退出码：0 = 通过；1 = 未通过（含「装置没牙」）。
# =============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM="$REPO_ROOT/Tools/clt_swift_env.sh"

if [ ! -f "$SHIM" ]; then
    echo "   ✗ 装置坏了：找不到 $SHIM"
    exit 1
fi

TMP="$(mktemp -d -t clt-swift-env-smoke)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() {
    echo "   ✗ $1"
    FAILS=$((FAILS + 1))
}

# -------------------------------------------------------------
# 探针：**用 `set -euo pipefail` 去 source**（这正是会踩坑的调用方式）。
# 打印三列：rc、输出字节数、含 `[clt-swift]` 的行数。
# -------------------------------------------------------------
probe() { # probe <shim 绝对路径>
    local shim="$1" out rc
    out="$(cd "$REPO_ROOT" && bash -c "set -euo pipefail; source '$shim'; echo '__AFTER__'" 2>&1)"
    rc=$?
    printf '%s\t%s\t%s\n' \
        "$rc" \
        "$(printf '%s' "$out" | wc -c | tr -d ' ')" \
        "$(printf '%s\n' "$out" | grep -c 'clt-swift' || true)"
}

# -------------------------------------------------------------
# ④ 先自证：测的是仓库里那一份
# -------------------------------------------------------------
echo "④ 被测文件自证"
if command -v shasum >/dev/null 2>&1; then
    SUMS="$(shasum -a 256 "$SHIM" | cut -c1-12)"
else
    SUMS="(无 shasum)"
fi
echo "   文件：$SHIM"
echo "   行数：$(wc -l < "$SHIM" | tr -d ' ')   sha256[:12]=$SUMS"

# -------------------------------------------------------------
# ① 真 shim：rc=0 且自证行 ≥1
# -------------------------------------------------------------
echo ""
echo "① 真 shim（set -euo pipefail 下 source）"
read -r RC BYTES SELF < <(probe "$SHIM")
echo "   rc=$RC  输出=${BYTES}字节  自证行=$SELF"
if [ "$RC" != "0" ]; then
    fail "rc=${RC}（期望 0）—— 调用方带 \`set -e\` 时 shim 会**静默终止**；"
    echo "      多半是那条取输出的赋值又丢了 \`|| true\`（详见本脚本文件头）。"
fi
if [ "$SELF" -lt 1 ]; then
    fail "输出里一行 \`[clt-swift]\` 自证都没有 —— shim 没跑到自证段"
    echo "      （与「文件没被 source 到」同形；① 的路径已由 ④ 自证）。"
fi

# -------------------------------------------------------------
# ② 阳性对照：合成的「好 shim」必须被判**通过**
# -------------------------------------------------------------
echo ""
echo "② 阳性对照：合成的「好 shim」应当通过"
GOOD="$TMP/good.sh"
cat >"$GOOD" <<'EOF'
echo "  [clt-swift] 合成好 shim 自证"
EOF
read -r RC BYTES SELF < <(probe "$GOOD")
echo "   rc=$RC  输出=${BYTES}字节  自证行=$SELF"
if [ "$RC" != "0" ] || [ "$SELF" -lt 1 ]; then
    fail "合成的好 shim 都没通过（rc=$RC 自证行=${SELF}）⇒ **装置没牙**（判据恒假），不是代码问题"
fi

# -------------------------------------------------------------
# ③ 阴性对照：逐字复刻失败形态，必须被判**失败**
# -------------------------------------------------------------
echo ""
echo "③ 阴性对照：复刻失败形态（\$(exit 69) 且不带 || true）应当失败"
BAD="$TMP/bad.sh"
cat >"$BAD" <<'EOF'
_v="$(exit 69)"
echo "  [clt-swift] 这行永远打不出来"
EOF
read -r RC BYTES SELF < <(probe "$BAD")
echo "   rc=$RC  输出=${BYTES}字节  自证行=$SELF"
if [ "$RC" = "0" ] && [ "$SELF" -ge 1 ]; then
    fail "失败形态被判成**通过**（rc=$RC 自证行=${SELF}）⇒ **装置没牙**，不是代码问题"
fi
if [ "$RC" != "69" ] || [ "$SELF" != "0" ]; then
    echo "   ⚠️ 形态与实测不完全一致（实测 rc=69、自证行 0）—— 判据仍成立，但值得看一眼"
fi

# -------------------------------------------------------------
if [ "$FAILS" -gt 0 ]; then
    echo ""
    echo "   ✗ 未通过（$FAILS 条）"
    exit 1
fi
echo ""
echo "   ✓ 通过：带 \`set -e\` 的调用方 source 之后 rc=0、自证行打得出来；"
echo "     且装置经双向对照（合成好/坏 shim）证明能分辨 rc=0 与 rc=69 这两种形态"
