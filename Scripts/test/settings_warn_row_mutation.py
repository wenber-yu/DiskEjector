#!/usr/bin/env python3
"""受阻行（`.sline--warn` 的产品侧实现）守卫的**变异测试**（手动跑，不进 CI）。

## 为什么需要

「通用」页在登录项第三态（已注册、等系统批准）会多出一行**受阻提示行** ——
浅琥珀底 + 琥珀标签 + 行尾「打开系统设置」按钮（设计稿 09 页第 2 帧，§8.153）。

它最阴的一点是：**底色与字色都不参与布局**，于是这条路的所有失败形态
渲染出来都是「一个看着正常的面板」：

| 写错的形态 | 渲染结果 | 高度类断言会红吗 |
|---|---|---|
| 底色忘了加 | 与普通行**逐像素相同** | ❌ |
| 底色加在内边距**之前** | 只有标签那一小块有色 | ❌ |
| 标签色忘了改 | 浅琥珀底上画的是黑字 | ❌ |
| 整行压根没插进去（判据写错） | 默认态照样正确 | ❌ |

四种的高度都与正确版**一字不差** ⇒ 正是本仓库那条红线
（「样式没生效」与「本来就没写」逐字相同）。
所以 `SettingsLayoutTests` 里那两条**像素判据**（暖色 / 琥珀）必须证明有牙，
否则「14 条全绿」只是一句好听的话。

## 五条变异各守什么（**互不覆盖**，这是本脚本最该被看见的地方）

| 变异 | 被哪条判据抓住 |
|---|---|
| M1 底色整块不画 | 暖色判据（`count` + `height`） |
| M2 标签色不跟色调走 | **只有琥珀判据**（暖色判据全绿） |
| M3 整行不插入 | 两条像素判据 + 高度断言 |
| M4 第三态判据写错 | 同上 |
| M5 底色只盖标签那一小块 | **只有 `height` 那条**（`count` 照样过万） |

M2 与 M5 这两行是重点：它们证明两条像素判据**各自都有独立的分辨力** ——
少写任何一条，对应那类失败就没人管。这不是理论推演，是下面逐条跑出来的。

## 用法

```bash
python3 Scripts/test/settings_warn_row_mutation.py
```

## 硬规则（沿用 `wait_outcome_mutation.py` / `settings_section_nav_mutation.py`）

- **备份用 `cp`，还原也写回原文**：不用 `git checkout`（会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件），否则「仍绿」可能只是没改上。
- **判红要正向证据**：`✘` 或汇总行的 `failed`。
- ⚠️ **先排除「变异体编译不过」**：那种情况判 `invalid`、结论作废，不算「被抓住」。
  判据是**没出现 `Build complete!`** —— 比 `"error:" in raw` 稳
  （测试失败输出里也可能含这个串）。
- 还原之后**回读比对哈希**；还原步骤不挂在会失败的命令后面（不用 `&&` 串）。
"""

from __future__ import annotations

import hashlib
import re
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "Sources/Views/SettingsView.swift"
FILTER = "SettingsLayoutTests"

BASELINE_TESTS = [
    "受阻行的琥珀底真的画出来了",
    "登录项待批准态的高度等于设计稿",
    "分隔线只画在卡片内的行与行之间",
]
BASELINE_MIN_TESTS = 14

MUTATIONS = [
    (
        "M1",
        "受阻行的底色整块不画（两个分支都 clear）⇒ 与新加功能完全无关",
        SRC,
        "            tone == .warning ? SettingsMetrics.warnRowBackground : Color.clear",
        "            Color.clear",
        FILTER,
    ),
    (
        "M2",
        "标签色不跟着色调走（始终用正文色）⇒ 浅琥珀底上画黑字",
        SRC,
        "                        tone == .warning\n"
        "                            ? DesignTokens.Palette.warningText\n"
        "                            : DesignTokens.Palette.foreground",
        "                        DesignTokens.Palette.foreground",
        FILTER,
    ),
    (
        "M3",
        "整块受阻行不插入（`if` 条件恒假）",
        SRC,
        "            if isLaunchAtLoginPendingApproval { loginPendingWarningLine }",
        "            if false { loginPendingWarningLine }",
        FILTER,
    ),
    (
        "M4",
        "第三态判据写错（认成 .disabled）",
        SRC,
        "        (launchAtLoginStateOverride ?? LaunchAtLoginManager.state) == .requiresApproval",
        "        (launchAtLoginStateOverride ?? LaunchAtLoginManager.state) == .disabled",
        FILTER,
    ),
    (
        "M5",
        "底色只盖住标签那一小块（加错层）",
        SRC,
        "        .background(\n"
        "            tone == .warning ? SettingsMetrics.warnRowBackground : Color.clear\n"
        "        )",
        "        .background(alignment: .top) {\n"
        "            if tone == .warning {\n"
        "                Rectangle().fill(SettingsMetrics.warnRowBackground).frame(height: 17)\n"
        "            }\n"
        "        }",
        FILTER,
    ),
]

