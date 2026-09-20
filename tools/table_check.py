#!/usr/bin/env python3
"""按 DocTableIntegrityTests 的两条轴，扫任意 Markdown 文件的表格结构。

用法：python3 tools/table_check.py <file> [<file> ...]
判据：① 每行「未转义」管道数 == 本块表头；② 表块中间不得被非表格行打断。
装置自证：把 blocks 打出来 —— 塌了就是口径失效，而不是「0 处缺陷」。

【为什么它进仓库，而不是留在 `.build/probe/`】
判据与 `DocTableIntegrityTests` **同一份**（两条轴），CI 里跑的是那个 Swift 守卫
（它扫 `git ls-files '*.md'`，当前 4 个文档）。本脚本存在的唯一理由是能扫**不被 git
跟踪**的文件 —— 最主要的就是 `.workbuddy-ai/memory/*.md`（被 `.gitignore` 排除，
CI 上根本不存在，那个守卫扫不到）。

⚠️ 2026-09-20：它原先放在 `.build/probe/round41/`，而 `DESIGN-SPEC.md` §8.104.5
把「要检查记忆目录就手工跑 …」写成了**活命令** —— 指向一个 gitignore、随时会被
`swift package clean` 抹掉的路径。这与 §8.107 那个「假 gh 放在 `.build/`」是**同一个病**：
**被反复引用的工具必须入库**，否则下一个人照文档去找只会拿到「文件不存在」，
与「这个工具从来没写过」逐字相同。
"""
import sys


def unescaped(s: str) -> int:
    n = 0
    prev = None
    for ch in s:
        if ch == "|" and prev != "\\":
            n += 1
        prev = ch
    return n


def strip_fences(lines):
    """剥掉围栏代码块，**保留行数**（行号才对得上）。"""
    out, in_fence = [], False
    for ln in lines:
        if ln.startswith("```"):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else ln)
    return out


def is_separator(s: str) -> bool:
    return set(s.replace("|", "").replace("-", "").replace(":", "").strip()) == set()


def scan(path: str):
    lines = strip_fences(open(path, encoding="utf-8").read().split("\n"))
    blocks, defects = 0, []
    i = 0
    while i < len(lines):
        if not lines[i].startswith("|"):
            i += 1
            continue
        start = i
        while i < len(lines) and lines[i].startswith("|"):
            i += 1
        end = i - 1
        blocks += 1
        # 轴②：表块中间被非空、非 `|` 行打断
        if (i < len(lines) and lines[i].strip() and not lines[i].startswith("|")
                and i + 1 < len(lines) and lines[i + 1].startswith("|")):
            defects.append((end + 2, "表被非表格行打断（续行会渲染成独立行，请用 <br>）"))
        if end <= start:
            continue
        want = unescaped(lines[start])
        for j in range(start + 1, end + 1):
            if is_separator(lines[j]):
                continue
            got = unescaped(lines[j])
            if got != want:
                defects.append((j + 1, f"未转义管道 {got} ≠ 表头 {want}（多出的单元格会被丢掉）"))
    return blocks, defects


if __name__ == "__main__":
    bad = 0
    for p in sys.argv[1:]:
        blocks, defects = scan(p)
        print(f"{p}\n  blocks={blocks}  defects={len(defects)}")
        for ln, what in defects:
            print(f"    L{ln}: {what}")
        if defects:
            bad = 1
    sys.exit(bad)
