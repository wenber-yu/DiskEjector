#!/usr/bin/env bash
# =============================================================
# 从 `swift test` 日志里摘出「最慢的几条测试」，拼成**一行**摘要。
#
# 【为什么要有它】
# 门槛 6（`Scripts/coverage.sh`）绿跑时只回显**最后 3 行**（`run_gate` 的
# `tail -3`），测试日志本身随 `mktemp` 一起删掉 ⇒ 测试的耗时分布**没有任何
# 观测窗口**。2026-09-21 那次「本地 <1s / CI 57.1s」的数字来自一次**红**跑，
# 之后再想看就得再造一次失败。
#
# 【⚠️ 口径：这个数字**不是**该测试自身的耗时】
# swift-testing 打印的 `passed after X seconds` 是「**完成时刻**距 run 开始」的
# 墙钟 —— 测试并行执行，早开始晚结束的那条会把**整个 run 的时长**算进去。
#
# 实测（`.build/preflight/门槛6.log`，2026-09-21 10:40 本机）：
#   · 最慢单条 `真实占用时关闭进程并推出()` = 22.030 秒
#   · 同一份日志的汇总行 `Test run with 442 tests in 56 suites failed after
#     22.032 seconds`                        = 22.032 秒
#   ⇒ **单条值 ≈ 整轮值**（差 0.002 秒）。它只说明「这条挂在最后」，
#     不说明「这条自己跑了 22 秒」。
#
# ⇒ 所以本函数的输出**必须**把口径印在结果里。判据就是那两条实测数字：
#   把 22.030 当成「该测试耗时」会得出「这条测试要 22 秒」的错结论。
#   （这与 §8.113.9 那条同源：`start()`→回调 与 `start()`→`await` 返回
#     是两个量，断言只能判前者。）
#
# ⇒ **要回答「卡在哪个时间窗」就换一把尺子**（2026-09-21 补）：
#   `Tools/probe/stamp_lines.py`（在**伪终端**里跑命令、逐行打**事件时刻**）
#   + `Tools/probe/test_timeline.py`（报「最长零完成窗口」与完成事件密度）。
#   ⚠️ **两者不可互相替代**：本函数给「谁挂在最后」（**完成时刻**排序），
#   那套装置给「哪段时间**一条测试都没完成**」—— 2026-09-21 实测整轮 21.8s 里
#   有一段 **4.504s 零完成**，而本函数的名单对此**一个字都说不出来**。
#
# 【为什么解析不到时**不**返回非 0】
# 本函数的产物是**诊断信息**，不是判据。返回非 0 会让「测试全绿但 swift 改了
# 输出格式」变成门槛红 —— 那与覆盖率毫无关系，正是「门槛会自己烂掉」的来源。
# 替代的可见性来自**自证字段**：输出里带 `[耗时行 N/M]`（N=解析到的条数，
# M=汇总行声明的测试数）。格式一变 N 会塌成 0 而 M 不变 ⇒ **数字自己会说话**。
#
# 【用法】
#   source Scripts/lib/test_timings.sh
#   test_timings_line <日志文件> [N=3]
#
# 【调用方契约】不依赖任何全局变量；不设置任何全局变量；不 `exit`。
# =============================================================

# 提取 `<秒数>|<名字>`，每行一条。
#
# ⚠️⚠️ **正则里绝不能出现 `[✔✘]` 这种多字节字符类**（2026-09-21 实测踩到）。
# BSD sed 在 `LC_ALL=C` 下把 bracket expression 当**字节集合**处理：`[✔✘]` 只
# 匹配**一个字节**，而 `✔` 是 3 字节（E2 9C 94）⇒ 匹配掉 E2 之后，紧跟的
# `[[:space:]]+` 撞上续字节 9C ⇒ **整条正则失败**。
# 症状是**本机（locale 未设 = C）一条都解析不出来、CI（LC_ALL=en_US.UTF-8）完全正常**
# —— 也就是「本地这个功能是废的，而 CI 绿」，方向与「本地绿 CI 红」相反、更难发现。
# ⇒ 判据：行首前缀一律用**纯 ASCII** 的 `^[^T]*`（勾叉/缩进都不含 `T`，照样吃得掉）。
# 实测 `[✔✘]` 与 `[^T]*` 两种写法在 C / en_US.UTF-8 下的输出：前者 ❌ 分叉，后者 ✅ 逐字节相同。
#
# 为什么是 `[^T]*` 而不是 `^.*`：`.*` 贪婪会吃到**最后一个** `Test `，若测试名里
# 含 `Test ` 就会切错；`[^T]*` **跨不过 T**，只能停在行首那个 `Test `。
#
# ⚠️ 同样只用 sed 的 `s///` 捕获组，**不做位置索引**（`awk substr` / `match` 的
#    RSTART）：BSD awk 在 C locale 下按字节索引，会把中文名字切碎 —— 同一类分叉。
#    `s///` 把匹配到的内容**原样搬运**，字节模式与字符模式结果相同。
#
# ⚠️ **必须显式删掉汇总行**：`✘ Test run with 442 tests in 56 suites failed
#    after 22.032 seconds with 1 issue.` 与普通结果行**同形**（`Test ... failed
#    after N seconds`），不删就会把「整轮」当成一条测试排进最慢名单里 ——
#    而它**永远**是第一名，于是名单的第一位被一个假条目占死。
#    这条判据同样只用 ASCII（`Test run with <数字> tests in `）。
#
# ⚠️ 结果行有**三种**结尾，全部在真实日志里出现过：
#    · `passed after N seconds.`
#    · `failed after N seconds with 1 issue.`
#    · `recorded an issue at <文件>:<行>:<列>: ...` ← **没有耗时**，自然被排除
#      这是**应该的**：它没有可比的数字。
test_timings_extract() {
    local log="$1"
    [ -f "$log" ] || return 0
    sed -e '/Test run with [0-9][0-9]* tests in /d' "$log" \
        | sed -nE 's/^[^T]*Test[[:space:]]+(.*)[[:space:]](passed|failed) after ([0-9.]+) seconds.*$/\3|\1/p'
}

