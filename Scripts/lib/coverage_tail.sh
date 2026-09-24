#!/usr/bin/env bash
# =============================================================
# 覆盖率门槛**成功路径**的收尾输出（`Scripts/coverage.sh` 唯一调用方）。
#
# 【为什么抽成函数】
# 门槛 6 由 `run_gate` 执行，**成功时只回显最后 3 行**（`Scripts/lib/gate_report.sh`
# 的 `sed ... | tail -3`）。所以「最慢名单能不能被看见」完全取决于它**排在第几行**
# —— 而这件事**源码文本断言守不住**（断言只能证明「那行还在」，证明不了「它在
# 最后 3 行里」）。抽成函数之后，`Scripts/test/coverage_tail_smoke.sh` 可以**真调它、
# 真做一次 `tail -3`**，把布局变成可测的。
#
# 【顺序即契约】这三行必须都在，且都在最后 3 行内：
#   1. `行覆盖率: X%   门槛: Y%`   ← 门槛的核心数字
#   2. `最慢 N 条（…）：…`          ← 诊断信息（口径见 Scripts/lib/test_timings.sh）
#   3. `✅ 覆盖率达标`              ← 通过的明确信号
#
# ⚠️ `test_timings_line` 的产物是**诊断**不是判据，解析不到时它只打一行警告、
#    返回 0。**不要**在这里把它变成判据 —— 理由见 `test_timings.sh` 文件头。
# =============================================================

# 自包含：调用方只需 source 本文件。
# shellcheck source=./test_timings.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_timings.sh"

# coverage_success_tail <测试日志> [最慢条数=3]
coverage_success_tail() {
    local test_log="$1" top_n="${2:-3}"
    test_timings_line "$test_log" "$top_n"
    echo "✅ 覆盖率达标"
}
