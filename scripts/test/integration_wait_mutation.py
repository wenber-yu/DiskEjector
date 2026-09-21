#!/usr/bin/env python3
"""`IntegrationEjectTests` 的**等待装置 / 诊断装置**的变异测试（手动跑，不进 CI）。

## 为什么需要

2026-09-21 这一轮改的是**测试装置**，不是产品：

1. `waitForDisk` —— 不再假设「`hdiutil attach` 返回 ⇒ 盘立刻可见」，改成**轮询**到
   `fetchExternalDisks()` 里出现为止（那才是产品自己的可见判定时点）；
2. `notFoundDiagnostic` —— 未找到测试盘时的失败文本，必须把**四条证据**打出来，
   好把「没挂上 / DiskArbitration 还没描述出它 / 枚举口径」三种可能分开。

两条都**必须**用变异证明：把新行为改回旧行为，对应的断言要变红。
没有这一步，它们与「没写」逐字相同 —— 因为「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

## ⚠️ 一次实测留下的重要提醒（2026-09-21）

变异 M1 下，**真机那条 `真实占用时关闭进程并推出` 照样是绿的** ——
也就是说「偶发」并没有被这条变异复现出来。⇒ **变异只证明「守卫有牙」，
不证明「那个偶发已经消失」**；这条测试的偶发本来就只有 ~1/几十 的概率。
别把「变异全红」当成「flaky 已修好」的证据。

## 用法

```bash
source tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 scripts/test/integration_wait_mutation.py
```

## 硬规则（沿用 `wait_outcome_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件、打印那一行），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
- 判红**看退出码**（`swift test` 失败即非 0），不靠 grep 认 ✘ 字符。
- 还原之后 `cmp -s` 再确认一次；还原步骤**不挂在会失败的命令后面**（别用 `&&` 串）。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INTEGRATION = REPO / "Tests/DiskEjectorAppTests/IntegrationEjectTests.swift"

# 整个套件一起跑：swift-testing 的 --filter 认名字正则，用套件名最稳（不会匹配到 0 条）。
FILTER_SUITE = "IntegrationEjectTests"

# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "`waitForDisk` 退回「只查一次」（模拟 2026-09-21 那次偶发的旧行为）",
        INTEGRATION,
        """        let started = Date()
        var polls = 0
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            polls += 1
            if let disk = await probe() {
                return (
                    WaitOutcome(ok: true, polls: polls, elapsed: Date().timeIntervalSince(started)),
                    disk
                )
            }
            // `Task.sleep` 是**让路**（不是 `usleep` 那种同步阻塞）——
            // 本套件不标 `@MainActor`，但协作线程池上的同步阻塞同样会饿着别的用例（§8.99）。
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // 退出循环时可能刚好是最后一拍就绪 —— 再查一次，别把「刚好赶上」误报成超时。
        polls += 1
        let found = await probe()
        return (
            WaitOutcome(ok: found != nil, polls: polls, elapsed: Date().timeIntervalSince(started)),
            found
        )""",
        """        let started = Date()
        _ = started.addingTimeInterval(timeout)
        let found = await probe()
        return (
            WaitOutcome(ok: found != nil, polls: 1, elapsed: Date().timeIntervalSince(started)),
            found
        )""",
        FILTER_SUITE,
    ),
    (
        "M2",
        "诊断里删掉 ② 与 ④ 两条证据（三种可能就分不开了）",
        INTEGRATION,
        """        ② 只喂它一个 URL 给 fetchExternalDisks()：\\(Self.enumerateOnly(vol))
           （空 = DiskArbitration 还描述不出它 / 判定为不可推出；非空 = 枚举本身能认它）
""",
        "",
        FILTER_SUITE,
    ),
    (
        "M3",
        "诊断装置瞎掉：`systemMounts()` 恒返回空数组",
        INTEGRATION,
        """        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            .map(\\.path)""",
        """        []""",
        FILTER_SUITE,
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
    return proc.returncode, "\n".join(raw.splitlines()[-14:])


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