# 汇总行声明的测试总数（自证用的分母）。取**最后**一条 —— 日志里可能因为
# 重试或分片出现多条，最后一条才是最终结论。
test_timings_declared_count() {
    local log="$1"
    [ -f "$log" ] || return 0
    sed -nE 's/^[^T]*Test run with ([0-9]+) tests in .*$/\1/p' "$log" | tail -1
}

# 输出**一行**摘要（调用方负责缩进/换行）。
test_timings_line() {
    local log="$1" top_n="${2:-3}"
    local all declared found out row i
    local -a rows=()

    # ⚠️ 先整份读进变量，**不把 `head` 接在管道上**：`set -o pipefail` 下
    #    `sed | sort | head -n 3` 里 head 提前退出 ⇒ 上游收 SIGPIPE(141) ⇒
    #    整条管道非 0 ⇒ 调用方 `set -e` 直接把门槛判红。数据量小时上游可能
    #    已经写完、head 不提前退出 ⇒ **时红时绿**，是最难查的那种 flaky。
    all="$(test_timings_extract "$log" | sort -t'|' -k1,1 -rn -s)"
    declared="$(test_timings_declared_count "$log")"

    if [ -z "$all" ]; then
        echo "   ⚠️ 未能从测试日志里解析出任何耗时行（日志格式可能变了）—— 最慢名单不可用"
        return 0
    fi

    # 按行遍历（**不按名字去重**：参数化测试会有同名条目，实测
    # `宿主必须关掉安全区` 等 4 个名字各出现 2 次 ⇒ 按名字去重会少报）。
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        i=$((i + 1))
        [ "$i" -gt "$top_n" ] && break
        rows+=("${row%%|*}s ${row#*|}")
    done <<< "$all"

    # ⚠️ 计数用 `wc -l` 而不是 `grep -c .`：`grep -c` 为 0 时**退出码是 1**，
    #    会吃掉 `&&` 链（本仓库在 shell grep 上反复踩过，见用户级记忆）。
    found="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"

    # ⚠️ 拼接用 `for` 遍历全部元素、靠 `out` 非空来决定分隔符，**不用数组切片
    #    `"${rows[@]:1}"`**：那在 `set -u` 下遇到元素不足时会报 unbound variable，
    #    而调用方 `coverage.sh` 正是 `set -euo pipefail`。
    #
    # ⚠️⚠️ **空数组要单独挡**：`"${rows[@]}"` 在**空数组 + `set -u`** 下同样报
    #    `rows[@]: unbound variable`（bash 3.2 / macOS 自带；实测 4.4 之前都这样）。
    #    触发条件是 `top_n = 0` —— 那时门槛会红，而报错信息与覆盖率毫无关系。
    #    本脚本的阳性对照（故意用 N=0 构造空名单）当场打出了这条报错。
    #    实测三种写法在 `set -u` + 空数组下：`${#a[@]}` ✅ 安全、
    #    `${a[@]+"${a[@]}"}` ✅ 安全、裸 `"${a[@]}"` ❌ 报 unbound ⇒ 用前者。
    out=""
    if [ "${#rows[@]}" -gt 0 ]; then
        for row in "${rows[@]}"; do
            out="${out}${out:+ · }${row}"
        done
    fi

    # 自证：解析到的条数 / 汇总行声明的条数。正常时两者接近（实测 441/442，
    # 差的那 1 条是没有耗时输出的 `recorded an issue` 行）；格式一变
    # 左边会塌成 0 而右边不变 ⇒ 读的人一眼能看出名单不可信。
    echo "   最慢 ${#rows[@]} 条（墙钟＝完成时刻距 run 开始，含并发调度等待，≠ 该测试自身耗时）：${out} ［耗时行 ${found}/${declared:-?}］"
}
