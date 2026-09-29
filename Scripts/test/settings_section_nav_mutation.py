#!/usr/bin/env python3
"""``SettingsSectionNavigationTests`` 守卫的**变异测试**（手动跑，不进 CI）。

## 为什么需要

两栏设置面板的左栏支持 ↑/↓ 在分类间移动（设计稿 09 页 §8.152.5）。
那条功能的**接线**（`.focusable()` + `.onMoveCommand`）在 `swift test` 里跑不到 ——
没有窗口、也没有可信的方向键注入（合成 `NSEvent` 会被 SwiftUI 的字段校验丢掉）。
所以守卫被拆成两半：**算术**靠纯函数断言，**接线**靠扫源码断言。
两半都得证明有牙，否则「7 条全绿」只是一句好听的话。

## 六条变异覆盖的是哪六类失败

| 类型 | 典型写法 | 为什么危险 |
|---|---|---|
| 回绕 | `% all.count` | 不崩了，但「按住 ↑ 到顶」会跳回最后一项 |
| 夹少一格 | `all.count - 2` | 极容易写错一格的 off-by-one |
| 符号写反 | `index - step` | 方向整体反了，看起来「能跑」 |
| 越界兜到第一项 | `… : 0]` | 看似「保守修法」，语义完全错 |
| 视图里方向反了 | `.up` 配 `step: +1` | **算术全绿也拦不住** —— 只有扫源码能抓 |
| 枚举顺序改了 | 声明对调 | 左栏顺序变了，而走查图不进 CI |

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/settings_section_nav_mutation.py
```

## 硬规则（沿用 `wait_outcome_mutation.py` / `pixel_read_path_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
- ⚠️ **判红之前先排除「变异体编译不过」与「过滤器一条都没跑到」**：
  这两种情况下退出码同样非 0，与「被守卫抓住」**逐字相同** ⇒ 判为结论作废，不算通过。
- ⚠️ **六条变异体都必须「跑得起来但答错」，不许是「崩掉」**：
  下标越界崩溃会让进程在半途死掉，**打不出** `Test run with N tests` 那一行，
  于是 `classify` 只能判 `invalid` —— 证据白丢。所以夹取类变异一律**改成另一种
  非崩溃的错误语义**（回绕 / 夹少一格 / 符号反 / 兜到底），而不是简单删掉夹取。
- 还原之后回读比对；还原步骤**不挂在会失败的命令后面**（不用 `&&` 串）。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SETTINGS_VIEW = REPO / "Sources/Views/SettingsView.swift"

# swift-testing 的 `--filter` 认**类型名 / 函数名**，不认 `@Suite` 展示名。
FILTER = "SettingsSectionNavigationTests"

# 夹取表达式 —— M1~M4 共用这一个锚点（每次只挑一条施加）。
CLAMP = "all[min(max(index + step, 0), all.count - 1)]"

# 基线要核对的**七条**测试函数名（本 suite 无 `@Suite` 展示名，但核对仍走归一化）。
BASELINE_TESTS = (
    "分类的声明顺序就是左栏显示顺序",
    "向下逐项走到关于",
    "向上逐项走回通用",
    "在两端夹住而不回绕",
    "一次跨多格越界也夹在两端",
    "步长为零时每一项都不动",
    "上键步长为负一下键步长为正一",
)
BASELINE_MIN_TESTS = 7

# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "越界时**回绕**（`% all.count`）—— 不崩了，但「按住 ↑ 到顶」会跳回最后一项",
        SETTINGS_VIEW,
        CLAMP,
        "all[((index + step) % all.count + all.count) % all.count]",
        FILTER,
    ),
    (
        "M2",
        "上端**夹少一格**（`all.count - 2`）—— 就在边界上的 off-by-one",
        SETTINGS_VIEW,
        CLAMP,
        "all[min(max(index + step, 0), all.count - 2)]",
        FILTER,
    ),
    (
        "M3",
        "夹取里的加号写成减号（`index - step`）—— 方向整体反了，而函数仍然「能跑」",
        SETTINGS_VIEW,
        CLAMP,
        "all[min(max(index - step, 0), all.count - 1)]",
        FILTER,
    ),
    (
        "M4",
        "越界时**兜到第一项**（`… : 0]`）—— 看着像「保守修法」，而 `.about` 按 ↓ 会变成 `.general`",
        SETTINGS_VIEW,
        CLAMP,
        "all[(index + step >= 0 && index + step < all.count) ? index + step : 0]",
        FILTER,
    ),
    (
        "M5",
        "**视图里** ↑ 配 `step: +1`（方向键反向）—— 算术一条都不变，只有扫源码那条能抓",
        SETTINGS_VIEW,
        "case .up: selection = SettingsSection.moved(from: selection, step: -1)",
        "case .up: selection = SettingsSection.moved(from: selection, step: 1)",
        FILTER,
    ),
    (
        "M6",
        "枚举里 `.about` 与 `.diagnostics` 声明对调（左栏顺序变了，而走查图不进 CI）",
        SETTINGS_VIEW,
        "    case diagnostics\n    case about\n",
        "    case about\n    case diagnostics\n",
        FILTER,
    ),
]

# 「测试真的跑过」的**正向证据**：swift-testing 无论成败都会打这一行。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打这一行；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态（见 `deployment_target_mutation.py` 的 M1/M2）：
# swiftc 的 `<file>:<行>:<列>: error:`，与**构建期**无文件行号的 `error: Build failed`。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)


def _normalize_name(s: str) -> str:
    """把测试名归一化：去掉引号 / 书名号 / 括号 / 空白（函数名与显示名常不同形）。"""
    return re.sub(r"[\s「」『』\"'“”（）()\[\]{}]", "", s)


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
    """把一次运行判成 `red` / `green` / `invalid`。

    ⚠️ **不许**写成 `"error:" in raw`：扫源码型守卫（本文件 M5 就是）失败时
    swift-testing 会把 `#expect` 的操作数**整份回显**，而 `SettingsView.swift` 里
    有 `error:` 字样（`prompt(for error: LaunchAtLoginError)`）
    ⇒ **真的跑起来并失败**的变异被判成 `invalid`、**不算通过**（2026-09-28 实测）。

    现行口径 = **正向证据**：`Test run with N tests` 且 `N ≥ 1` 才配谈红；
    一条都没跑到时，按「构建成没成」+ 编译诊断把两类 `invalid` 分开。
    """
    run = TEST_RUN_RE.search(raw)
    if run is not None and int(run.group(1)) >= 1:
        # 真的跑到测试了 —— 这时候退出码说了算。
        return "green" if code == 0 else "red"
    # 一条都没跑到：要么构建就没过，要么过滤器一条都没匹配上。
    if COMPILE_DIAG_RE.search(raw) or not BUILD_OK_RE.search(raw):
        return "invalid（变异体编译不过）"
    return "invalid（过滤器一条都没跑到）"


def baseline_is_green() -> bool:
    """先证明**未变异时装置是绿的** —— 否则后面「每条都被抓住」毫无意义。

    ⚠️ 光看「退出码 0」不够：**跑 0 条测试也返回 0**（见 ``classify`` 的说明）。
    所以这里三重自证：① ``classify`` 判 green；② 跑到 ≥ ``BASELINE_MIN_TESTS`` 条；
    ③ 七条测试函数名逐个出现在输出里。
    """
    print("===== 基线自检（未变异，七条测试全跑）=====")
    code, raw = run_tests(FILTER)
    verdict = classify(code, raw)
    print(f"退出码 {code}，判定 {verdict}")
    print("原始尾部：")
    print("\n".join(raw.splitlines()[-6:]))
    if verdict != "green":
        print("⚠️ 基线不是绿的 —— 先修基线，再来谈变异。")
        return False

    run = TEST_RUN_RE.search(raw)
    count = int(run.group(1))
    haystack = _normalize_name(raw)
    missing = [name for name in BASELINE_TESTS if _normalize_name(name) not in haystack]
    print(
        f"基线跑到 {count} 条测试；七条测试名核对：" + ("全在" if not missing else "缺 " + "、".join(missing))
    )
    if count < BASELINE_MIN_TESTS:
        print(f"⚠️ 基线只跑到 {count} 条（< {BASELINE_MIN_TESTS}）—— 过滤器少匹配了，结论作废。")
        return False
    if missing:
        print("⚠️ 有测试名没跑到 —— 基线覆盖不完整，结论作废。")
        return False
    return True


def main() -> int:
    if not baseline_is_green():
        return 1

    failures: list[str] = []
    for name, why, path, old, new, filter_expr in MUTATIONS:
        original = path.read_text(encoding="utf-8")
        if original.count(old) != 1:
            print(f"[{name}] ⚠️ 目标片段在 {path.name} 里出现 {original.count(old)} 次 —— 结论作废")
            failures.append(f"{name}: 片段不唯一")
            continue

        backup = Path(tempfile.mkdtemp(prefix="mut-setnav-")) / path.name
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

            code, raw = run_tests(filter_expr)
            verdict = classify(code, raw)
            # 装置自证 ②：打印**原始输出**里的 ✘ 与汇总行，不只打印我的判红结论
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
            # ⚠️ 还原**单独一条**，不挂在可能失败的语句后面；还原后再比对
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