TEST_RUN_RE = re.compile(r"Test run with (\d+) tests? in (\d+) suites?")


def run_tests(filter_expr: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["swift", "test", "--filter", filter_expr],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def classify(code: int, raw: str) -> str:
    """green / red / invalid。"""
    if "Build complete!" not in raw:
        return "invalid"
    if code == 0 and "✘" not in raw and "failed" not in raw:
        return "green"
    return "red"


def baseline_is_green() -> bool:
    print("=" * 72)
    print("基线自检（三重：绿 + 条数下限 + 名字逐个核对）")
    print("=" * 72)
    code, raw = run_tests(FILTER)
    verdict = classify(code, raw)
    print(f"基线判定：{verdict}（退出码 {code}）")
    print("原始尾部：")
    print("\n".join(raw.splitlines()[-5:]))
    if verdict != "green":
        print("⚠️ 基线不是绿的 —— 先修基线，再来谈变异。")
        return False

    run = TEST_RUN_RE.search(raw)
    count = int(run.group(1)) if run else 0
    missing = [name for name in BASELINE_TESTS if name not in raw]
    print(
        f"基线跑到 {count} 条测试；关键测试名核对："
        + ("全在" if not missing else "缺 " + "、".join(missing))
    )
    if count < BASELINE_MIN_TESTS:
        print(f"⚠️ 基线只跑到 {count} 条（< {BASELINE_MIN_TESTS}）—— 过滤器少匹配了，结论作废。")
        return False
    if missing:
        print("⚠️ 有关键测试名没跑到 —— 基线覆盖不完整，结论作废。")
        return False
    return True


def main() -> int:
    if not baseline_is_green():
        return 1

    failures: list[str] = []
    for name, why, path, old, new, filter_expr in MUTATIONS:
        original = path.read_text(encoding="utf-8")
        original_sha = hashlib.sha256(original.encode("utf-8")).hexdigest()
        if original.count(old) != 1:
            print(f"[{name}] ⚠️ 目标片段在 {path.name} 里出现 {original.count(old)} 次 —— 结论作废")
            failures.append(f"{name}: 片段不唯一")
            continue

        backup = Path(tempfile.mkdtemp(prefix="mut-warnrow-")) / path.name
        backup.write_text(original, encoding="utf-8")
        try:
            path.write_text(original.replace(old, new, 1), encoding="utf-8")
            # 装置自证 ①：变异真的写进去了（回读，不信写入返回）
            landed = new in path.read_text(encoding="utf-8")
            print()
            print(f"[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            if not landed:
                failures.append(f"{name}: 变异没写进去")
                continue

            code, raw = run_tests(filter_expr)
            verdict = classify(code, raw)
            lines = [
                ln
                for ln in raw.splitlines()
                if ln.strip().startswith("✘") or "Test run with" in ln
            ]
            print(f"[{name}] 守卫输出（✘ 与汇总行）：")
            for ln in (lines[-8:] or ["（没有任何 ✘ / 汇总行）"]):
                print(f"        {ln.strip()}")

            if verdict == "red":
                print(f"[{name}] ✅ 被抓住（退出码 {code}）")
            elif verdict == "invalid":
                print(f"[{name}] ⚠️ 变异体编译不过 —— 结论作废，不算被抓住")
                failures.append(f"{name}: 编译失败（无效变异）")
            else:
                print(f"[{name}] ❌ 未被抓住（守卫仍绿）")
                failures.append(f"{name}: 守卫没反应")
        finally:
            path.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
            restored = hashlib.sha256(path.read_bytes()).hexdigest()
            # 装置自证 ②：还原必须逐字节一致
            if restored != original_sha:
                print(f"[{name}] ⚠️ 还原后哈希不一致 —— 树上有残留！")
                failures.append(f"{name}: 还原不干净")

    print()
    print("=" * 72)
    if failures:
        print(f"❌ {len(failures)} 条未通过：")
        for item in failures:
            print(f"    - {item}")
        return 1
    print(f"✅ {len(MUTATIONS)} 条变异全部被抓住，且还原逐字节一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
