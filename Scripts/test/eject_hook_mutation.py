#!/usr/bin/env python3
"""「接管访达的推出」判定层的**变异测试**（手动跑，不进 CI）。

## 为什么需要

本轮（2026-09-27）把「接管访达的推出」从 PoC 升级为正式功能，新增的判据**全是守装置**：
`EjectHookPolicy`（纯值判定层）、`ProcessTerminator`（同步清场器）、
`OccupancySnapshotStore`（跨线程只读快照）、`OccupancyStore.publish`（单一写入点）。

这四样东西有一个共同特征：**它们错了不会崩、不会报错，只会静默放行** ——
而「功能没生效」与「开关没打开」「去重生效」「hook 没注册」在真机上**逐字相同**。
所以每条判据都必须用变异证明：把行为改回旧的（错的）那一版，对应断言要变红。
没有这一步，它们与「没写」逐字相同 —— 因为「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

## 2026-09-28 追加：可用性闸门（M11–M16）

同一轮补的第二个洞：**没授「完全磁盘访问」时那个开关开着也什么都不做**。
闸门（``AppSettings/TakeOverAvailability``）把「用户偏好」与「此刻能不能生效」分开，
改动落在两处 —— 纯函数（推导）与设置行（渲染）。两处各要一条证据：

- **M11 / M12**：闸门恒真 / 恒假（推导两向）；
- **M13 / M14**：画出来的值忽略可用性 / 忽略用户意愿（渲染两向）；
- **M15 / M16**：**接线守卫** —— 把设置行写回「直接读用户偏好」。
  ⚠️ 这两条的过滤器是**扫源码**那条测试（`接管行三处都过闸门`）：
  纯函数全绿、只有它会红。这类「视图有没有真的用它」的缺陷，
  单测**结构上抓不到**（它测的是推导，不是接线）。

## 2026-09-29 转向后（拦截方案退役）

「拦截 + 弹窗 + 同步等用户」整体退役（DA approval 没有「静默取消」第三态，见
`Design/architecture/eject-takeover-pivot.md`）。随之删除的变异：

- **M4 / M6**（去重窗口边界 / resolve 的 cancel 分支）—— `EjectHookThrottle` 与
  `resolve()` 整体删除；
- **M17–M19**（用户决策窗口三连）—— `userDecisionTimeout` / `systemUnmountPatience`
  删除，「决策 + 清场必须落在系统等待上限内」这条不等式契约随同步等窗一起消失。

新增 **M20**：`EjectAttentionCenter.note` 的幂等性（字典键去重）—— Finder 重试
每 ~2.2s 触发一次回调，提醒若用数组追加会累积成堆，这是转向后「不骚扰」的关键守卫。
M3 / M5 改为守 `shouldNotify` 与提醒键的口径。

## 与架构文档 §6 的对应

架构文档列了 M1–M10 十条。**M2 在这里被拆成两条**，理由如下：

架构文档 M2 的字面描述是「把自排除判定的位置挪到占用缓存之后」。
但在 ``EjectHookPolicy.decide`` 这个纯函数里，**「自排除」与「占用判定」互换顺序
对所有入参产出完全相同的结论**（自排除为真时两条路都返回 `.passThrough(.selfInitiated)`）
⇒ 这条变异**不可观测、不可杀**，写进去只会得到一条永远「仍绿」的假结论。

「位置」这件事唯一可观测的形态是**跨过更早的那条 guard**：
把自排除挪到**开关之前**，`开关关优先于自排除` 立刻变红（原因码从 `takeOverDisabled`
变成 `selfInitiated`）。所以拆成：

- **M2a**「自排除失效」（删掉那条 guard）—— 抓「自排除存不存在」，由第 3 条测试抓；
- **M2b**「自排除挪到开关之前」—— 抓「自排除的位置」，由第 2 条测试抓。

## 用法

```bash
source Tools/clt_swift_env.sh        # 先让 swift 可用（Xcode 许可未接受时）
python3 Scripts/test/eject_hook_mutation.py
```

## 硬规则（沿用 `wait_outcome_mutation.py` / `test_timings_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件、打印那一行），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印我的判红结论 —— 判据自己也会错。
- 判红**先要「测试真的跑过」的正向证据**（`Test run with N tests` 且 N ≥ 1），**再看退出码**。
  ⚠️ **不许**用 `"error:" in raw` 判「编译不过」—— 见 ``classify`` 的说明。
  2026-09-28 实测翻过一次车：**扫源码型守卫**的失败操作数是被扫文件**整份字符串**
  （`#expect(source.contains(...))`），swift-testing 失败时把它整份回显，
  而文件里本来就有 `private func prompt(for error: LaunchAtLoginError)` ⇒
  M15 / M16 明明**真的跑起来并失败**，却被 `"error:" in raw` 判成「编译不过」而**不算通过**。
  **被扫的文件越大越容易撞上这个词**，所以这类守卫上这个判据是**系统性**失灵的。
  两种假红照样先排掉：**变异体编译不过**（没有那一行，但有 `:行:列: error:`）与
  **过滤器一条都没跑到**（有那一行且 N == 0）⇒ 由 ``classify`` 判成 `invalid`、**不算通过**。
- 还原之后 `cmp -s` 再确认一次；还原步骤**不挂在会失败的命令后面**（别用 `&&` 串）。
- **自带「未变异时全绿」自检**：先跑一遍基线（全部 suite 全跑），非绿即退出 ——
  否则「每条都被抓住」可能只是因为基线本来就是红的。
  ⚠️ 但**「退出码 0」不等于「基线跑了」**：`--filter` 一条都没匹配上时
  `swift test` 只打一行 `warning: No matching test cases were run` 就**返回 0**。
  2026-09-28 实测：`--filter` 认的是**类型标识符 / 测试函数名**，**不认 `@Suite("…")` 展示名**，
  而基线原本正是用展示名拼的 ⇒ 基线**一条都没跑**、还被旧 ``classify`` 判成 green。
  所以 ``baseline_is_green`` 现在是**三重自证**（绿 + 条数下限 + 每个展示名逐个核对）。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
POLICY = REPO / "Sources/Services/EjectHookPolicy.swift"
TERMINATOR = REPO / "Sources/Services/ProcessTerminator.swift"
SNAPSHOT = REPO / "Sources/Services/OccupancySnapshotStore.swift"
OCCUPANCY_STORE = REPO / "Sources/Services/OccupancyStore.swift"
APP_SETTINGS = REPO / "Sources/Settings/AppSettings.swift"
SETTINGS_VIEW = REPO / "Sources/Views/SettingsView.swift"
ATTENTION = REPO / "Sources/Services/EjectAttentionCenter.swift"

# 过滤器（swift-testing 的 `--filter` 认测试名正则）。
# ⚠️ 这些名字必须与 `EjectHookPolicyTests.swift` 里的 `@Test func` **逐字相同**：
# 对不上就会「一条都没跑到」，而它的退出码与「守卫没牙」**逐字相同**。
# 每个变异体用**最窄**的过滤器 —— 只跑「该抓住它的那一条」，证据才精确。
FILTER_SWITCH = "开关关时一律放行即使盘被占用|开关关优先于自排除"
FILTER_SELF = "自排除时放行且不读占用缓存"
FILTER_SWITCH_ORDER = "开关关优先于自排除"
FILTER_VAGUE = "占用不明确时放行"
FILTER_KEY = "明确列出占用进程时提醒并带上挂载路径"
FILTER_ATTENTION_DEDUP = "同键重复提醒是更新不是累积"
FILTER_SIGKILL = "忽略SIGTERM的进程被升级SIGKILL|无权终止时计入并升级SIGKILL"
FILTER_NOPATH = "没有挂载路径一律解析失败"
FILTER_UNKNOWN = "读不到时兜unknown而不是none"
FILTER_PARITY = "每轮之后快照与UI逐键相同"
# 可用性闸门（2026-09-28）：推导两向 + 画出来的值两向 + 接线（扫源码）。
FILTER_AVAIL_RESOLVE = "可用性只由沙盒与授权两个布尔决定"
FILTER_AVAIL_PAINT = "不可用时不许画成开"
FILTER_AVAIL_WANTS = "可用时等于用户意愿"
FILTER_AVAIL_WIRING = "接管行三处都过闸门"

# 「真的跑到了测试」的**正向证据**：swift-testing 无论成败都会打这一行（见 ``classify``）。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打这一行；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态（2026-09-28 实测补齐第二种）：
#   ① swiftc 诊断 —— `<file>:<行>:<列>: error: …`（有文件行号，好认）；
#   ② **构建期**错误 —— SwiftPM 自己报的，**没有文件行号**：
#      `error: The package product 'x-product' requires minimum platform version 14.0 …`
#      `error: Build failed` / `error: fatalError`。
#   ⚠️ 只写 ①（第一版就是这么写的）⇒ 平台版本冲突这类**构建期**失败认不出来，
#   会被错判成「过滤器一条都没跑到」（`DeploymentTargetTests` 的 M1 / M2 当场 NG）。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)

# 基线自检要核对的**七个 suite 展示名**（`@Suite("…")` 里的那个字符串）。
BASELINE_SUITES = (
    "接管访达推出的判定层",
    "待处理占用提醒",
    "同步清场器",
    "占用结论的跨线程只读快照",
    "占用结论的单一写入点",
    "接管访达推出的开关偏好",
    "接管访达推出的可用性闸门",
)

# 基线自检：**七个 suite 全跑**（不是某一条），否则「全绿」不代表装置整体是绿的。
#
# ⚠️ **必须写类型名，不能写 `@Suite("…")` 的展示名**：`--filter` 匹配的是
# **类型标识符与测试函数名**，展示名**不参与**匹配。2026-09-28 实测：
# 用展示名拼成的七路取名 ⇒ `warning: No matching test cases were run`，
# 基线**一条都没跑**；而「0 条测试 + 退出码 0」被旧 ``classify`` 判成 green
# ⇒ 整个基线自检是**空转**（比「基线红」更坏：它看起来是绿的）。
# 展示名不改丢：单独拿来核对「每个 suite 是不是都真的跑到了」（见 ``baseline_is_green``）。
FILTER_BASELINE = (
    "EjectHookPolicyTests|EjectAttentionCenterTests|ProcessTerminatorTests"
    "|OccupancySnapshotStoreTests|OccupancyStoreSnapshotParityTests"
    "|TakeOverFinderEjectPreferenceTests|TakeOverAvailabilityTests"
)
# 基线里**至少**要跑到多少条测试。防的是「过滤器只匹配上一部分」这种半空转 ——
# ``classify`` 只拦得住 N == 0。
BASELINE_MIN_TESTS = 28

# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "删掉 `isTakeOverEnabled` 分支（开关关也会去拦盘 —— 正是「默认关」要防的事）",
        POLICY,
        "        guard isTakeOverEnabled else { return .passThrough(.takeOverDisabled) }\n",
        "        // M1 变异：开关分支已删除\n",
        FILTER_SWITCH,
    ),
    (
        "M2a",
        "自排除**失效**（删掉那条 guard）⇒ 自己拦自己 ⇒ 永久推不出",
        POLICY,
        "        guard !isSelfInitiated else { return .passThrough(.selfInitiated) }\n",
        "        // M2a 变异：自排除已删除\n",
        FILTER_SELF,
    ),
    (
        "M2b",
        "自排除**挪到开关之前**（位置错）⇒ 开关关时原因码变成 `selfInitiated`，"
        "日志里就出现了「我们在链路上」的证据",
        POLICY,
        "        guard isTakeOverEnabled else { return .passThrough(.takeOverDisabled) }\n"
        "        guard !isSelfInitiated else { return .passThrough(.selfInitiated) }\n",
        "        guard !isSelfInitiated else { return .passThrough(.selfInitiated) }\n"
        "        guard isTakeOverEnabled else { return .passThrough(.takeOverDisabled) }\n",
        FILTER_SWITCH_ORDER,
    ),
    (
        "M3",
        "`shouldNotify` 去掉 `!processes.isEmpty` ⇒ `.occupied([])` 会提醒一个**空列表**"
        "（系统说忙但列不出具体程序，弹空提醒毫无意义）",
        POLICY,
        "        guard case .occupied(let processes) = occupancy, !processes.isEmpty else { return nil }",
        "        guard case .occupied(let processes) = occupancy else { return nil }",
        FILTER_VAGUE,
    ),
    (
        "M5",
        "提醒的键从 `mountPath` 换成 `volumeName` ⇒ 两块**同名盘**的提醒互相覆盖"
        "（A 盘的提醒被同名的 B 盘顶掉）",
        POLICY,
        "        let disk = DiskInfo(\n            id: request.mountPath,",
        "        let disk = DiskInfo(\n            id: request.volumeName,",
        FILTER_KEY,
    ),
    (
        "M20",
        "`EjectAttentionCenter.note` 用数组追加而不是字典键覆盖 ⇒ Finder 重试会**累积**"
        "一堆重复提醒（每 2.2s 一条），这正是转向后要去掉的「反复骚扰」",
        ATTENTION,
        "        pending[disk.mountPath] = EjectAttention(disk: disk, processes: processes, notedAt: date)",
        "        pending[UUID().uuidString] = EjectAttention(disk: disk, processes: processes, notedAt: date)",
        FILTER_ATTENTION_DEDUP,
    ),
    (
        "M7",
        "`clear` 去掉 `SIGKILL` 那一步 ⇒ 忽略 `SIGTERM` 的进程还活着 ⇒ 访达拿到 `fBsyErr`"
        "并弹**它自己的报错框**（本功能最大的价值点当场失效）",
        TERMINATOR,
        "            _ = signal(escalated, signal: SIGKILL, selfPid: selfPid, kill: kill)",
        "            _ = escalated  // M7 变异：不再升级 SIGKILL",
        FILTER_SIGKILL,
    ),
    (
        "M8",
        "`EjectHookRequest.make` 去掉挂载路径判空 ⇒「整个盘」的 eject 回调"
        "（访达推出的**第二阶段**）会被当成一块盘走进判定与去重 ⇒ 推出被打断",
        POLICY,
        '        let mountPath = (description[DescriptionKey.volumePath] as? URL)?.path ?? ""\n'
        "        guard !mountPath.isEmpty else { return nil }\n",
        '        let mountPath = (description[DescriptionKey.volumePath] as? URL)?.path ?? ""\n'
        "        // M8 变异：挂载路径判空已删除\n",
        FILTER_NOPATH,
    ),
    (
        "M9",
        "`occupancy(for:)` 的兜底从 `.unknown` 改成 `.none`"
        "（**把「还没测出来」当成「确认没占用」** —— 本应用最不能犯的错）",
        SNAPSHOT,
        "        return values[mountPath] ?? .unknown",
        "        return values[mountPath] ?? .none",
        FILTER_UNKNOWN,
    ),
    (
        "M10",
        "`OccupancyStore.publish(_:)` 只写 `results`、不写快照 ⇒ UI 与快照**分叉**"
        "（界面说有占用、DA 回调读到的是没占用）",
        OCCUPANCY_STORE,
        "        results = next\n        OccupancySnapshotStore.update(next)",
        "        results = next\n        // M10 变异：不再写快照",
        FILTER_PARITY,
    ),
    (
        "M11",
        "可用性闸门**恒判可用** ⇒ 没授完全磁盘访问的人照样能把开关打开，"
        "而那条链路永远走不到弹窗（**这正是本闸门要防的那件事**）",
        APP_SETTINGS,
        "            (isSandboxed || isFullDiskAccessAuthorized) ? .usable : .needsFullDiskAccess",
        "            .usable",
        FILTER_AVAIL_RESOLVE,
    ),
    (
        "M12",
        "可用性闸门**恒判不可用** ⇒ 已授权的人也被要求去授权，"
        "那个开关永远拨不动（把一条正常路径锁死）",
        APP_SETTINGS,
        "            (isSandboxed || isFullDiskAccessAuthorized) ? .usable : .needsFullDiskAccess",
        "            .needsFullDiskAccess",
        FILTER_AVAIL_RESOLVE,
    ),
    (
        "M13",
        "`effectiveIsOn` 忽略可用性（退回「用户偏好直接当画出来的值」）"
        "⇒ 未授权时开关画成「开」，而它什么都不会做 —— 界面在撒谎",
        APP_SETTINGS,
        "            userWants && availability.isUsable",
        "            userWants",
        FILTER_AVAIL_PAINT,
    ),
    (
        "M14",
        "`effectiveIsOn` 忽略用户意愿（**恒关**）⇒ 用户开了也画成关，"
        "而且他还拨不动（`onTap` 只由可用性决定）",
        APP_SETTINGS,
        "            userWants && availability.isUsable",
        "            availability.isUsable && false",
        FILTER_AVAIL_WANTS,
    ),
    (
        "M15",
        "接管那一行的 `onTap` 绕过闸门（写回直传 `toggleTakeOverFinderEject`）"
        "⇒ 未授权时整行又能点了，用户点下去「有反应但不会生效」"
        "（⚠️ 这条是**接线守卫**：纯函数全绿，只有扫源码那条会红）",
        SETTINGS_VIEW,
        "                        onTap: takeOverTapAction,",
        "                        onTap: toggleTakeOverFinderEject,",
        FILTER_AVAIL_WIRING,
    ),
    (
        "M16",
        "接管的无障碍值读回用户偏好而不是生效值 ⇒ 看不见的用户听到「开」，"
        "而它并没有生效（看得见的人至少能看出开关是关的）",
        SETTINGS_VIEW,
        "                        accessibilityValue: L10n.tr(takeOverOn ? .on : .off)",
        "                        accessibilityValue: L10n.tr(takeOverFinderEject ? .on : .off)",
        FILTER_AVAIL_WIRING,
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

    ## 为什么不能判 `"error:" in raw`

    2026-09-28 实测翻过一次车（M15 / M16）。**扫源码型守卫**的失败操作数是
    被扫文件**整份内容**（`#expect(source.contains("onTap: takeOverTapAction"))`），
    swift-testing 一失败就把这个字符串**整份回显**，而 `SettingsView.swift` 里本来就有
    ``private func prompt(for error: LaunchAtLoginError)`` 这一行 ⇒ `"error:" in raw` 为真。
    于是两条**真的跑起来并失败**的变异体（退出码 1、`Test run with 1 test ... failed`
    各 2 个 / 1 个 issue）被判成「变异体编译不过」而**不算通过**。
    这不是偶然：**被扫的文件越大，越可能撞上 `error:` 这个词** —— 对这类守卫是系统性误判。

    ## 改用的口径：要判红，先拿出「测试真的跑过」的正向证据

    - **编译不过** ⇒ 构建阶段就挂了，**不会有** `Test run with N tests` 这一行；
    - **过滤器没跑到** ⇒ 有那一行，但 N == 0（**或压根没有那一行**，
      形态是 `warning: No matching test cases were run`，而且 **`swift test` 返回 0** ——
      ⚠️ 这一种光看退出码会读成**绿**，比「假红」更坏）；
    - **被抓住（red）** ⇒ 有那一行且 N ≥ 1，同时退出码非 0。

    这比「只看退出码」更严：退出码非 0、却没真跑到测试的运行，一律 `invalid`。

    ## 「编译不过」怎么与「过滤器没跑到」分开

    跑到 0 条时，两种可能各看一个信号：

    - **构建成没成**：`Build complete!` 在不在（正向证据，SwiftPM 每次构建都打）。
      不在 ⇒ 构建失败 ⇒ 编译不过；
    - **编译诊断**：swiftc 的 `:行:列: error:`，或构建期无行号的 `error: Build failed`。
      有 ⇒ 编译不过。

    ⚠️ 判据是**两个正向信号取或**，不是「输出里有没有 `error:`」——
    后者正是本节开头那个把「被抓住」误判成「编译不过」的来源。
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

    ⚠️ 光看「退出码 0」不够：**跑 0 条测试也返回 0**（见 ``FILTER_BASELINE`` 的说明）。
    所以这里三重自证：
    ① ``classify`` 判 green（跑到 ≥ 1 条且退出码 0）；
    ② 真的跑到 ≥ ``BASELINE_MIN_TESTS`` 条（拦「只匹配上一部分」）；
    ③ 每个 suite 的**展示名**逐个出现在输出里（拦「某个 suite 悄悄没跑」）。
    """
    print(f"===== 基线自检（未变异，{len(BASELINE_SUITES)} 个 suite 全跑）=====")
    code, raw = run_tests(FILTER_BASELINE)
    verdict = classify(code, raw)
    tail = "\n".join(raw.splitlines()[-6:])
    print(f"退出码 {code}，判定 {verdict}")
    print("原始尾部：")
    print(tail)
    if verdict != "green":
        print("⚠️ 基线不是绿的 —— 先修基线，再来谈变异。")
        return False

    run = TEST_RUN_RE.search(raw)
    count = int(run.group(1))
    missing = [name for name in BASELINE_SUITES if f'Suite "{name}"' not in raw]
    print(f"基线跑到 {count} 条测试；{len(BASELINE_SUITES)} 个 suite 展示名核对：" + ("全在" if not missing else "缺 " + "、".join(missing)))
    if count < BASELINE_MIN_TESTS:
        print(f"⚠️ 基线只跑到 {count} 条（< {BASELINE_MIN_TESTS}）—— 过滤器少匹配了，结论作废。")
        return False
    if missing:
        print("⚠️ 有 suite 没跑到 —— 基线覆盖不完整，结论作废。")
        return False
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
            # 装置自证 ①：变异真的写进去了（回读，不信写入返回）
            landed = new in path.read_text(encoding="utf-8")
            print(f"\n[{name}] {why}")
            print(f"[{name}] 变异落地：{landed}（{path.name}）")
            print(f"[{name}] 过滤器：{filter_expr}")
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
