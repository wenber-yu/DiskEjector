#!/usr/bin/env python3
# =============================================================
# 变异测试：证明下面两个冒烟脚本对**实现**真的有牙。
#
#   · Scripts/test/test_timings_smoke.sh   守 Scripts/lib/test_timings.sh
#   · Scripts/test/coverage_tail_smoke.sh  守 Scripts/lib/coverage_tail.sh + coverage.sh 的接线
#
# 【为什么必须有这个脚本】
# 「冒烟全绿」有**三种**可能：① 实现是对的；② 冒烟脚本自己坏了（装置死了）；
# ③ 冒烟脚本太宽容（守不住）。三者输出**逐字相同**。
# 唯一能把它们分开的办法是**变异**：故意把实现改坏，看冒烟会不会红。
#
# 【为什么不放进 preflight】
# 变异要跑十几轮冒烟 + 反复改文件，属于**开发时**的验证，不是每次提交都该付的成本。
# 所以它**手动跑**。⇒ 文件头必须写清「怎么重跑」，否则它与「没做过」等价：
#     python3 Scripts/test/test_timings_mutation.py
#
# 【每条变异都对应一条**具体的**判据】，见 MUTATIONS 里每条的 `expect`。
#
# 【⚠️ 硬规则（本仓库踩过的坑）】
#   · 变异必须**确认落地**（改完回读一次）—— 没落地的变异会打印「仍绿」，
#     与「守卫没牙」逐字相同。
#   · 必须打印**原始输出**（冒烟的失败项列表），不只打印我的结论。
#   · 还原放 `finally` 里、并且**还原后回读校验** —— 否则一次失败会把改坏的文件
#     留在工作区，而后续所有结论都建立在坏文件上。
#   · 不用 `git checkout` 还原（会清掉未提交的改动，实测踩过）。
# =============================================================
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TIMINGS = REPO / "scripts" / "lib" / "test_timings.sh"
TAIL = REPO / "scripts" / "lib" / "coverage_tail.sh"
COVERAGE = REPO / "scripts" / "coverage.sh"
SMOKES = [
    REPO / "scripts" / "test" / "test_timings_smoke.sh",
    REPO / "scripts" / "test" / "coverage_tail_smoke.sh",
]

# (目标文件, 说明, 原文, 替换成, 预期红因)
MUTATIONS = [
    (
        TIMINGS,
        "M1 行首前缀换回多字节字符类 [✔✘]（C locale 下按字节匹配 ⇒ 分叉）",
        r"s/^[^T]*Test[[:space:]]+(.*)[[:space:]](passed|failed) after ([0-9.]+) seconds.*$/\3|\1/p",
        r"s/^[[:space:]]*[✔✘][[:space:]]+Test[[:space:]]+(.*)[[:space:]](passed|failed) after ([0-9.]+) seconds.*$/\3|\1/p",
        "三种 locale 输出必须逐字节相同 + 未设 locale 下要解析出 7 条",
    ),
    (
        TIMINGS,
        "M2 去掉排序（保持日志原始顺序）",
        """all="$(test_timings_extract "$log" | sort -t'|' -k1,1 -rn -s)\"""",
        """all="$(test_timings_extract "$log")\"""",
        "第一名/第二名/第三名的顺序断言",
    ),
    (
        TIMINGS,
        "M3 数值降序改成字典序（-rn → -r）",
        "sort -t'|' -k1,1 -rn -s",
        "sort -t'|' -k1,1 -r -s",
        "9.500s 若按字典序会抢到第一名",
    ),
    (
        TIMINGS,
        "M4 不再剔除汇总行（整轮会被当成一条测试）",
        """sed -e '/Test run with [0-9][0-9]* tests in /d' "$log" \\""",
        """cat "$log" \\""",
        "汇总行没有被当成一条测试（它是永远的第一名，会占死名单首位）",
    ),
    (
        TIMINGS,
        "M5 自证计数写死（解析条数恒报 442）",
        """found="$(printf '%s\\n' "$all" | wc -l | tr -d ' ')\"""",
        """found=442""",
        "自证字段正确（耗时行 7/442）",
    ),
    (
        TIMINGS,
        "M6 抹掉口径说明（数字会被误读成「该测试自身耗时」）",
        "≠ 该测试自身耗时",
        "耗时",
        "输出里写明了口径（不是该测试自身耗时）",
    ),
    (
        TIMINGS,
        "M7 把 head 接回管道（set -o pipefail 下的 SIGPIPE 陷阱）",
        """all="$(test_timings_extract "$log" | sort -t'|' -k1,1 -rn -s)\"""",
        """all="$(test_timings_extract "$log" | sort -t'|' -k1,1 -rn -s | head -n "$top_n")\"""",
        "大样本(20000 行) · set -euo pipefail 下退出码为 0",
    ),
    (
        TAIL,
        "N1 往收尾函数里多塞一行（会把通过信号挤出 tail -3）",
        """    test_timings_line "$test_log" "$top_n"
    echo "✅ 覆盖率达标\"""",
        """    test_timings_line "$test_log" "$top_n"
    echo "   （附加诊断）"
    echo "✅ 覆盖率达标\"""",
        "收尾函数恰好输出 2 行 + tail -3 里有「✅ 覆盖率达标」",
    ),
    (
        TAIL,
        "N2 删掉通过信号（✅ 覆盖率达标）",
        """    echo "✅ 覆盖率达标\"""",
        """    :""",
        "tail -3 里有通过信号「✅ 覆盖率达标」",
    ),
    (
        COVERAGE,
        "N3 拆掉接线（coverage.sh 不再调用收尾函数）",
        """    coverage_success_tail "$TEST_LOG" 3""",
        """    echo "✅ 覆盖率达标\"""",
        "coverage.sh 真的调用了收尾函数（非注释）",
    ),
    (
        COVERAGE,
        "N4 把最慢条数改成 0（名单退化成空名单）",
        """coverage_success_tail "$TEST_LOG" 3""",
        """coverage_success_tail "$TEST_LOG" 0""",
        "coverage.sh 真的调用了收尾函数且条数为 3（非注释）",
    ),
]


