#!/usr/bin/env python3
"""审计「变异脚本跑完之后，树里有没有残留变异体」。

## 为什么需要

变异脚本的还原步骤**自己会失败**（进程被 kill、`finally` 里那条 `cp` 没跑到、
备份被并发污染……），而失败之后**没有任何症状**：
下一次 `swift test` 大概率还是绿的（变异体往往就是「旧的那一版正确代码」，
它自洽、能编译、也说得通），于是**你会在被改过的树上继续干活**。
2026-09-25 实测过一次：两路装置并发跑，备份互相污染（技能 K21）。

## 判据：判「是不是**正确形态**」，别判「变异形态在不在」

- ❌ 第一版判据：`new`（变异形态）在文件里出现过 ⇒ 判「有残留」。
  **误报 6 / 31 条**：`new` 常常是 `old` 的**子串**；别处本来就有同样的合法代码。
- ✅ 现行判据：用**变异脚本自己的前提** —— 锚点 `old` 必须**恰好命中 1 次**。
  - 命中 1 次 = 当前就是正确形态（顺带证明下一次变异能成功施加）；
  - 命中 0 次 = 锚点**不在了**；⚠️ **两种原因要分开**：① 有残留（被改成 `new` 了）；
    ② **源码被合法改过**（技能 K16：改了实现 ⇒ 旧变异里逐字抄着的源码文本会失效）。
    判据本身分不出这两种，**都得人工看** —— 别把「合法改动」直接读成「有残留」；
  - 命中 >1 次 = 锚点不唯一，需要人工看。

这个判据**不依赖备份**，所以 K21 那种「备份自己被骗了」的情况它照样抓得到。

## 用法

    python3 Scripts/test/mutation_residue_audit.py        # 退出码 0 = 无残留

## 实现说明

- **import 目标脚本取 `MUTATIONS`，不用正则去抠**（K23：正则抠多行字面量会灾难性回溯，
  实测跑 2m43s 无输出，看着像「慢」，其实判据死了）。
- 目标脚本都有 `if __name__ == "__main__"` 守卫，import 期不会跑变异。
- 本仓库各脚本的条目有**两种形态**，这里都认（见 ``anchor_hits``）：
  - `(name, edits, expect)`，`edits = [(path, old, new), …]`（`deployment_target_mutation.py`）；
  - `(name, why, path, old, new, filter)`，其中 `old is None` 表示「用模块级 `ANCHOR`」
    （`pixel_read_path_mutation.py`）。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "Scripts/test"

SCRIPTS_TO_AUDIT = (
    "eject_hook_mutation",
    "deployment_target_mutation",
    "pixel_read_path_mutation",
    "integration_wait_mutation",
    "wait_outcome_mutation",
    # 2026-09-28：启动即检查 + 「检查失败」不再冒充「已是最新」那一轮。
    "update_check_mutation",
    # 2026-09-29：两栏设置面板的左栏 ↑/↓ 分类导航那一轮。
    "settings_section_nav_mutation",
    # 2026-09-29：登录项「等待系统批准」的受阻提示行那一轮（§8.153 工程侧实现）。
    # ⚠️ 它的五条变异**都不改布局、只改颜色或条件** ⇒ 高度一字不差，
    # 全靠 `SettingsLayoutTests` 里那两条**像素判据**抓 —— 所以这份审计对它尤其重要。
    "settings_warn_row_mutation",
)


def load_module(name: str):
    """按路径加载变异脚本（**不是** `import`，它们不在包路径里）。"""
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    if spec is None or spec.loader is None:
        raise RuntimeError(f"加载不了 {name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def anchor_hits(module) -> list[tuple[str, Path, str, int]]:
    """把两种条目形态都摊平成 `(变异名, 文件, 锚点, 命中次数)`。"""
    anchor = getattr(module, "ANCHOR", None)
    out: list[tuple[str, Path, str, int]] = []
    for entry in module.MUTATIONS:
        name = entry[0]
        # 形态一：edits 是一串 (path, old, new)
        if isinstance(entry[1], list):
            for path, old, _new in entry[1]:
                path = Path(path)
                if not path.exists():
                    out.append((name, path, old, -1))  # -1 = 文件不存在
                    continue
                out.append((name, path, old, read(path).count(old)))
            continue
        # 形态二：(name, why, path, old, new, filter)
        path, old = Path(entry[2]), entry[3]
        if old is None:
            old = anchor
        if old is None:
            continue
        if not path.exists():
            out.append((name, path, old, -1))  # -1 = 文件不存在
            continue
        out.append((name, path, old, read(path).count(old)))
    return out


def main() -> int:
    failures: list[str] = []
    for name in SCRIPTS_TO_AUDIT:
        try:
            module = load_module(name)
        except Exception as exc:  # noqa: BLE001 —— 载入失败也是「这条结论作废」
            print(f"{name:32s} ⚠️ 载入失败：{exc} —— 结论作废")
            failures.append(f"{name}: 载入失败")
            continue

        hits = anchor_hits(module)
        bad = [(n, p.name, h) for (n, p, _a, h) in hits if h != 1]
        total = len(hits)
        if not bad:
            print(f"{name:32s} 锚点 {total} 条 → 全部恰好命中 1 次 ✅（无残留）")
            continue
        print(f"{name:32s} 锚点 {total} 条 → ⚠️ {len(bad)} 条异常：")
        for n, f, h in bad:
            meaning = (
                "锚点不在了 —— 可能是有残留，也可能是这段源码被合法改过（K16），需人工看"
                if h == 0 else (
                    f"锚点不唯一（命中 {h} 次），需人工看" if h > 1 else "文件不存在"))
            print(f"    [{n[:16]}] {f} 命中 {h} 次 —— {meaning}")
        failures.append(f"{name}: {len(bad)} 条锚点形态异常")

    print()
    if failures:
        print("===== 审计未通过 =====")
        for item in failures:
            print(f"  - {item}")
        print("⚠️ 树上可能有残留变异体：先按上表核对，再决定是否 `cp` 还原；"
              "**不要**用 `git checkout`（会连未提交的改动一起清掉）。")
        return 1
    # ⚠️ 条数**不写死**：写死的那一刻起它就成了一句会过期的断言
    # （加第 7 个脚本时很容易忘了改，而审计照样报「通过」）。
    print(f"===== 审计通过：{len(SCRIPTS_TO_AUDIT)} 个变异脚本的锚点全部是正确形态 =====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
