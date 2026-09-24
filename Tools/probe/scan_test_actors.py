#!/usr/bin/env python3
"""扫 Tests/ 里**每一个 test** 的 actor 隔离：哪些不在 main actor 上、它们碰了什么。

## 为什么要改到「逐 test」这一层（v1 的缺陷）

v1 只看 `@Suite` 声明附近有没有 `@MainActor`，结果把 `VisualStyleTests` 报成可疑
—— 但它的**每个 `@Test` 都带 `@MainActor`**（suite 级没有）。
⇒ **suite 级没标 ≠ 不安全**。按 suite 判会误报，而误报比漏报更耗人：
每一条都得人工复核一遍。

v2 的判据：**effective main-actor = suite 有 **或** test 自己有**。
并且只看 **test 函数体内**的共享状态访问（不看注释、不看源码文本断言里的字符串）。

## 另一个要避开的误报

`UpdateSettingsTests` 里有大量 `"UpdateController.shared.startIfNeeded()"` 这类
**源码文本断言**（断言的是字符串，不是真的调用单例）。
v2 会把命中行打印出来让人分辨，并且跳过以 `//` 开头的注释行。

## 装置自证

① 打印文件数 / suite 数 / test 数 —— 为 0 就是扫错了，不是「没有」；
② 打印隔离状态的**分布**（含安全的那批），让「N 个非 main-actor」有参照；
③ 每条命中带**文件名 + 行号 + 原文**，便于人工复核（脚本不自证结论）。
"""

import os
import re
import sys

# ⚠️ **从脚本位置派生，不写死绝对路径** —— 入库后要能在任何一台机器上跑
# （原先写的是 `/Users/wenbo/MyCode/...`，换台机器就扫了个不存在的目录，
#   而 `os.walk` 对不存在的目录**不报错**、只是什么都不返回 ⇒ 症状与「0 候选」逐字相同）。
ROOT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "Tests",
)

SHARED = [
    ("NSApplication.shared", r"NSApplication\.shared"),
    ("NSApp", r"\bNSApp\b"),
    ("UserDefaults 写", r"UserDefaults[.\w]*\.(?:set|removeObject)\b"),
    (".shared 单例", r"\b[A-Z]\w*\.shared\b"),
    ("静态 var", r"\bstatic\s+var\s"),
    ("DispatchQueue.main", r"DispatchQueue\.main"),
]


def is_code(line):
    """排除注释行 —— ⚠️ 否则**注释里提到的 `@MainActor` 会被当成真标注**。

    实测：探针文件的注释里写着「② `@MainActor` + 碰共享状态 ⇒ 脚本必须不报它」，
    而容器判定的上下文窗口正好把那句注释圈了进去 ⇒ 整个 suite 被误判成 main-actor
    ⇒ **漏报**。共享状态那一步早就跳过注释行了，标注这步却漏了 —— 同一次扫描里
    两种口径不一致，是最难发现的那类 bug。
    """
    s = line.strip()
    return not (s.startswith("//") or s.startswith("///") or s.startswith("*"))


def find_containers(lines):
    """返回 [(行号1based, 名字, 容器级是否 main-actor)]。

    ⚠️ v2 的缺陷：只认 `@Suite`，于是**漏掉了「`@MainActor struct X` 但没有 `@Suite`」**
    这一大批（`IntegrationEjectTests` 就是这样被误报成非 main-actor 的）。
    本项目的测试文件大量采用这种写法 ⇒ v2 报出「418 个 test 里 389 个非 main-actor」，
    比例高到不合理 —— **分布本身就是装置坏了的自证信号**。
    v3 改为按「最近的容器声明」判定，不管它有没有 `@Suite`。
    """
    out = []
    for i, line in enumerate(lines, start=1):
        # ⚠️ 只认**顶层**容器（行首无缩进）：嵌套的辅助 struct 若被当成容器，
        #    会让它后面的 test 认错父级 —— 又是一次误报。
        if re.search(r"@Suite\b", line) or re.match(
            r"(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
            r"(?:final\s+)?(?:struct|class|enum|extension)\s+\w+", line
        ):
            # 容器声明前 3 行内的标注都算容器级
            ctx = "\n".join(l if is_code(l) else "" for l in lines[max(0, i - 4): i + 1])
            m = re.search(r"(?:struct|class|enum|extension)\s+(\w+)", line)
            out.append((i, m.group(1) if m else "?", "@MainActor" in ctx))
    return out