def run_smoke(smoke: Path) -> tuple[int, str]:
    p = subprocess.run(["bash", str(smoke)], capture_output=True, text=True, cwd=str(REPO))
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main() -> int:
    originals = {p: p.read_text(encoding="utf-8") for p in (TIMINGS, TAIL, COVERAGE)}

    # ── 基线自证：不变异时两个冒烟都必须绿 ──
    # 少了这一步，下面「变异后红了」可能只是因为冒烟脚本本来就红（装置坏了）。
    print("── 基线（未变异）──")
    for smoke in SMOKES:
        rc, out = run_smoke(smoke)
        if rc != 0:
            print(f"  ❌ 基线就是红的：{smoke.name} —— 后面的结论全部作废")
            print(out[-2000:])
            return 1
        print(f"  ✅ 基线绿：{smoke.name}")
    print()

    caught = 0
    problems: list[str] = []
    try:
        for target, name, old, new, expect in MUTATIONS:
            print(f"[{name}]")
            print(f"     靶文件：{target.relative_to(REPO)}")
            print(f"     预期红因：{expect}")
            original = originals[target]
            if old not in original:
                print("     ⚠️ 变异靶点没找到（原文不匹配）⇒ 这条变异**没落地**，结论作废")
                problems.append(f"{name}：变异靶点没找到")
                print()
                continue

            target.write_text(original.replace(old, new, 1), encoding="utf-8")

            # 变异落地自证：回读确认
            back = target.read_text(encoding="utf-8")
            if back == original or new not in back:
                print("     ⚠️ 变异没落地（回读不一致）⇒ 结论作废")
                problems.append(f"{name}：变异没落地")
                print()
                continue
            print("     ✅ 变异已落地（回读确认）")

            reds = []
            for smoke in SMOKES:
                rc, out = run_smoke(smoke)
                if rc != 0:
                    reds.append((smoke, out))
            if reds:
                print(f"     🔴 冒烟红了（{len(reds)}/{len(SMOKES)} 个）⇒ 守卫有牙")
                for smoke, out in reds[:1]:
                    fails = [l.strip() for l in out.splitlines() if l.strip().startswith("❌")]
                    print(f"        {smoke.name} 的实际失败项：")
                    for l in fails[:4]:
                        print(f"          {l}")
                    if len(fails) > 4:
                        print(f"          ……（共 {len(fails)} 条）")
                caught += 1
            else:
                print("     🟢 冒烟**仍然绿** ⇒ 这条变异没被抓住（守卫在这条轴上没牙）")
                problems.append(f"{name}：仍绿")
            print()

            # 每条之间立即还原，避免下一条建立在坏文件上
            target.write_text(original, encoding="utf-8")
            if target.read_text(encoding="utf-8") != original:
                print("     ⚠️ 还原失败 —— 中止（后续结论不可信）")
                problems.append(f"{name}：还原失败")
                break
    finally:
        for p, content in originals.items():
            p.write_text(content, encoding="utf-8")
        print("── 还原校验 ──")
        bad = [p.name for p, c in originals.items() if p.read_text(encoding="utf-8") != c]
        if bad:
            print(f"  ❌ 这些文件**未**还原：{', '.join(bad)}，请手工检查！")
            problems.append("还原校验失败")
        else:
            print("  ✅ 三个文件均已还原为原始内容")

    print()
    print(f"── 合计：{caught}/{len(MUTATIONS)} 条变异被守卫抓住 ──")
    if problems:
        print("   问题：")
        for p in problems:
            print(f"     · {p}")
    return 0 if caught == len(MUTATIONS) and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
