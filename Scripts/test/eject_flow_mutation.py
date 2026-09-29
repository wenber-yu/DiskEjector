#!/usr/bin/env python3
"""``EjectFlowController``「报错后验盘兜底」的**变异测试**（手动跑，不进 CI）。

## 为什么需要

2026-09-29 用户真机实测（v2026.09.29 build 297，转向「放行 + 菜单栏提醒」后的第一轮反馈）：
点提醒卡片「关闭并推出」后盘**已经推出**（Finder 重试风暴抢先推成了），
app 却弹「无法推出 OSStatus -36」**误报框**。真机日志铁证：

    10:31:29.764 推出失败: inUse(fBsyErr)     ← 我们第一次 unmount 被占用挡回（占用进程还活着）
    10:31:38.132 推出失败: other(OSStatus -36) ← 清场后重试落空：盘已被 Finder 抢先推出

修复 = 两个失败分支加**验盘兜底**：报错后挂载点已不在系统挂载列表里 ⇒
「推出」这个用户目标已达成 ⇒ 视作成功，不弹误报框。

这条判据**必须**用变异证明有牙：把兜底改回旧行为（报错即失败），
对应断言要变红。没有这一步，「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/eject_flow_mutation.py
```

## 硬规则（沿用 `eject_hook_mutation.py` 的现行口径）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件），否则「仍绿」可能只是没改上。
- **判红要正向证据**：`Test run with N tests` 且 `N ≥ 1` 才配谈红；
  `"error:" in raw` 是系统性误判（扫源码型守卫失败时整份文件被回显，
  文件里的 `error:` 会把「被抓住」误判成「编译不过」）。
- **编译失败两种形态都认**：`文件:行:列: error:` 与构建期无行号的
  `error: Build failed` / `error: fatalError`。
- **匹配 0 条时 `swift test` 打 warning 并返回 0** ⇒ 「退出码 0」同时表示
  「全通过」与「一条都没跑」，必须先拿 `Test run with N tests`。
- **`--filter` 只认类型标识符 / 测试函数名，不认 `@Suite("…")` 展示名**。
  `EjectFlowControllerTests` 没有 `@Suite` 展示名（`struct` 直接开头），
  所以基线自检**只能做条数下限核对**（没有展示名可核对）。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FLOW = REPO / "Sources/Services/EjectFlowController.swift"

TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)

# 基线：``EjectFlowControllerTests`` 全跑。2026-09-29 实测该 suite 为
# 45 条（含本轮新增 3 条）。防「过滤器只匹配上一部分」的半空转。
BASELINE_MIN_TESTS = 45
FILTER_BASELINE = "EjectFlowControllerTests"

MUTATIONS = [
    (
        "M1",
        "``eject(disk:)`` 的失败分支**拆掉验盘兜底**（报错即失败）⇒"
        "「盘已被 Finder 抢先推出」时照样弹「无法推出 -36」误报框 —— 用户实测的原 bug 复现",
        FLOW,
        "volumeMounted(disk.mountPath) ? .failed(reason: failure) : .ejected",
        ".failed(reason: failure)",
        "eject报错但盘已不在挂载列表时视作成功",
    ),
    (
        "M2",
        "``terminateAndEject`` 的验盘条件**反转**（`if volumeMounted` → `if !volumeMounted`）⇒"
        "两条守卫同时翻红：盘不在的报错被当成真失败（误报回来了），"
        "盘还在的报错被吞成成功（真故障被静默）",
        FLOW,
        "            if volumeMounted(disk.mountPath) {\n"
        "                outcome = .failed(reason: failure)\n"
        "            } else {",
        "            if !volumeMounted(disk.mountPath) {\n"
        "                outcome = .failed(reason: failure)\n"
        "            } else {",
        "terminateAndEject报错但盘已不在时视作成功|terminateAndEject报错且盘还在时仍报失败",
    ),
]


def run_tests(filter_expr: str) -> tuple[int, str]:
    """跑一次 `swift test`（只跑目标用例），返回 (退出码, 原始输出)。"""
    proc = subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", filter_expr],
        cwd=REPO,
        capture_output=True,
        text=True,
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def classify(code: int, raw: str) -> str:
    """把一次运行判成 `red` / `green` / `invalid`（口径见模块说明的「硬规则」）。

    要判红，先拿出「测试真的跑过」的正向证据（`Test run with N tests` 且 N ≥ 1）；
    一条都没跑到时按「构建成没成」+ 编译诊断分开两类 `invalid`。
    """
    run = TEST_RUN_RE.search(raw)
    if run is not None and int(run.group(1)) >= 1:
        return "green" if code == 0 else "red"
    if COMPILE_DIAG_RE.search(raw) or not BUILD_OK_RE.search(raw):
        return "invalid（变异体编译不过）"
    return "invalid（过滤器一条都没跑到）"


def baseline_is_green() -> bool:
    """先证明**未变异时装置是绿的**。

    双重自证：① ``classify`` 判 green；② 真的跑到 ≥ ``BASELINE_MIN_TESTS`` 条。
    （该 suite 没有 `@Suite` 展示名 ⇒ 没有第三重可核对，见模块说明。）
    """
    print("===== 基线自检（未变异）=====")
    code, raw = run_tests(FILTER_BASELINE)
    verdict = classify(code, raw)
    print(f"退出码 {code}，判定 {verdict}")
    print("原始尾部：")
    print("\n".join(raw.splitlines()[-6:]))
    if verdict != "green":
        print("⚠️ 基线不是绿的 —— 先修基线，再来谈变异。")
        return False
    count = int(TEST_RUN_RE.search(raw).group(1))
    if count < BASELINE_MIN_TESTS:
        print(f"⚠️ 基线只跑到 {count} 条（< {BASELINE_MIN_TESTS}）—— 过滤器少匹配了，结论作废。")
        return False
    print(f"基线跑到 {count} 条测试（≥ {BASELINE_MIN_TESTS}）")
    return True


def main() -> int:
    if not baseline_is_green():
        return 1

    failures: list[str] = []
    for name, why, path, old, new, filter_expr in MUTATIONS:
        original = path.read_text(encoding="utf-8")
        if old not in original:
            print(f"[{name}] ⚠️ 装置自证失败：目标片段不在 {path.name} 里 —— 这条变异没落地，结论作废")
            failures.append(f"{name}: 目标片段找不到")
            continue
        if original.count(old) != 1:
            print(f"[{name}] ⚠️ 目标片段出现 {original.count(old)} 次，无法唯一定位 —— 结论作废")
            failures.append(f"{name}: 片段不唯一")
            continue

        backup = Path(tempfile.mkdtemp(prefix="mut-")) / path.name
        shutil.copy2(path, backup)
        try:
            path.write_text(original.replace(old, new, 1), encoding="utf-8")
            landed = new in path.read_text(encoding="utf-8")
            print(f"\n[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            print(f"[{name}] 过滤器：{filter_expr}")
            if not landed:
                failures.append(f"{name}: 变异没写进去")
                continue
            code, raw = run_tests(filter_expr)
            verdict = classify(code, raw)
            lines = [ln for ln in raw.splitlines() if ln.startswith("✘") or "Test run with" in ln]
            print(f"[{name}] 守卫输出（✘ 与汇总行）：")
            for ln in lines[-8:] or ["（没有任何 ✘ / 汇总行）"]:
                print(f"        {ln}")
            print(f"[{name}] 原始尾部：\n" + "\n".join(raw.splitlines()[-4:]))
            if verdict == "red":
                print(f"[{name}] ✅ 被抓住（退出码 {code}）")
            elif verdict == "green":
                print(f"[{name}] ❌ 仍绿 —— 这条守卫没有牙")
                failures.append(f"{name}: 仍绿")
            else:
                print(f"[{name}] ❌ {verdict} —— 结论作废")
                failures.append(f"{name}: {verdict}")
        finally:
            shutil.copy2(backup, path)
        if path.read_text(encoding="utf-8") != original:
            print(f"[{name}] ⚠️ 还原后内容与原文不一致 —— 请人工核对 {path}")
            failures.append(f"{name}: 还原失败")
        else:
            print(f"[{name}] 还原确认：与原文逐字节一致")

    print("\n===== 汇总 =====")
    print(f"变异 {len(MUTATIONS)} 条，未通过 {len(failures)} 条")
    for item in failures:
        print(f"  - {item}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