def find_tests(lines):
    """返回 [(行号1based, 名字, test级是否 main-actor, 收集到的属性行)]。

    ⚠️ v3 的缺陷：只看 `@Test` **之后**的行，而本项目大量写成
        ```
        @MainActor
        @Test func xxx() {
        ```
    即 `@MainActor` 在 `@Test` **之前** ⇒ 一批 test 被误判成非 main-actor
    （`UpdateSettingsTests` 的 8 条就是这样冒出来的）。
    v4：**往下 + 往上**都收集紧邻的属性行。
    """
    out = []
    for i, line in enumerate(lines, start=1):
        if re.search(r"@Test\b", line):
            attrs = [lines[i - 1]]
            # 往上：连续的 @ 开头行
            j = i - 2
            while j >= 0 and lines[j].strip().startswith("@") and is_code(lines[j]):
                attrs.append(lines[j])
                j -= 1
            # 往下：@Test 与 func 之间可能还夹别的属性（如 @Test("名字") @MainActor）
            k = i
            while k < len(lines) and lines[k].strip().startswith("@") and is_code(lines[k]) and not re.search(
                r"@Test\b", lines[k]
            ):
                attrs.append(lines[k])
                k += 1
            m = re.search(r"\bfunc\s+([\w\u4e00-\u9fff]+)\s*\(", "\n".join(lines[i - 1: i + 5]))
            out.append((i, m.group(1) if m else "?", "@MainActor" in "\n".join(attrs), attrs))
    return out


def body_range(lines, start_idx):
    """从 test 声明行开始，到下一个 @Test / @Suite / 顶层声明为止。"""
    for j in range(start_idx + 1, len(lines)):
        s = lines[j]
        if re.match(r"\s*@", s) or re.match(r"^\s*(?:private\s+|public\s+)?func\s", s):
            return start_idx + 1, j
    return start_idx + 1, len(lines)


def main() -> int:
    files = []
    for dirpath, _dirs, names in os.walk(ROOT):
        for n in names:
            if n.endswith(".swift"):
                files.append(os.path.join(dirpath, n))
    files.sort()

    n_suites = n_tests = n_nonmain = 0
    risky = []

    for path in files:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        suites = find_containers(lines)
        tests = find_tests(lines)
        n_suites += sum(1 for i, _n, _m in suites if "@Suite" in lines[i - 1])
        n_tests += len(tests)
        if not tests:
            continue

        for ln, tname, t_main, attrs in tests:
            # 找它所在的容器：取它之前最近的那个容器声明（不论有没有 @Suite）
            owner = None
            for sl, sname, s_main in suites:
                if sl < ln:
                    owner = (sname, s_main)
            container_main = owner[1] if owner else False
            effective_main = container_main or t_main
            if effective_main:
                continue
            n_nonmain += 1

            a, b = body_range(lines, ln - 1)
            body = lines[a:b]
            found = []
            for off, raw in enumerate(body, start=a + 1):
                stripped = raw.strip()
                if stripped.startswith("//") or stripped.startswith("///"):
                    continue
                for label, pat in SHARED:
                    if re.search(pat, raw):
                        found.append((off, label, stripped))
            if found:
                risky.append((os.path.relpath(path, ROOT), ln, tname, owner[0] if owner else "?", found))

    # ① ② 自证
    print(f"扫到 {len(files)} 个文件、{n_suites} 个 @Suite、{n_tests} 个 @Test")
    if n_tests == 0:
        print("SELFCHECK-FAIL：一个 test 都没扫到 ⇒ 正则错了，本次扫描作废")
        return 3
    print(f"  **非** main-actor 的 test：{n_nonmain} 个（其余 {n_tests - n_nonmain} 个在 main actor 上）")

    print("\n=== 非 main-actor **且函数体内**碰共享状态的 test（真候选）===")
    if not risky:
        print("  （无 —— 所有非 main-actor 的 test 函数体内都没有共享状态访问）")
    for rel, ln, tname, sname, found in risky:
        print(f"  ⚠️ {rel}:{ln} 【{sname}】{tname} —— {len(found)} 处：")
        for off, label, raw in found[:6]:
            print(f"      :{off} [{label}] {raw[:110]}")
        if len(found) > 6:
            print(f"      … 还有 {len(found) - 6} 处")

    print(f"\n=== 小结：真候选 {len(risky)} 条（非 main-actor {n_nonmain} 个里）===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
