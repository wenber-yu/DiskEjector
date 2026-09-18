import Foundation
import Testing

@testable import DiskEjectorApp

/// 设置面板「更新」组与「语言」行的契约测试。
///
/// ## 这一批断言都在钉什么
///
/// 这两块界面的共同点是「**状态很多、而且多数状态在测试进程里造不出来**」：
/// Sparkle 没启动（拿不到 `lastUpdateCheckDate`）、`Locale.current` 由开发机决定、
/// 重启动作不能真跑。所以断言必须落在**纯函数**与**源码结构**上，
/// 而不是「把界面渲染出来看看对不对」。
///
/// 判据同 `UpdateFeedTests`：**改坏了不会编译失败，也不会在别处报警** ——
/// 只能靠测试钉。
@Suite("更新与语言设置")
struct UpdateSettingsTests {

    private var repoRoot: URL {
        // #filePath = <仓库根>/Tests/DiskEjectorAppTests/UpdateSettingsTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - 「检查更新」行的状态

    /// **优先级**：进行中的态 > 跳过 > 已是最新 > 从未检查。
    ///
    /// 这条用的是纯函数，所以能把「两个条件同时成立」构造出来 ——
    /// 真实环境里 `lastUpdateCheckDate` 来自 Sparkle、`phase` 由 Sparkle 的回调推进，
    /// 测试进程里都构造不出来，留在计算属性里就永远测不到顺序。
    @Test func 行状态的优先级() {
        let checked = Date(timeIntervalSince1970: 1_760_000_000)

        // ① 跳过盖过「已是最新」。
        #expect(
            UpdateController.rowState(phase: .idle, skippedVersion: "1.1.0", lastCheck: checked)
                == .skipped(version: "1.1.0"),
            "跳过标记必须盖过「已是最新」—— 否则用户跳过之后界面上不留痕迹，分不清「跳过生效了」和「检查更新坏了」"
        )
        #expect(
            UpdateController.rowState(phase: .idle, skippedVersion: nil, lastCheck: checked)
                == .upToDate(checked))
        #expect(
            UpdateController.rowState(phase: .idle, skippedVersion: nil, lastCheck: nil)
                == .neverChecked)
        #expect(
            UpdateController.rowState(phase: .idle, skippedVersion: "1.1.0", lastCheck: nil)
                == .skipped(version: "1.1.0"),
            "没检查过也要显示跳过态 —— 用户可能是在上次会话里跳过的")

        // ② 进行中的四态盖过一切 —— 否则界面会同时说「已跳过 1.1.0」和「正在下载 1.1.0」。
        #expect(
            UpdateController.rowState(
                phase: .downloading(version: "1.2.0", fraction: 0.42),
                skippedVersion: "1.1.0", lastCheck: checked)
                == .downloading(version: "1.2.0", fraction: 0.42))
        #expect(
            UpdateController.rowState(
                phase: .ready(version: "1.2.0"), skippedVersion: "1.1.0", lastCheck: checked)
                == .ready(version: "1.2.0"))
        #expect(
            UpdateController.rowState(
                phase: .failed(version: "1.2.0"), skippedVersion: "1.1.0", lastCheck: checked)
                == .failed(version: "1.2.0"))
        #expect(
            UpdateController.rowState(
                phase: .found(version: "1.2.0"), skippedVersion: "1.1.0", lastCheck: checked)
                == .found(version: "1.2.0", lastCheck: checked))
    }

    /// 「发现新版本」那一行要把上次检查时间带上（设计稿 B2：`发现 1.1.0 · 上次检查：…`）。
    ///
    /// **时间必须走 `.found` 的关联值**，不能在视图里另读一次 `lastUpdateCheckDate` ——
    /// 那样「发现」与「已是最新」两行各自读一次时钟，跨零点时会互相矛盾。
    @Test func 发现新版本时带上上次检查时间() {
        let checked = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(
            UpdateController.rowState(
                phase: .found(version: "1.1.0"), skippedVersion: nil, lastCheck: checked)
                == .found(version: "1.1.0", lastCheck: checked))
        #expect(
            UpdateController.rowState(
                phase: .found(version: "1.1.0"), skippedVersion: nil, lastCheck: nil)
                == .found(version: "1.1.0", lastCheck: nil),
            "没检查过时 lastCheck 为 nil —— 视图据此退化成不带时间的写法")
    }

    /// 进度只在**整数百分比**变了的时候才发通知。
    ///
    /// `showDownloadDidReceiveData` 是**按数据块**回调的，一个大 dmg 上千次；
    /// 每次都写 `@Published` 会让设置面板每秒重绘几十次。
    /// 而这条边界（42.1% → 42.9% 不该发）在真机上根本构造不出来。
    @Test func 进度按整数百分比去重() {
        #expect(
            UpdateController.shouldPublishProgress(from: 0.421, to: 0.429) == false,
            "同一个整数百分比内的抖动不该触发重绘")
        #expect(UpdateController.shouldPublishProgress(from: 0.429, to: 0.431) == true)
        #expect(UpdateController.shouldPublishProgress(from: 0, to: 0.009) == false)
        #expect(UpdateController.shouldPublishProgress(from: 0, to: 0.01) == true)
        #expect(
            UpdateController.shouldPublishProgress(from: 0.5, to: 0.4) == true,
            "倒着走也要发 —— 服务器给的总长可能偏小，进度会回退，界面必须跟着回退")
    }

    /// 跳过记的是**版本号**，不是布尔。
    ///
    /// 布尔记不住「跳过的是哪一版」：下个版本发布后它还是 `true`，用户会被**永久静音**
    /// （他以为只是跳过了 1.1.0）。这条走一遍 `UserDefaults` 往返 ——
    /// 类型被改成 `Bool` 时，`string(forKey:)` 会返回 `nil`，测试当场红。
    @MainActor
    @Test func 跳过记的是版本号而不是布尔() {
        let controller = UpdateController.shared
        let saved = controller.skippedVersion
        defer { controller.skippedVersion = saved }

        controller.skippedVersion = "1.1.0"
        #expect(controller.skippedVersion == "1.1.0", "读回来的必须是原来那个版本号字符串")
        #expect(controller.rowState == .skipped(version: "1.1.0"))

        controller.skippedVersion = nil
        #expect(controller.skippedVersion == nil)
        #expect(controller.rowState != .skipped(version: "1.1.0"), "清掉之后不该还是跳过态")
    }

    /// 手动「检查更新」会清掉跳过标记（**跳过必须可撤销**）。
    ///
    /// 设计稿 B5 的 spec-note 明确要求：不清的话用户点了「检查更新」也看不到那个版本，
    /// 只能去改偏好文件才能反悔 —— 而界面上没有任何地方告诉他这一点。
    @Test func 手动检查更新会清掉跳过标记() throws {
        let source = try contents("Sources/Services/UpdateController.swift")
        let body = try #require(
            source.range(of: "func checkForUpdates()").map { String(source[$0.lowerBound...]) },
            "找不到 checkForUpdates() —— 改名了就要同步这条断言")
        let head = String(body.prefix(900))
        #expect(
            head.contains("clearSkippedVersion()"),
            "checkForUpdates() 开头必须先清掉跳过标记，否则用户永远看不到被跳过的版本")
    }

    // MARK: - 「更新」是唯一入口

    /// 「检查更新」在设置面板里**只能出现一次**。
    ///
    /// 设计稿 `05-settings.html` 规定「更新」组是这件事的唯一入口：
    /// 同一个动作有两个入口时，用户会以为它们做的事不一样
    /// （一个「检查」一个「更新」，其实都只是问一句有没有新版本）。
    ///
    /// 这条**读源码** —— 与 `UpdateFeedTests` 读 shell 脚本同一个理由：
    /// SwiftUI 的 `Text` 在 AppKit 视图树里没有对应视图，问不到「有几个按钮」，
    /// 只能钉住「源码里只出现一次」。将来真要加第二个入口，会先红在这里。
    ///
    /// ⚠️ **数的是「动作」不是「文案键」**：`L10n.tr(.checkForUpdates)` 在同一个入口里
    /// 出现**两次**（行的标签 + 按钮的标题），数它会把一个入口数成两个。
    /// 第一版就是这么写错的 —— 断言的对象必须是「调用动作的地方」。
    @Test func 检查更新在设置面板里只有一个入口() throws {
        let source = try contents("Sources/Views/SettingsView.swift")
        let occurrences =
            source.components(separatedBy: "UpdateController.shared.checkForUpdates()")
            .count - 1
        #expect(
            occurrences == 1,
            """
            设置面板里有 \(occurrences) 处会真正发起「检查更新」（期望 1）。
            设计稿规定「更新」组是唯一入口 —— 关于行上原来那个按钮已于 2026-09-18 删掉，
            不要再加回来。（行的标签与按钮的标题用同一个文案键是正常的，不计入这里。）
            """
        )
    }

    // MARK: - 「自动更新」开关

    /// 一个开关必须同时驱动 Sparkle 的**检查**与**下载**两级。
    ///
    /// Sparkle 把两者分成 `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate`，
    /// 而设计稿只有一个开关。只开检查不开下载的话，用户开了「自动更新」
    /// 却发现从没自动下载过 —— 那不是他要的。
    @Test func 自动更新开关同时驱动检查与下载() throws {
        let source = try contents("Sources/Views/SettingsView.swift")
        let body = try #require(
            source.range(of: "func toggleAutoUpdate()").map { String(source[$0.lowerBound...]) },
            "找不到 toggleAutoUpdate() —— 改名了就要同步这条断言")
        let head = String(body.prefix(600))
        #expect(head.contains("automaticallyChecksForUpdates = newValue"))
        #expect(
            head.contains("automaticallyDownloadsUpdates = newValue"),
            "只设检查不设下载的话，「自动更新」开着也不会自动下载")
    }

    /// ⚠️ **不要**在 `AppSettings` 里再存一份自动更新偏好。
    ///
    /// 真相在 Sparkle 的 `SPUUpdaterSettings`（写进同一份 UserDefaults）。
    /// 再存一份必然脱节：用户在别处改了它，我们这份不会知道，
    /// 于是界面显示的开关位置与实际行为不一致。
    @Test func 自动更新偏好不在AppSettings里另存一份() throws {
        let source = try contents("Sources/Settings/AppSettings.swift")
        #expect(
            !source.contains("static let autoUpdate ="),
            "AppSettings.Key 里不该有 autoUpdate —— 真相在 Sparkle 那边，另存一份会与它脱节")
    }

    // MARK: - 语言

    /// 「待重启」判定：**只看「选的语言」与「生效的语言」是否相同**。
    @Test func 待重启判定只看选中语言与生效语言是否相同() {
        // 跟随系统永远不「待重启」—— 系统给什么就是什么，没有「等待中的变化」。
        #expect(!LanguageManager.isRestartPending(preferred: .system, active: .zhHans))
        #expect(!LanguageManager.isRestartPending(preferred: .system, active: .en))
        // 选的就是正在用的 → 不待重启。
        #expect(!LanguageManager.isRestartPending(preferred: .en, active: .en))
        // 选的和正在用的不同 → 待重启（这就是那个必须画出来的第三态）。
        #expect(LanguageManager.isRestartPending(preferred: .en, active: .zhHans))
        #expect(LanguageManager.isRestartPending(preferred: .zhHant, active: .zhHans))
        #expect(LanguageManager.isRestartPending(preferred: .zhHans, active: .en))
    }

    /// 系统语言 → 本应用支持的语言。**纯函数**，所以不依赖开发机的 `Locale.current`。
    @Test func 系统语言映射到支持的语言() {
        #expect(LanguageManager.language(for: Locale(identifier: "zh-Hans-CN")) == .zhHans)
        #expect(LanguageManager.language(for: Locale(identifier: "zh-Hans")) == .zhHans)
        #expect(LanguageManager.language(for: Locale(identifier: "en-US")) == .en)
        #expect(LanguageManager.language(for: Locale(identifier: "en")) == .en)
        // 繁体：脚本标注与地区两种写法都要认。
        // 只认一种的话，另一种会静默落进「简体」—— 繁体用户看到简体字，
        // 而且没有任何地方会报错。
        #expect(LanguageManager.language(for: Locale(identifier: "zh-Hant")) == .zhHant)
        #expect(LanguageManager.language(for: Locale(identifier: "zh-Hant-TW")) == .zhHant)
        #expect(LanguageManager.language(for: Locale(identifier: "zh_TW")) == .zhHant)
        #expect(LanguageManager.language(for: Locale(identifier: "zh_HK")) == .zhHant)
    }

    /// 未知的语言偏好回退到「跟随系统」，而不是某个具体语言。
    @Test func 未知语言偏好回退到跟随系统() {
        #expect(AppLanguage.resolve(nil) == .system)
        #expect(AppLanguage.resolve("klingon") == .system)
        #expect(AppLanguage.resolve("") == .system)
        #expect(AppLanguage.resolve("en") == .en)
        #expect(AppLanguage.resolve("zh-Hant") == .zhHant)
    }

    /// 具体语言用**该语言自己的写法**（endonym），只有「跟随系统」走本地化。
    ///
    /// 反过来的话，英文界面里那一项会写成 "Chinese" ——
    /// 一个只认中文的用户在英文界面里找中文，反而要绕一下。
    @Test func 具体语言用该语言自己的写法而跟随系统才本地化() {
        #expect(AppLanguage.zhHans.displayName == "简体中文")
        #expect(AppLanguage.en.displayName == "English")
        #expect(AppLanguage.zhHant.displayName == "繁體中文")
        // 「跟随系统」是产品文案，必须本地化 —— 它不是语言的名字。
        #expect(AppLanguage.system.displayName == TestLanguage.designText(.followSystemLanguage))
    }

    /// 「跟随系统」= **删掉** `AppleLanguages`，不是写一个猜测值。
    ///
    /// 写死 `["zh-Hans"]` 的话，用户之后改系统语言本应用不会跟 —— 名字还叫「跟随系统」。
    @Test func 跟随系统是删掉AppleLanguages而不是写死一个值() throws {
        let source = try contents("Sources/Settings/LanguageManager.swift")
        let body = try #require(
            source.range(of: "static func apply(").map { String(source[$0.lowerBound...]) },
            "找不到 apply(_:) —— 改名了就要同步这条断言")
        let head = String(body.prefix(900))
        #expect(head.contains("removeObject(forKey: appleLanguagesKey)"))
        #expect(
            head.contains("UserDefaults.standard.set([code], forKey: appleLanguagesKey)"),
            "具体语言要写成数组（AppleLanguages 是数组，写成字符串不生效且不报错）")
    }

    // MARK: - 更新弹窗与 Sparkle 之间的接线（读源码）
    //
    // **为什么读源码而不是驱动真流程**：这条链上两头都是不可测的 ——
    // 一头是 Sparkle 的会话（需要真实 appcast 与签名），另一头是自绘窗口
    // （SwiftUI 的 `Text` 在 AppKit 视图树里没有对应视图）。
    // 而「用户按了 Esc 到底回答了 Sparkle 什么」这种接线一旦接错，
    // **编译不会失败、界面上也看不出来**，只有更新装错版本时才暴露。
    //
    // ⚠️ 读源码断言要**数动作不数文案键**（2026-09-18 踩过：数 `L10n.tr(.checkForUpdates)`
    // 时同一个入口里行标签与按钮标题各用一次，恒为 2，断言永远绿）。

    /// **弹窗只在自动更新关掉时出现**（设计稿 A 段的开场白）。
    ///
    /// 开着的时候用户什么都不用做 —— 这正是「后台更新」这个词的含义。
    /// 若这里改成「用户主动检查就弹」，开关开着时也会弹，与设计稿自相矛盾。
    @Test func 弹窗只在自动更新关掉时出现() throws {
        let source = try contents("Sources/Services/UpdateUserDriver.swift")
        let body = try #require(
            source.range(of: "func showUpdateFound(").map { String(source[$0.lowerBound...]) },
            "找不到 showUpdateFound —— 改名了就要同步这条断言")

        #expect(
            body.contains("autoDownloads: controller.automaticallyDownloadsUpdates"),
            "弹窗与否只看「自动更新」开关")
        #expect(
            !body.contains("state.userInitiated"),
            "不许按 userInitiated 分流 —— 那会让「开着开关但用户手点检查」也弹窗，而设计稿写死了「开着的时候用户什么都不用做」"
        )
        #expect(
            body.contains("if shouldPresent {") && body.contains("reply(.install)"),
            "不弹窗的那条路必须直接开始下载（reply(.install)），否则后台路径根本不会启动")
    }

    /// 弹窗的三个出口各自回答 Sparkle 哪个 choice。
    ///
    /// 接错的后果很具体：Esc 若回答 `.skip`，用户按一下「稍后」就被**永久静音**了。
    @Test func 三个出口各自回答哪个choice() throws {
        let source = try contents("Sources/Services/UpdateController.swift")
        let body = try #require(
            source.range(of: "func showUpdateAlertIfNeeded()").map { String(source[$0.lowerBound...]) },
            "找不到 showUpdateAlertIfNeeded —— 改名了就要同步这条断言")

        #expect(body.contains("reply(.install)"), "「后台更新并重启」→ install")
        #expect(body.contains("reply(.skip)"), "「跳过此版本」→ skip")
        #expect(
            body.contains("reply(.dismiss)"),
            "Esc / 关窗 → dismiss（**不是 skip** —— 那会变成永久静音）")
        #expect(
            body.contains("skipPendingVersion()"),
            "回答 .skip 之前必须把版本号记下来，否则设置行留不下「已跳过 1.1.0」这条痕迹")
    }

    /// 「立即重启」回答的是 `.install`，**不是先 dismiss 再想办法**。
    ///
    /// Sparkle 只在 `showReadyToInstallAndRelaunch` 的 reply 里接受「现在就装」；
    /// 一旦回了 `.dismiss`，就没有公开 API 能把这次安装重新叫起来。
    @Test func 立即重启回答的是install() throws {
        let source = try contents("Sources/Services/UpdateController.swift")
        let body = try #require(
            source.range(of: "func installReadyUpdate()").map { String(source[$0.lowerBound...]) },
            "找不到 installReadyUpdate —— 改名了就要同步这条断言")
        let head = String(body.prefix(300))

        #expect(head.contains("reply(.install)"))
        #expect(!head.contains("reply(.dismiss)"))
        #expect(
            head.contains("readyReply = nil"),
            "回答之前要先清掉，否则第二次点会重复回答同一个 reply")
    }

    /// 进度是**按数据块累加**的，且总长未知时不猜百分比。
    ///
    /// `showDownloadDidReceiveData` 给的是**增量**，直接当比例用的话进度条永远停在 0。
    /// 而总长为 0（服务器没给 `Content-Length`）时猜出来的百分比会在中途倒退 ——
    /// 比没有进度更让人怀疑。
    @Test func 进度按数据块累加且总长未知时不猜() throws {
        let source = try contents("Sources/Services/UpdateUserDriver.swift")
        let body = try #require(
            source.range(of: "func showDownloadDidReceiveData(").map { String(source[$0.lowerBound...]) },
            "找不到 showDownloadDidReceiveData —— 改名了就要同步这条断言")
        let head = String(body.prefix(500))

        #expect(head.contains("receivedContentLength += length"), "回调给的是增量，必须累加")
        #expect(
            head.contains("guard expectedContentLength > 0 else { return }"),
            "总长未知时直接返回，不猜百分比")
    }
}
