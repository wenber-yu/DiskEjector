#!/usr/bin/env python3
"""``WaitOutcome`` / ``appBundlePath`` 守卫的**变异测试**（手动跑，不进 CI）。

## 为什么需要

2026-09-21 这一轮加了三样东西，它们全都是「守装置」而不是「守产品」的：

1. ``WaitOutcome.diagnostic`` —— 失败信息里必须带「等了多久、求值几次」；
2. ``WaitOutcome.failureNote`` —— 那句话必须真的被拼进 `#expect` 的消息；
3. ``ProcessAppResolver.appBundlePath(fromRunningAppBundleURL:)`` ——
   运行中应用报的 `bundleURL` 只有真的是 `.app` 才可信。

第 3 条是**真 bug 修复**（CLT 下测试进程的 `bundleURL` 就是可执行文件自己的路径），
前两条是「下次 CI 红的时候能不能一眼看出真因」。
三条都**必须**用变异证明：把新行为改回旧行为，对应的断言要变红。
没有这一步，它们与「没写」逐字相同 —— 因为「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

## 用法

```bash
source tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 scripts/test/wait_outcome_mutation.py
```

## 硬规则（沿用 `test_timings_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件、打印那一行），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
- 判红**看退出码**（`swift test` 失败即非 0），不靠 grep 认 ✘ 字符。
- 还原之后 `cmp -s` 再确认一次；还原步骤**不挂在会失败的命令后面**（别用 `&&` 串）。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WAIT_OUTCOME = REPO / "Tests/DiskEjectorAppTests/WaitOutcome.swift"
OCCUPANCY = REPO / "Tests/DiskEjectorAppTests/OccupancyStoreTests.swift"
RESOLVER = REPO / "Sources/Services/ProcessAppResolver.swift"

# 两个「等待 helper 自己的守卫」的过滤器（swift-testing 的 --filter 认名字正则）。
FILTER_WAIT = "等待超时时必须报出轮询次数与耗时|等待可执行路径超时时必须报出轮询次数与耗时"
FILTER_BUNDLE = "非app的运行中应用路径不被当成bundle"

# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "`diagnostic` 退化成一句不带数字的空话（正是要修的病）",
        WAIT_OUTCOME,
        'format: "等了 %.2fs、求值 %d 次，条件%@",\n            elapsed, polls, ok ? "最终成立" : "始终不成立")',
        'format: "条件%@", ok ? "最终成立" : "始终不成立")',
        FILTER_WAIT,
    ),
    (
        "M2",
        "`failureNote` 把 `diagnostic` 整个丢掉（消息里就没有数字了）",
        WAIT_OUTCOME,
        'func failureNote(_ what: String) -> String {\n        "\\(what)\\n\\(diagnostic)"\n    }',
        'func failureNote(_ what: String) -> String {\n        "\\(what)"\n    }',
        FILTER_WAIT,
    ),
    (
        "M3",
        "`waitUntil` 不再累计轮询次数（`polls` 恒为 1）",
        OCCUPANCY,
        "    while Date() < deadline {\n        polls += 1\n        if await condition() {",
        "    while Date() < deadline {\n        if await condition() {",
        FILTER_WAIT,
    ),
    (
        "M4",
        "`waitUntil` 把墙钟报成 0（`elapsed` 不再反映真实等待）",
        OCCUPANCY,
        "    let ok = await condition()\n    return WaitOutcome(ok: ok, polls: polls, elapsed: Date().timeIntervalSince(started))",
        "    let ok = await condition()\n    return WaitOutcome(ok: ok, polls: polls, elapsed: 0)",
        FILTER_WAIT,
    ),
    (
        "M5",
        "`appBundlePath` 不再要求 `.app` 后缀（回到旧行为：直接采信 `bundleURL`）",
        RESOLVER,
        'guard let path, path.hasSuffix(".app") else { return nil }\n        return path',
        "return path",
        FILTER_BUNDLE,
    ),
]


def run_tests(filter_expr: str) -> tuple[int, str]:
    """跑一次 `swift test`（只跑目标用例），返回 (退出码, 原始尾部)。"""
    proc = subprocess.run(
        ["swift", "test", "--disable-sandbox", "--filter", filter_expr],
        cwd=REPO,
        capture_output=True,
        text=True,
        errors="replace",
    )
    raw = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, "\n".join(raw.splitlines()[-6:])


def main() -> int:
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
            # 装置自证 ①：变异真的写进去了（回读，不信写入返回）
            landed = new in path.read_text(encoding="utf-8")
            print(f"\n[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            if not landed:
                failures.append(f"{name}: 变异没写进去")
                continue
            code, tail = run_tests(filter_expr)
            print(f"[{name}] 原始尾部：\n{tail}")
            if code == 0:
                print(f"[{name}] ❌ 仍绿 —— 这条守卫没有牙")
                failures.append(f"{name}: 仍绿")
            else:
                print(f"[{name}] ✅ 被抓住（退出码 {code}）")
        finally:
            # ⚠️ 还原**单独一条**，不挂在可能失败的语句后面；还原后再 cmp 确认
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
