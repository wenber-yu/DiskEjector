#!/usr/bin/env python3
"""更新检查守卫的**变异测试**（手动跑，不进门槛）。

## 为什么需要

2026-09-28 用户报告：从 /Applications 重新打开应用（14:46），设置行显示
「上次检查：今天 10:03 · 已是最新版本」，而 13:22 已发布的新版本就在 appcast 里。
查下来是**两个独立的缺陷**，各自都只能用「改回旧行为、断言必须变红」来证明守卫有牙：

1. **启动路径从不发起检查** —— `startIfNeeded()` 只 `ensureUpdater()`，
   排期全交给 Sparkle；而 Sparkle 只在「距上次 ≥ `SUScheduledCheckInterval`」时
   才立刻查（`SPUUpdater.m:552-589`），否则只排一个未来定时器，
   应用没活到那一刻它就**永远不 fire**。
2. **「检查失败」与「已是最新」共用同一句话** —— 两者的判据此前只有
   「`phase == .idle` 且 `lastUpdateCheckDate != nil`」，而 Sparkle 的
   `SULastCheckTime` 是在**发起**检查时就写的（`SPUUpdater.m:789`，在任何网络请求之前）
   ⇒ 「根本没查成」也会被渲染成「刚刚查过、是最新版」。
   用户那条读数就是这么一次**无法分辨**的读数（当时线上是 build 277、盘上 273，
   一次真的查成的检查**不可能**得出「已是最新版本」）。

   这一条**修了两遍**，第二遍是**真机验证逼出来的**（记在这里，因为它是最贵的一课）：
   初版把结论挂在 user driver 的 `showUpdateNotFoundWithError` / `showUpdaterError` 上
   —— 判据看着很硬（`SPUUIBasedUpdateDriver.m:464-495` 正是按码分流这两个回调），
   单测全绿、变异全被抓。**真机一跑就穿**：把 feed 指到关掉的端口，Sparkle 打了
   `kCFErrorDomainCFNetwork -1004`，而结论一个字节都没写 —— 因为
   `SPUScheduledUpdateDriver.m:106` 传的是 `showErrorToUser:_showedUpdate`，
   而 `_showedUpdate` 只在**已经展示过更新**之后才为真
   ⇒ 「启动/后台检查失败」**没有任何 user driver 回调**。而用户报的那一次正是后台检查。
   ⇒ 结论换到 `SPUUpdater.m:810` 的 delegate 回调（逐轮必到），并且**只有一个写入点**
   （M9e / M9f 守的就是「唯一来源」这条）。
   教训：**「代码里有这一行」与「这一行真的会被调到」是两件事**，
   而后者只有真机能答。

没有这一步，新守卫与「没写」逐字相同 —— 因为「装置报绿」有三种可能：
装置宽容 / 装置死了 / **变异自己没变成旧行为**。

还有一条不是在守更新逻辑：`UpdateFeedTests.脚本写明了自动检查的默认值()` 里那条
「Info.plist 的 heredoc 不许出现反引号」。它守的是**写更新配置的那段 shell** ——
2026-09-28 实测：`SUScheduledCheckInterval` 的注释里写了反引号包起来的
Swift 方法名，于是每次构建打一条 `command substitution` 告警，而那段文字在产出的
`Info.plist` 里**被静默吃掉**。变异 M15 就把它塞回去。

## 用法

```bash
python3 Scripts/test/update_check_mutation.py
```

## 硬规则（沿用 `wait_outcome_mutation.py`）

- **备份用 `cp`，还原也用 `cp`**：不用 `git checkout`（它会连未提交的改动一起清掉）。
- **每次变异前先证明它落地了**（回读文件、打印那一行），否则「仍绿」可能只是没改上。
- **打印被测命令的原始尾部**，不只打印判红结论 —— 判据自己也会错。
- 判红口径 = **正向证据** `Test run with N tests`（N ≥ 1）；`swift test` 的
  「退出码 0」同时表示「全通过」与「一条都没跑到」（2026-09-28 统一口径，见
  `eject_hook_mutation.py` 的第四次实测）。
- **先跑基线自检**（`baseline_is_green`）：未变异时必须绿，否则「每条都被抓住」毫无意义。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CONTROLLER = REPO / "Sources/Services/UpdateController.swift"
DRIVER = REPO / "Sources/Services/UpdateUserDriver.swift"
VIEW = REPO / "Sources/Views/SettingsView.swift"
CATALOG = REPO / "Sources/Localization/Localizable.xcstrings"
BUILD_SCRIPT = REPO / "build_app.sh"

# 九条守卫的过滤器（`swift test --filter` 认**函数名**正则）。
FILTER_LAUNCH = "启动检查的判据"
FILTER_WIRING = "启动检查接在排期回调上"
FILTER_SELECTOR = "启动检查的delegate选择器真的被导出了"
FILTER_OUTCOME = "检查成功与失败落在不同的结论上"
FILTER_OUTCOME_PURE = "检查结论的判据"
FILTER_OUTCOME_SELECTOR = "检查结论的delegate选择器真的被导出了"
FILTER_ROWSTATE = "检查失败不许冒充已是最新版本"
FILTER_TEXT = "检查失败那一行有出口且不说谎"
# ⚠️ 这条在 `UpdateFeedTests` 里（**不属于**更新检查那个 suite）：它守的是
# `build_app.sh` 写进 Info.plist 的那段 shell。见模块说明里「第三个守卫」。
FILTER_PLIST = "脚本写明了自动检查的默认值"
# 「更新」组拆成两行（2026-09-28）之后的四条。
FILTER_ROWS_OWN = "两个开关各自只驱动自己那个标志"
FILTER_ROWS_ORDER = "关掉检查时先关下载再关检查"
FILTER_ROWS_TAP = "下载行的可点性与说明必须同源"
FILTER_ROWS_STATE = "出图注入态不许再存一份可点性"

# 「测试真的跑过」的**正向证据**：swift-testing 无论成败都会打这一行（见 ``classify``）。
TEST_RUN_RE = re.compile(r"Test run with (\d+) tests?")
# 构建成功的**正向证据**：SwiftPM 每次构建都会打；**编不过就没有它**。
BUILD_OK_RE = re.compile(r"^\s*Build complete!", re.M)
# 编译诊断的**两种**形态：① swiftc `<file>:<行>:<列>: error:`；② 构建期无行号。
COMPILE_DIAG_RE = re.compile(r":\d+:\d+: error:|^\s*error: (?:Build failed|fatalError)", re.M)

# 基线自检：本脚本的变异散在**十三**条测试上（十二条同一 suite + 一条 UpdateFeedTests），必须全跑。
BASELINE_FILTER = "|".join(
    [FILTER_LAUNCH, FILTER_WIRING, FILTER_SELECTOR, FILTER_OUTCOME, FILTER_OUTCOME_PURE,
     FILTER_OUTCOME_SELECTOR, FILTER_ROWSTATE, FILTER_TEXT, FILTER_PLIST,
     FILTER_ROWS_OWN, FILTER_ROWS_ORDER, FILTER_ROWS_TAP, FILTER_ROWS_STATE])
BASELINE_TESTS = (
    "启动检查的判据",
    "启动检查接在排期回调上",
    "启动检查的delegate选择器真的被导出了",
    "检查成功与失败落在不同的结论上",
    "检查结论的判据",
    "检查结论的delegate选择器真的被导出了",
    "检查失败不许冒充已是最新版本",
    "检查失败那一行有出口且不说谎",
    "脚本写明了自动检查的默认值",
    "两个开关各自只驱动自己那个标志",
    "关掉检查时先关下载再关检查",
    "下载行的可点性与说明必须同源",
    "出图注入态不许再存一份可点性",
)
# 基线里**至少**要跑到多少条。防的是「过滤器只匹配上一部分」。
BASELINE_MIN_TESTS = 13


def _normalize_name(s: str) -> str:
    """把测试名归一化：去掉引号 / 书名号 / 括号 / 空白（函数名与显示名常不同形）。"""
    return re.sub(r"[\s「」『』\"'“”（）()\[\]{}]", "", s)


# (编号, 说明, 文件, 旧片段, 新片段, 过滤器)
MUTATIONS = [
    (
        "M1",
        "忽略用户的「自动更新」开关 —— 关掉之后启动时还是会偷偷查一次",
        CONTROLLER,
        "guard automaticallyChecks else { return false }",
        "guard automaticallyChecks else { return true }",
        FILTER_LAUNCH,
    ),
    (
        "M2",
        "把「时间戳在未来」（时钟回拨 / 被手改）当成「刚查过」—— 于是永久静默",
        CONTROLLER,
        "guard lastCheck <= now else { return true }",
        "guard lastCheck <= now else { return false }",
        FILTER_LAUNCH,
    ),
    (
        "M3",
        "防抖边界由闭改开（`>=` → `>`）—— 恰好等于防抖的那一次漏掉",
        CONTROLLER,
        "return now.timeIntervalSince(lastCheck) >= debounce",
        "return now.timeIntervalSince(lastCheck) > debounce",
        FILTER_LAUNCH,
    ),
    (
        "M4",
        "**回到旧行为**：启动时永远不查（这正是用户报的那件事）",
        CONTROLLER,
        "return now.timeIntervalSince(lastCheck) >= debounce",
        "return false",
        FILTER_LAUNCH,
    ),
    (
        "M5",
        "用错入口：走 `checkForUpdates()`（用户按下那个语义）而不是后台那个",
        CONTROLLER,
        # ⚠️ 锚点**不能**只用 `updater.checkForUpdatesInBackground()`：裸串命中 2 次
        # —— `startIfNeeded()` 上方那段说明性注释里也写了一遍（解释「为何不能放这儿」）。
        # 带上日志那条语句的收尾 `"""）` 才唯一。
        "            \"\"\")\n        updater.checkForUpdatesInBackground()",
        "            \"\"\")\n        updater.checkForUpdates()",
        FILTER_WIRING,
    ),
    (
        "M6",
        "把「发起检查」那一步整个删掉（判据算出来了却没人用）",
        CONTROLLER,
        "            \"\"\")\n        updater.checkForUpdatesInBackground()",
        "            \"\"\")\n        Self.logger.info(\"变异：没有发起检查\")",
        FILTER_WIRING,
    ),
    (
        "M6b",
        "**第一版实现的样子**：把发起检查挪回 `startIfNeeded()` —— "
        "那一句会被 Sparkle 静默丢掉（`sessionInProgress` 还没让出来），"
        "而「代码里有这一行」看起来很对、断言也查不出来",
        CONTROLLER,
        "        _ = ensureUpdater()\n    }",
        "        if let updater = ensureUpdater() { updater.checkForUpdatesInBackground() }\n    }",
        FILTER_WIRING,
    ),
    (
        "M6c",
        "拆掉「只覆盖一次」的闸门 —— 6 小时的排期被压成 5 分钟",
        CONTROLLER,
        "        guard !didRunLaunchCheck else { return }\n",
        "",
        FILTER_WIRING,
    ),
    (
        "M6d",
        "让「不查」那一支变成哑的（日志还在，但不再说明发生了什么）—— "
        "于是「这次启动没检查」是回调没到、还是判据说不用查，读日志分不出来",
        CONTROLLER,
        "                启动检查：跳过 —— 自动检查开关 ",
        "                启动检查：—— 自动检查开关 ",
        FILTER_WIRING,
    ),
    (
        "M7",
        "把「已落下载/安装终态 ⇒ 检查必定成功」那一支删掉 —— "
        "**下载失败**于是被记成「检查失败」（反方向的一句谎）",
        CONTROLLER,
        "        case .failed, .installFailed:\n            return .succeeded\n",
        "",
        FILTER_OUTCOME_PURE,
    ),
    (
        "M8",
        "把 `SUNoUpdateError` 从「不是错」的名单里剔掉 —— "
        "「查到了、没有新版」被记成检查失败（界面把「已是最新」说成「检查失败」）",
        CONTROLLER,
        "        switch nsError.code {\n        case 1001,  // SUNoUpdateError —— 查到了，没有可用更新\n",
        "        switch nsError.code {\n        case 0,  // 变异：SUNoUpdateError 不在名单里了\n",
        FILTER_OUTCOME_PURE,
    ),
    (
        "M9",
        "`guard let error else` 由「成功」翻成「失败」—— 正常结束被记成检查失败",
        CONTROLLER,
        "        guard let error else { return .succeeded }\n",
        "        guard let error else { return .failed }\n",
        FILTER_OUTCOME_PURE,
    ),
    (
        "M9b",
        "兜底那一支由「失败」翻成「成功」—— **回到用户报的那个病**："
        "取不到 feed 却记成「成功了、已是最新版本」",
        CONTROLLER,
        "            4008:  // SUInstallationAuthorizeLaterError\n            return .succeeded\n        default:\n            return .failed",
        "            4008:  // SUInstallationAuthorizeLaterError\n            return .succeeded\n        default:\n            return .succeeded",
        FILTER_OUTCOME_PURE,
    ),
    (
        "M9c",
        "把域判定整条删掉 —— 别的域里同样编号（1001）的错误被当成「没有新版本」",
        CONTROLLER,
        "        guard nsError.domain == SUSparkleErrorDomain else { return .failed }\n",
        "",
        FILTER_OUTCOME_PURE,
    ),
    (
        "M9d",
        "delegate 选择器拼错一个词（`didFinishUpdateCycleForr`）—— "
        "只出 warning、不编译失败，而方法**永远不会被调**",
        CONTROLLER,
        "didFinishUpdateCycleFor updateCheck:",
        "didFinishUpdateCycleForr updateCheck:",
        FILTER_OUTCOME_SELECTOR,
    ),
    (
        "M9e",
        "让「周期收尾」回调**不写结论**（判据算了却没人用）",
        CONTROLLER,
        "        lastCheckOutcome = outcome",
        "        _ = outcome",
        FILTER_OUTCOME,
    ),
    (
        "M9g",
        "让「发现有效更新」**不落结论** —— 弹窗路（周期收尾回调不发）于是在重开应用后"
        "倒退回「已是最新版本」（真机实测到的那条窄口子）",
        CONTROLLER,
        "        lastCheckOutcome = .succeeded",
        "        _ = item.displayVersionString",
        FILTER_OUTCOME,
    ),
    (
        "M9f",
        "回退到初版那个**错的落点**：让 user driver 兜底支去写结论。"
        "代码里看着对，而它**不是每轮必到**的回调（后台检查根本没 UI 回调）",
        DRIVER,
        "        controller?.driverDidReset()\n        }\n        acknowledgement()",
        "        controller?.lastCheckOutcome = .failed\n        }\n        acknowledgement()",
        FILTER_OUTCOME,
    ),
    (
        "M10",
        "`rowState` 里恒说「已是最新版本」—— **本轮在修的那句断言**原地复活",
        CONTROLLER,
        "return outcome == .failed ? .checkFailed(lastCheck) : .upToDate(lastCheck)",
        "return .upToDate(lastCheck)",
        FILTER_ROWSTATE,
    ),
    (
        "M11",
        "`rowState` 里恒说「检查失败」—— 反向的一句谎（查成了也说失败）",
        CONTROLLER,
        "return outcome == .failed ? .checkFailed(lastCheck) : .upToDate(lastCheck)",
        "return .checkFailed(lastCheck)",
        FILTER_ROWSTATE,
    ),
    (
        "M12",
        "`rowState` 把结论判反（`.failed` 说成最新、`.succeeded` 说成失败）",
        CONTROLLER,
        "return outcome == .failed ? .checkFailed(lastCheck) : .upToDate(lastCheck)",
        "return outcome == .succeeded ? .checkFailed(lastCheck) : .upToDate(lastCheck)",
        FILTER_ROWSTATE,
    ),
    (
        "M13",
        "那一行的三语文案改回「已是最新版本」（谎话换个地方重来）",
        CATALOG,
        "\"上次检查：%@ · 检查失败\"",
        "\"上次检查：%@ · 已是最新版本\"",
        FILTER_TEXT,
    ),
    (
        "M14",
        "那一行挂回「已是最新」的文案键（界面与判据分叉）",
        VIEW,
        "format: L10n.tr(.updateCheckFailedFormat),",
        "format: L10n.tr(.updateUpToDateFormat),",
        FILTER_TEXT,
    ),
    (
        "M15",
        "把反引号塞回 Info.plist 的 heredoc（**本轮的事故现场**）—— "
        "未加引号的 heredoc 会先做命令替换：每次构建打一条告警，"
        "而那段注释在产物里被**静默吃掉**",
        BUILD_SCRIPT,
        "         成本：一次 appcast 请求 3.3 KB，最坏 4 次/天。",
        "         成本：一次 appcast 请求 3.3 KB（用 `curl` 量的），最坏 4 次/天。",
        FILTER_PLIST,
    ),
    # ---- 「更新」组拆成两行（2026-09-28）之后新增的七条 ----
    #
    # 这一组的共同点：**改坏了界面上完全看不出来**。
    # 两行各自显示自己的值，互相偷改对方的存储时，两边的开关位置都还是对的。
    (
        "M16",
        "「自动检查更新」开的时候顺手把「自动下载」也打开 —— 两行又绑回一起（"
        "界面上看不出来：那一行的说明仍写着「退出时安装」，而下载其实已经开了）",
        VIEW,
        "            UpdateController.shared.automaticallyChecksForUpdates = true",
        "            UpdateController.shared.automaticallyChecksForUpdates = true\n"
        "            UpdateController.shared.automaticallyDownloadsUpdates = true",
        FILTER_ROWS_OWN,
    ),
    (
        "M17",
        "关掉「自动检查更新」时**不管**「自动下载」—— UserDefaults 里留下一个停在 1 的 "
        "SUAutomaticallyUpdate（有效行为被 getter 与 allows 相与掩盖，只有读 defaults 的人会中招）",
        VIEW,
        "            UpdateController.shared.automaticallyDownloadsUpdates = false\n"
        "            UpdateController.shared.automaticallyChecksForUpdates = false",
        "            UpdateController.shared.automaticallyChecksForUpdates = false",
        FILTER_ROWS_ORDER,
    ),
    (
        "M18",
        "把「关检查时顺手关下载」的**写入顺序对调** —— downloads 写不进去（setter 在 "
        "allows 为假时空操作），存下来的仍是旧值；而界面与行为**都正常**",
        VIEW,
        "            UpdateController.shared.automaticallyDownloadsUpdates = false\n"
        "            UpdateController.shared.automaticallyChecksForUpdates = false",
        "            UpdateController.shared.automaticallyChecksForUpdates = false\n"
        "            UpdateController.shared.automaticallyDownloadsUpdates = false",
        FILTER_ROWS_ORDER,
    ),
    (
        "M19",
        "「自动下载更新」那一行去改「自动检查」的标志 —— 显示的东西与它实际做的事不一致",
        VIEW,
        "        UpdateController.shared.automaticallyDownloadsUpdates = newValue",
        "        UpdateController.shared.automaticallyDownloadsUpdates = newValue\n"
        "        UpdateController.shared.automaticallyChecksForUpdates = newValue",
        FILTER_ROWS_OWN,
    ),
    (
        "M20",
        "下载行的可点性判据丢掉「检查开着」这一半 —— 于是「点一下、开关动一下、"
        "实际什么都没发生」（Sparkle 的 setter 在 allows 为假时空操作）",
        VIEW,
        "        guard canAutoUpdate, autoCheckUpdateOn else { return nil }",
        "        guard canAutoUpdate else { return nil }",
        FILTER_ROWS_TAP,
    ),
    (
        "M21",
        "下载行的说明从「三态」压成「两态」—— 「检查没开」那批用户读到的会是"
        "「组件没起来」：**编一个具体原因比不写原因更糟**（§8.113.14 的教训）",
        VIEW,
        "        if !canAutoUpdate { return L10n.tr(.autoUpdateUnavailableHint) }\n"
        "        return autoCheckUpdateOn ? L10n.tr(.autoDownloadUpdateHint) "
        ": L10n.tr(.autoDownloadNeedsCheckHint)",
        "        return canAutoUpdate ? L10n.tr(.autoDownloadUpdateHint) "
        ": L10n.tr(.autoUpdateUnavailableHint)",
        FILTER_ROWS_TAP,
    ),
    (
        "M22",
        "往出图注入态里再存一份「能不能点」—— 出图与视图推出来的可点性从此可以互相矛盾，"
        "而**出图正是用来「看有没有矛盾」的**（尺子做成了橡皮筋）",
        VIEW,
        "    var downloadsIsOn: Bool",
        "    var downloadsIsOn: Bool\n    var downloadIsTappable: Bool = true",
        FILTER_ROWS_STATE,
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
    """把一次运行判成 `red` / `green` / `invalid`（口径见模块说明）。

    ⚠️ **不许**写成 `"error:" in raw`：扫源码型守卫失败时 swift-testing 会把
    `#expect` 的操作数（**整份被扫文件**）整份回显，文件里凡有 `error:` 字样就撞上
    ⇒ 真的跑起来并失败的变异被判成 `invalid`、**不算通过**。
    本脚本扫的正是 `UpdateController.swift` / `SettingsView.swift` 这类大文件，
    撞上的概率极高（`prompt(for error:)` 之类形参名）。实测踩过，见
    `eject_hook_mutation.py` 的第四次实测。
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

    ⚠️ 光看「退出码 0」不够：**跑 0 条测试也返回 0**（见 ``classify``）。
    所以这里三重自证：① ``classify`` 判 green；② 跑到 ≥ ``BASELINE_MIN_TESTS`` 条；
    ③ 五条测试函数名逐个出现在输出里（归一化后比）。
    """
    print("===== 基线自检（未变异，五条测试全跑）=====")
    code, raw = run_tests(BASELINE_FILTER)
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
        f"基线跑到 {count} 条测试；{len(BASELINE_TESTS)} 条测试名核对："
        + ("全在" if not missing else "缺 " + "、".join(missing)))
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
            # ⚠️ 还原**单独一条**，不挂在可能失败的语句后面；还原后再比对确认
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
