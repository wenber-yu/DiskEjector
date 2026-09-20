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

    /// 取一个成员函数的方法体（签名之后、下一个同缩进的成员声明之前）。
    ///
    /// **为什么不直接对整份源码 `contains`**：整文件搜索会被**别处的一句注释或死代码**
    /// 满足 —— 断言于是退化成「这个字符串在仓库里出现过」，与「启动链上真的调了它」
    /// 是两回事。而这里要钉的恰恰是**调用点在哪个函数里**。
    private func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try #require(
            source.range(of: signature),
            "找不到 \(signature) —— 改名了就要同步这条断言")
        let rest = source[start.upperBound...]
        let boundaries = [
            "\n    func ", "\n    private func ", "\n    static func ", "\n    @discardableResult",
        ]
        let end = boundaries.compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    /// 只留代码行，去掉整行注释。
    ///
    /// **为什么必须去掉**：本仓库的注释习惯是**引用**被断言的那个标识符
    /// （例如「2026-09-18 实扫发现 `driverDidFailDownload` 当时没有调用点」）。
    /// 对整段方法体直接 `contains` 的话，**把调用删掉、注释留着**依然会绿 ——
    /// 断言于是退化成「这个字符串在文件里出现过」，而这里要钉的是「真的调了它」。
    ///
    /// 只去**整行**注释（`//` 打头）；行尾注释留着，因为它前面那截是真代码。
    private func codeOnly(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 取 `switch` 里某一个 `case` 的整段（到下一个**同缩进**的 `case` 之前）。
    ///
    /// **为什么需要它**：`updateCheckLine` 的每一个行态都写在同一个 `switch` 里，
    /// 对整份 `SettingsView.swift` 做 `contains` 的话，断言会被**另一个分支**满足
    /// —— 与 `functionBody` 那条理由一样：要钉的是「这一段里有什么」。
    ///
    /// ⚠️ 缩进敏感（`case` 固定 8 空格）。缩进被改时它会**找不到**并报红，
    /// 而不是静默变绿 —— 这正是想要的（同 §8.80.9：口径失效必须是红的）。
    /// 取 `anchor` 之后、下一个 `stop` 之前的那一段。
    ///
    /// 用来从源码 / HTML 里**抠出一个值**（键名、属性值、某一帧），
    /// 而不是 `contains` 一下就完事 —— `contains` 只能回答「在不在」，
    /// 回答不了「两边是不是**同一个**」。
    ///
    /// ⚠️ 找不到就返回 `nil`（让调用方 `#require` 报红），**不静默返回空串**：
    /// 空串会让「找不到」与「找到了一个空值」长得一样。
    private func slice(after anchor: String, upTo stop: String, in text: String) -> String? {
        guard let a = text.range(of: anchor) else { return nil }
        let rest = text[a.upperBound...]
        guard let b = rest.range(of: stop) else { return nil }
        return String(rest[rest.startIndex..<b.lowerBound])
    }

    private func caseBlock(_ header: String, in source: String) throws -> String {
        let start = try #require(
            source.range(of: header),
            "找不到 \(header) —— 改了 case 的写法就要同步这条断言")
        let rest = source[start.upperBound...]
        // ⚠️ **两个候选 stop 都要有**（2026-09-20 补）：只认 `\n        case ` 的话，
        // 取**最后一支**时会一直吃到**文件末尾**（它后面没有别的 case 了）——
        // 于是「这一支里没有 X」这类**否定**断言会被后面别处的 X 满足 ⇒ 静默变绿。
        // `\n        }`（8 空格 + `}`）只匹配 switch 自己的收尾：分支内部的 `}` 缩进更深。
        let end =
            ["\n        case ", "\n        }"]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
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

        // ② 进行中 / 受阻的六态盖过一切 —— 否则界面会同时说「已跳过 1.1.0」和「正在下载 1.1.0」。
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

        // ⚠️ **`.checking` 也在这条链上**（2026-09-20 补，§8.93 / §8.97）：
        // 它是「用户点了、Sparkle 还没答」的那 3~4.5 秒。若被跳过态盖过，
        // 界面上仍写着「已跳过 1.1.0」—— 用户会以为那一下没生效，然后再点一次。
        #expect(
            UpdateController.rowState(
                phase: .checking, skippedVersion: "1.1.0", lastCheck: checked)
                == .checking,
            "「正在检查」被跳过态盖过了 —— 用户点完看到的是上一轮的结果，会反复点（真机实测这段 3~4.5 秒，§8.93）")
        #expect(
            UpdateController.rowState(phase: .checking, skippedVersion: nil, lastCheck: checked)
                == .checking,
            "「正在检查」被「已是最新版本」盖过了 —— 那正是这条中间态要修的现象：点完几秒内零反馈")
        #expect(
            UpdateController.rowState(phase: .checking, skippedVersion: nil, lastCheck: nil)
                == .checking,
            "「正在检查」被「尚未检查」盖过了 —— 点完还是写着「尚未检查」，用户只能再点一次")

        // ⚠️ **`.locationBlocked` 也在这条链上**（2026-09-20 补，§8.94 / §8.95.7）：
        // 只读卷上 Sparkle **连 appcast 都不去取**（`SPUBasicUpdateDriver.m:71` 判 `MNT_RDONLY`），
        // 而它仍把「上次检查时间」写成当下（`SPUUpdater.m:789`）—— 落到「已是最新版本」
        // 就是**谎报**：明明一次网络请求都没发。
        #expect(
            UpdateController.rowState(
                phase: .locationBlocked, skippedVersion: "1.1.0", lastCheck: checked)
                == .locationBlocked,
            "「位置不允许更新」被跳过态盖过了 —— 用户会以为是跳过标记挡着，去点「检查更新」")
        #expect(
            UpdateController.rowState(phase: .locationBlocked, skippedVersion: nil, lastCheck: checked)
                == .locationBlocked,
            "「位置不允许更新」被「已是最新版本」盖过了 —— 只读卷上这就是一句谎话（§8.94 实测零网络请求）")
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

    /// **「正在检查」这一态只在 `ensureUpdater()` 成功之后才设** —— 顺序错了会留下一个没有出口的态。
    ///
    /// `checkForUpdates()` 里 updater 起不来时是**直接 `return` 并跳去下载页**的
    /// （`UpdateService.openUpdateSource()`）。若把 `phase = .checking` 提到 `guard` 之前，
    /// 那条路上界面会**永远停在「正在检查更新…」**，而它实际发生的事是「打开网页」——
    /// 用户等的是一个永远不来的答案。
    ///
    /// ⚠️ **为什么是源码文本守卫**：`phase` 是 `private(set)`、`ensureUpdater()` 是 `private`，
    /// 测试进程里造不出「updater 起不来」那条路（同 `停摆兜底挂在phase的didSet上` 的局限）。
    /// 而顺序这件事**编译不会管、别处也不会红** —— 只能靠这条钉。
    ///
    /// 变异验证见本轮记录：把 `phase = .checking` 挪到 `guard` 之前，这条会红。
    @Test func 正在检查这一态只在updater起来之后才设() throws {
        let source = try contents("Sources/Services/UpdateController.swift")
        let body = codeOnly(try functionBody("func checkForUpdates()", in: source))

        let ensureAt = try #require(
            body.range(of: "ensureUpdater()")?.lowerBound,
            "checkForUpdates() 里没有 ensureUpdater() —— 改名了就要同步这条断言")
        let checkingAt = try #require(
            body.range(of: "phase = .checking")?.lowerBound,
            """
            checkForUpdates() 没有把状态推进到「正在检查」——
            用户点完之后界面在这几秒里零反馈（真机实测 4.31 / 3.15 / 4.51 秒，§8.93），
            而「检查更新」按钮在这几秒里仍亮着、仍可反复点。实得：
            \(body)
            """)

        #expect(
            checkingAt > ensureAt,
            """
            `phase = .checking` 排在 `ensureUpdater()` 之前了。
            updater 起不来时上面已经 `return` 并跳去下载页 —— 提前设的那一态
            会**永远停在「正在检查更新…」**，而它实际发生的事是「打开网页」。
            这一态**必须有出口**，所以它只能在确认 updater 起来了之后才设。实得：
            \(body)
            """)
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

    // MARK: - updater 的启动时机

    /// **updater 必须在启动链上真的被建起来** —— 否则「自动更新」开关只是个装饰。
    ///
    /// 2026-09-18 实测到的断点：`UpdateController.startIfNeeded()` **全仓库只有定义、
    /// 没有任何调用点**（死代码）。于是 `SPUUpdater.start()` 从未执行过，Sparkle 的
    /// 自动检查排期从未开始 —— 而 Info.plist 里的 `SUEnableAutomaticChecks=true`、
    /// `SUScheduledCheckInterval=86400`、设置面板上那个「自动更新」开关，
    /// **三样全都显示为「配好了」**；设置行则永远停在「尚未检查」。
    ///
    /// 这正是本仓库反复记的那类判据：**「设了没生效」与「功能坏了」在界面上长得一样**，
    /// 所以必须有一条断言把「接线还在不在」钉住。这条读源码 —— 与
    /// `检查更新在设置面板里只有一个入口` 同一个理由：接线断掉**不会编译失败、不会崩、
    /// 也不会有别的断言变红**，只有真发一版、真等一天才看得出来。
    @Test func 启动链上必须真的建起updater() throws {
        let source = try contents("Sources/DiskEjectorApp/DiskEjectorApp.swift")
        let body = codeOnly(try functionBody("func applicationDidFinishLaunching(", in: source))

        #expect(
            body.contains("UpdateController.shared.startIfNeeded()"),
            """
            applicationDidFinishLaunching 里没有 `UpdateController.shared.startIfNeeded()`。
            Sparkle 只在 `SPUUpdater.start()` 之后才会排期自动检查 —— 不建它，
            「自动更新」开关、SUEnableAutomaticChecks、SUScheduledCheckInterval 全都形同虚设，
            而界面上完全看不出来（设置行永远停在「尚未检查」）。
            """
        )
        #expect(
            !body.contains("checkForUpdates()"),
            """
            启动链上调了 checkForUpdates() —— 那会**每次启动都主动联网并可能弹窗**。
            启动只负责把 updater 建起来；要不要检查由 Sparkle 的排期与「自动更新」开关决定
            （见 UpdateController.startIfNeeded() 的说明）。
            """
        )
    }

    // MARK: - 「下载失败」这一态必须真的有生产者

    /// 这次报错该不该算成「下载失败」——**纯函数**，所以能把两种情形都构造出来。
    ///
    /// 真实环境里「下载中报错」**造不出来**（要真的下载、且真的失败），
    /// 而它正是 `.failed` 那一态的唯一来源。留成驱动里一句 `if case` 的话，
    /// 「分支写反了」或「被删掉了」都不会有任何断言变红
    /// —— 2026-09-18 实扫发现 `driverDidFailDownload` 当时**全仓库没有调用点**，就是这么发生的。
    @Test func 只有正在下载时出错才算下载失败() {
        #expect(UpdateController.isDownloadFailure(phase: .downloading(version: "1.1.0", fraction: 0)))
        #expect(UpdateController.isDownloadFailure(phase: .downloading(version: "1.1.0", fraction: 0.97)))

        // 其余每一态都不是「下载失败」——**尤其 `.failed` 自己**：
        // 它已经在这一态里了，再判一次会让错误处理递归地停不下来。
        #expect(!UpdateController.isDownloadFailure(phase: .idle))
        #expect(!UpdateController.isDownloadFailure(phase: .found(version: "1.1.0")))
        #expect(!UpdateController.isDownloadFailure(phase: .ready(version: "1.1.0")))
        #expect(!UpdateController.isDownloadFailure(phase: .failed(version: "1.1.0")))
        // 2026-09-20 补的两态：**尤其 `.checking`** —— 用户点「检查更新」之后、
        // Sparkle 还没答的那几秒，`showUpdaterError` 是可能到的（feed 拿不到）。
        // 若被算成「下载失败」，界面会写「1.1.0 下载失败」—— 而**根本还没开始下载**。
        #expect(
            !UpdateController.isDownloadFailure(phase: .checking),
            "「正在检查」被算成「下载失败」了 —— 那一刻还没开始下载，文案会凭空冒出「%@ 下载失败」")
        #expect(
            !UpdateController.isDownloadFailure(phase: .locationBlocked),
            "「位置不允许更新」被算成「下载失败」了 —— 它不是网络问题，重试在只读卷上必然再失败（§8.94）")
    }

    /// **「位置不允许更新」的判定**：域 + 码，**单测写字面量**。
    ///
    /// ⚠️ 这里**故意不引 `SUError.runningFromDiskImageError`**：实现引符号、测试写字面量，
    /// 两边才**不同源**。两边都引符号就是「拿常量跟自己比」—— Sparkle 哪天把 `1003`
    /// 改成别的数字，这条断言**照样绿**（§8.95.7 记过这个坑）。
    ///
    /// 反例与正例**同样重要**：只测正例的话，把判据写成 `return true` 也能过，
    /// 而那会把一次普通网络失败说成「请把应用拷到『应用程序』文件夹」。
    ///
    /// 两个码都在 Sparkle 源码里**写死**（`SUErrors.h:43` / `:45`），域是 `SUConstants.m:53`
    /// —— 读源码就是证据，不需要真机验证（§8.95.7 逐行对过）。
    @Test func 位置不允许更新的判定按域与码分档() {
        func sparkleError(_ code: Int) -> NSError {
            NSError(domain: "SUSparkleErrorDomain", code: code)
        }

        #expect(
            UpdateController.isUpdateLocationBlocked(sparkleError(1003)),
            """
            只读卷（SURunningFromDiskImageError = 1003）没被判出来 ——
            用户从 dmg 挂载卷里直接双击就掉进「已是最新版本」，而 Sparkle 连 appcast 都没去取。
            """)
        #expect(
            UpdateController.isUpdateLocationBlocked(sparkleError(1005)),
            """
            App Translocation（SURunningTranslocated = 1005）没被判出来 ——
            从「下载」文件夹直接双击走的就是这条（Gatekeeper 把 app 挪到只读随机路径）。
            """)

        // 域对、码不对 ⇒ 不是这一态（别的 Sparkle 错误有自己的出口）。
        #expect(
            !UpdateController.isUpdateLocationBlocked(sparkleError(1000)),
            "别的 Sparkle 错误码被误判成「位置不允许更新」—— 那会把一次普通失败说成「请把应用拷到『应用程序』文件夹」")
        // 码对、域不对 ⇒ 也不是（别的框架恰好也用 1003 时不该被我们认领）。
        #expect(
            !UpdateController.isUpdateLocationBlocked(NSError(domain: "SomeOtherDomain", code: 1003)),
            "域没对上却按码认领了 —— 判域存在的意义就是防这个")
    }

    /// **「正在检查」与「位置不允许更新」两态不给按钮** —— 而这条只有读源码才钉得住。
    ///
    /// 两态各自的理由都写在 `SettingsView` 的注释里：`.checking` 时 Sparkle 正跑着
    /// （点「检查更新」只会闪一下），`.locationBlocked` 时「重试」在只读卷上**必然再失败**。
    /// 共同点：**给按钮就等于给一个点了没反应的东西**（同 `.ready` 那条判据）。
    ///
    /// ⚠️ **为什么必须钉**：把 `EmptyView()` 换成 `retryUpdateButton` **编译照过、
    /// 别的断言也不会红**（高度不变、优先级不变）—— 症状是用户点一下没反应，
    /// 与「功能坏了」逐字相同。
    ///
    /// ⚠️ **设计稿没有这两帧**（「仍开着」第 40 行）：所以「照设计稿改实现」这条路
    /// **指不到它们** —— 只能靠这条守卫。这也是它比一般守卫更该有的原因。
    ///
    /// ⚠️ 用的是 `caseBlock`，而 `.locationBlocked` 是那个 `switch` 的**最后一支**
    /// —— `caseBlock` 因此需要两个候选 stop（2026-09-20 修，见它的说明）。
    @Test func 正在检查与位置受限两态都不给按钮() throws {
        let source = try contents("Sources/Views/SettingsView.swift")

        for (label, header) in [
            ("正在检查", "case .checking:"),
            ("位置不允许更新", "case .locationBlocked:"),
        ] {
            let block = codeOnly(try caseBlock(header, in: source))
            #expect(
                block.contains("EmptyView()"),
                """
                `\(label)` 那一支的 control 不是 `EmptyView()` —— 它必须是「什么都不给」。实得：
                \(block)
                """)
            #expect(
                !block.contains("Button"),
                """
                `\(label)` 那一支出现了按钮。两态都不该有按钮：
                「正在检查」时 Sparkle 正跑着（点了只会闪一下）；
                「位置不允许更新」时「重试」在只读卷上**必然再失败**。
                给一个点了没反应的按钮，与「功能坏了」长得一模一样。实得：
                \(block)
                """)
            #expect(
                block.contains("description:"),
                """
                `\(label)` 那一支少了第二行（`description:`）—— 面板是固定高度，
                其余各态都有第二行，只有 label 会比别态矮 14.8pt（§8.82）。实得：
                \(block)
                """)
        }
    }

    /// **「下载失败」这一态必须有生产者，而且接线断掉时这条会红。**
    ///
    /// 2026-09-18 实扫发现：`UpdateUserDriver` 调用了**除 `driverDidFailDownload` 以外**
    /// 的每一个 `driverDid*` —— 于是下载出错时流程落进 `driverDidReset()` → `phase = .idle`，
    /// 表现是「进度条无声消失」：**与「下载完成了」长得一模一样**，
    /// 用户既不知道失败了、也没有重试入口，而设计稿给这一态配的整行（文案 + 「重试」）
    /// 永远画不出来。三处都要钉：
    ///
    /// ① `ensureUpdater()` 必须把 `self` 交给 Sparkle 当 delegate
    ///   （原来传的是 `nil`，等于主动放弃 `updater:failedToDownloadUpdate:error:`）；
    /// ② `showUpdaterError` 必须按「是不是正在下载」分流，而不是无条件 `driverDidReset()`；
    /// ③ **选择器要在运行时真的存在** —— 见下一条测试。
    @Test func 下载失败必须真的接到界面那一态() throws {
        let controllerSource = try contents("Sources/Services/UpdateController.swift")
        let ensureBody = codeOnly(try functionBody("private func ensureUpdater()", in: controllerSource))

        #expect(
            ensureBody.contains("delegate: self"),
            """
            SPUUpdater 的 delegate 不是 self。
            下载失败这件事 Sparkle 同时走两条路：user driver 的 showUpdaterError 与
            delegate 的 updater:failedToDownloadUpdate:error:。delegate 给 nil 就等于
            主动放弃后者，而它才是文档上写明的「下载失败」信号。
            """
        )
        #expect(
            !ensureBody.contains("delegate: nil"),
            "delegate 又变回 nil 了 —— 见上一条说明。"
        )

        let driverSource = try contents("Sources/Services/UpdateUserDriver.swift")
        let errorBody = codeOnly(try functionBody("func showUpdaterError(", in: driverSource))

        #expect(
            errorBody.contains("isDownloadFailure(phase:"),
            """
            showUpdaterError 没有按「是不是正在下载」分流。
            不分流的话任何错误（feed 拿不到、签名不匹配…）都落进 driverDidReset()，
            「下载失败」这一态就永远没有生产者。
            """
        )
        #expect(
            errorBody.contains("driverDidFailDownload(version:"),
            """
            showUpdaterError 里没有调 driverDidFailDownload —— 下载失败这一态又变成孤儿了。
            这正是 2026-09-18 实扫查出来的那个 bug：它当时全仓库只有定义、没有任何调用点。
            """
        )
    }

    /// 钉 `failedToDownloadUpdate` 方法体的关键副作用（§8.84）。
    ///
    /// **为什么**：上一条钉的是 user driver 那条路（`showUpdaterError`），
    /// 这一条钉 **delegate 那条路**（`failedToDownloadUpdate`）。
    /// 两条路**谁先到**是 §8.47.6 的「未核实」项（2026-09-19 登记；SPEC 第 10 行）—— 钉住任意一条**不等于**钉住另一条：
    /// 「只钉 user driver」⇒ 真机只走 delegate 那条路的话**又没生产者**，
    /// 「只钉 delegate」⇒ 同理。两条都接、且都钉，才不依赖那个假设。
    ///
    /// ⚠️ 这条**没有行为测试**（§8.83.4 第 33 行）：需要构造 `SPUUpdater` 实例，
    /// 项目里 0 处构造。能做的只有**源码文本守卫** —— 即 §8.83.4 第三选项
    /// 「**承认做不了**而把现有监督守得更严」。变异验证见 §8.84.2。
    @Test func failedToDownloadUpdate必须真的接通delegate那条路() throws {
        let source = try contents("Sources/Services/UpdateController.swift")
        let body = codeOnly(
            try functionBody(
                "func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error)",
                in: source))

        #expect(
            body.contains("driverDidFailDownload(version: item.displayVersionString)"),
            """
            `failedToDownloadUpdate` 没有把下载失败传到 `.failed` 那一态。
            delegate 那条路如果真到了（§8.47.6「未核实」），**这一态就画不出来**，
            表现与「没实现这个钩子」逐字相同。实得：
            \(body)
            """)
        #expect(
            body.contains("Self.logger.error"),
            """
            error 被吞了 —— 用户不知道为什么失败，「重试」按钮按下去还是会失败。
            `error` 进来**就该往日志里写**。实得：
            \(body)
            """)
        // 防一种绕过：把整个方法体 catch 起来静默掉。
        // （`SPUUpdaterDelegate` 直接传 `Error`，不抛，不需要 catch —— 加 catch
        // 是想吞掉，那一律不准。）
        #expect(
            !body.contains("catch"),
            """
            delegate 直接拿 `Error`，不该自己 try/catch 吞掉。实得：
            \(body)
            """)
    }

    /// **选择器签名要与 ObjC 侧逐字对上，而写错只出 warning、不会编译失败。**
    ///
    /// `SPUUpdaterDelegate` 的方法是 `@objc optional`：签名差一个词（比如把
    /// `failedToDownloadUpdate` 写成 `failedToDownloadUpdates`、或参数类型写成 `SUAppcastItem?`），
    /// 编译器只给一条 `nearly matches optional requirement` 的 **warning** ——
    /// 而 warning 在构建日志里与噪音没有区别。后果是方法还在、却永远不会被调：
    /// 与「这个方法根本没写」逐字相同。这正是这次要修的病，所以用 `responds(to:)`
    /// 问**运行时**，而不是读源码猜。（实测有牙：改一个字母即红。）
    ///
    /// 只问「在不在」是**有意的**：能问到，就说明它作为 ObjC 选择器被导出，
    /// 说明它确实匹配上了协议里那条要求（否则 Swift 不会给它 `@objc`）。
    @MainActor
    @Test func 下载失败的delegate选择器真的被导出了() {
        #expect(
            UpdateController.shared.responds(
                to: NSSelectorFromString("updater:failedToDownloadUpdate:error:")),
            """
            UpdateController 没有导出 updater:failedToDownloadUpdate:error:。
            多半是签名与 SPUUpdaterDelegate 对不上了（少一个词、参数类型不精确）——
            这种错**不会编译失败**，只会让方法静默不被调用，而表现与「没有这个方法」逐字相同。
            """
        )
    }

    // MARK: - 自动更新那条路：唯一的落点是 delegate（§8.80）

    /// **自动更新开着时，user driver 一个回调都收不到** —— 于是 delegate 的
    /// `willInstallUpdateOnQuit` 是那条路上**唯一**的落点。
    ///
    /// 2026-09-19 读 Sparkle 源码确认（§8.80）：`SPUUpdater.m:622` 在
    /// `automaticallyDownloadsUpdates == YES` 时选 `SPUAutomaticUpdateDriver`，
    /// 而它**不经过** `SPUUIBasedUpdateDriver` —— 后者是 `showUpdateFound` /
    /// `showDownloadInitiated` / `showDownloadDidReceiveData` /
    /// `showReadyToInstallAndRelaunch` 这四个回调在全库**唯一**的调用方
    /// （`SPUUIBasedUpdateDriver.m:244/359/369/420`）。
    ///
    /// 不实现这个钩子的话，自动那条路上 `phase` 会一直停在 `.idle`，设置行于是显示
    /// 「已是最新版本 · 上次检查：…」—— **而新版本其实已经下载好、正等着退出时装**。
    /// 这正是设计稿 C 段开头那条自洽性判据要防的反例（它只防了「已是最新 + 弹窗」）。
    ///
    /// 这条读源码（同 `下载失败必须真的接到界面那一态` 的理由：接线断掉**不会编译失败、
    /// 不会崩、也不会有别的断言变红**，只有真机等一整天再退出才看得出来）。
    @Test func 自动更新那条路唯一的落点是delegate() throws {
        let source = try contents("Sources/Services/UpdateController.swift")
        let body = codeOnly(
            try functionBody("willInstallUpdateOnQuit item: SUAppcastItem,", in: source))

        #expect(
            body.contains("driverIsReady(version:"),
            """
            willInstallUpdateOnQuit 没有把状态推进到「已就绪」。
            自动那条路上这是**唯一**会到的落点 —— 不推进的话设置行会一直显示
            「已是最新版本」，而更新其实已经下载好、正等着退出时装。
            """
        )
        #expect(
            body.contains("PendingUpdate(appcastItem: item)"),
            "必须把条目翻成 PendingUpdate —— 否则「已就绪」只有版本号，行上的说明是空的"
        )
        #expect(
            body.contains("immediateInstallHandler()"),
            """
            拿到 immediateInstallationBlock 却没调它 —— 那设置行的「立即重启」
            就是个点了没反应的按钮（设计稿点名不许：「先画上『后台更新并重启』再补实现，
            用户会点到一个什么都不做的按钮」）。
            """
        )
        #expect(
            body.contains("return true"),
            """
            willInstallUpdateOnQuit 必须返回 true。
            返回 false 时 Sparkle 会 abortUpdate，而 immediateInstallationBlock
            **只在返回 true 时才可用**（`SPUUpdaterDelegate.h:437`）——
            界面上于是留下一个永远点不动的「立即重启」。
            """
        )
        #expect(
            !body.contains("return false"),
            "这条路上没有该返回 false 的分支 —— 见上一条说明。"
        )
    }

    /// **选择器要与 ObjC 侧逐字对上** —— 差一个词只出 warning、不会编译失败。
    ///
    /// 与 `下载失败的delegate选择器真的被导出了` 同一条判据、同一个理由：
    /// `@objc optional` 的方法拼错时，编译器只给一条
    /// `nearly matches optional requirement` 的 warning，而 warning 在构建日志里
    /// 与噪音没有区别。后果是方法还在、却**永远不会被调**：与「根本没写」逐字相同。
    /// 用 `responds(to:)` 问运行时，而不是读源码猜。
    @MainActor
    @Test func 退出时安装的delegate选择器真的被导出了() {
        #expect(
            UpdateController.shared.responds(
                to: NSSelectorFromString("updater:willInstallUpdateOnQuit:immediateInstallationBlock:")),
            """
            UpdateController 没有导出 updater:willInstallUpdateOnQuit:immediateInstallationBlock:。
            多半是签名与 SPUUpdaterDelegate 对不上了（少一个词、参数类型不精确）——
            这种错**不会编译失败**，只会让方法静默不被调用。
            而它是自动更新开着时**唯一**会到的落点：不导出 ⇒ 设置行永远显示「已是最新版本」。
            """
        )
    }

    /// 「立即重启」把控制交回**那条路给的东西**，而且**只交一次**。
    ///
    /// 自动那条路交回的是 `immediateInstallationBlock`（`() -> Void`），弹窗那条交回的是
    /// `.install` choice —— 两条路共用 `installReadyUpdate()` 一处实现（见 `readyReply`）。
    /// 这条从外部驱动：`driverIsReady` 是内部方法，传一个计数闭包进去，
    /// 看它会不会被调、被调几次。
    ///
    /// **整段是同步的、且都在主 actor 上**（没有 `await` ⇒ 不会与别的用例交错），
    /// 结束时立刻还原成 `.idle` —— `rowState` 读 `phase`，留着会污染别的断言。
    @MainActor
    @Test func 立即重启把控制交回那个闭包且只交一次() {
        let controller = UpdateController.shared
        defer { controller.driverDidReset() }

        var calls = 0
        controller.driverIsReady(version: "1.1.0") { _ in calls += 1 }
        #expect(controller.phase == .ready(version: "1.1.0"))

        controller.installReadyUpdate()
        #expect(
            calls == 1,
            "「立即重启」必须真的把控制交回去 —— 自动那条路交回的就是 immediateInstallationBlock"
        )

        controller.installReadyUpdate()
        #expect(calls == 1, "第二次点不该重复回答：回答前必须清空 readyReply")
    }

    /// `SUAppcastItem` → `PendingUpdate` 的翻译**只有一处**。
    ///
    /// 同一个条目会从**两条路**到达应用：user driver 的 `showUpdateFound`（弹窗那条）
    /// 与 delegate 的 `willInstallUpdateOnQuit`（自动那条）。两处各写一遍的话，
    /// 「显示版本号 / 体积 / 更新条目」这些字段迟早会在两条路上不一致 ——
    /// 而两条路各画各的，**没有任何东西会红**：用户看到的只是「自动更新时弹窗里少了体积」
    /// 这种没人会去比对的现象。
    ///
    /// ⚠️ **例外只有一处、且必须登记**：`DiskEjectorApp.swift` 里 `--preview-update` 的
    /// 样本是**逐个字段手写**的 —— 它**故意**不来自 appcast，因为走查图要与设计稿并排比，
    /// 样本必须逐字取自设计稿 A 段。这条断言把它钉成**唯一的**例外：
    /// 再冒出一处手写构造就红。
    @Test func appcast条目的翻译只有一处() throws {
        let sourcesRoot = repoRoot.appendingPathComponent("Sources")
        guard
            let walker = FileManager.default.enumerator(
                at: sourcesRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(sourcesRoot.path)")
            return
        }

        var fileCount = 0
        var hits: [(file: String, snippet: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            fileCount += 1
            let lines = codeOnly(try String(contentsOf: url, encoding: .utf8))
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where line.contains("PendingUpdate(") {
                // 连取后两行：构造点的实参常写在下一行（`--preview-update` 那处就是），
                // 只留一行的话看不出它到底传了什么。
                let snippet = lines[index..<min(index + 3, lines.count)]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ⏎ ")
                hits.append((url.lastPathComponent, snippet))
            }
        }

        // 范围锚：路径写错时 fileCount 会掉到 0，下面的断言于是变成空转（假绿）。
        #expect(fileCount >= 30, "只扫到 \(fileCount) 个 .swift —— 路径错了（假绿）")

        let fromAppcast = hits.filter { $0.snippet.contains("appcastItem:") }
        let handWritten = hits.filter { !$0.snippet.contains("appcastItem:") }

        #expect(
            fromAppcast.count == 2,
            """
            从 appcast 条目构造 PendingUpdate 的地方有 \(fromAppcast.count) 处（期望 2）。
            两条路（user driver 的 showUpdateFound / delegate 的 willInstallUpdateOnQuit）
            必须都走 `PendingUpdate(appcastItem:)`，否则字段会静默分叉。实得：
            \(hits.map { "\($0.file): \($0.snippet)" }.joined(separator: "\n"))
            """
        )
        #expect(
            handWritten.count == 1 && handWritten[0].file == "DiskEjectorApp.swift"
                && handWritten[0].snippet.contains("version: \"1.1.0\""),
            """
            逐个字段手写 PendingUpdate 的地方不是「--preview-update 的设计稿样本」那一处。
            从 appcast 来的数据一律走 PendingUpdate(appcastItem:)；那个样本是**故意**手写的
            （走查图要与设计稿并排比，样本必须逐字取自设计稿 A 段）。实得：
            \(handWritten.map { "\($0.file): \($0.snippet)" }.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 自动那条路的「下载中」：唯一来源是 delegate（§8.81）

    /// 自动那条路上「后台下载中」那一态只能由 delegate 的 `willDownloadUpdate` 设。
    ///
    /// 钉三件事：① 分流判据是 **`phase == .idle`**（= user driver 一声没吭 ⇒ 自动那条路，
    /// 见 `UpdateController` 里那段顺序论证）；② 还要判**开关开着**；
    /// ③ 百分比必须是 **`nil`**，不能猜成 `0` —— 那条路没有进度回调，
    /// 画一条停在 0% 的进度条比不画更让人怀疑。
    ///
    /// ⚠️ **2026-09-20 改写（§8.83）**：判据**抽到纯函数** ``shouldEnterBackgroundDownload(phase:autoDownloads:)``，
    /// 守卫从「读 willDownloadUpdate 体的判据文本」改成「读**两个体** —— 纯函数体钉判据、
    /// willDownloadUpdate 体钉**调用关系**」。两个一起钉才是真守卫：单钉任一个都是没牙的
    /// —— 例如只钉 willDownloadUpdate 体里的 `shouldEnterBackgroundDownload(…)` 调用，但
    /// 纯函数体的判据被改成「永远返回 true」，测试**照样绿**。
    @Test func 自动那条路的下载开始也由delegate送达() throws {
        let source = try contents("Sources/Services/UpdateController.swift")

        // ① 纯函数体：判据的两半（idle + autoDownloads）
        let pureFn = codeOnly(
            try functionBody(
                "shouldEnterBackgroundDownload(\n        phase: UpdatePhase, autoDownloads: Bool",
                in: source))
        #expect(
            pureFn.contains("guard case .idle = phase"),
            """
            分流判据不见了。自动那条路上 user driver **一条回调都不发**（§8.80），
            所以「`phase` 还是 `.idle`」就是「走的是自动那条路」——
            换成别的判据（例如另存一个「这次是后台检查」的位）会与真实情况脱节。实得：
            \(pureFn)
            """)
        #expect(
            pureFn.contains("autoDownloads"),
            """
            少了「开关开着」这一半：这一态要表达的是「**自动下载**正在进行」，
            而 `phase == .idle` 只说「没人说过话」。判据要与 `SPUUpdater.m:622`
            选驱动时用的是**同一个属性**。实得：
            \(pureFn)
            """)

        // ② willDownloadUpdate 体：调了纯函数 + 传了开关值 + 不猜 0
        let body = codeOnly(try functionBody("willDownloadUpdate item: SUAppcastItem,", in: source))
        #expect(
            body.contains("shouldEnterBackgroundDownload"),
            """
            willDownloadUpdate 没调纯函数（§8.83）。抽纯函数的目的是让它**真被调**，
            而不是把判据藏在方法体里 —— 留在原位就是「源码文本守卫」的原状，
            行为断言还是进不来。实得：
            \(body)
            """)
        #expect(
            body.contains("updater.automaticallyDownloadsUpdates"),
            """
            纯函数没拿到开关值。实得：
            \(body)
            """)
        #expect(
            body.contains("fraction: nil"),
            """
            百分比不是 `nil` 了。这条路**没有任何进度回调**
            （`showDownloadDidReceiveData` 全库只有 `SPUUIBasedUpdateDriver.m:369` 一个调用方），
            猜一个数字出来就是设计稿点名不许的「编出来的百分比」。实得：
            \(body)
            """)
        #expect(
            !body.contains("fraction: 0"),
            """
            百分比被写成了 `0` —— 那会让设置行画出一条**停在 0% 的进度条**，
            用户会盯着它判断「是不是卡住了」。`nil`（不知道）与 `0`（真的一格都没下完）
            必须是两种状态。实得：
            \(body)
            """)

        // 同一判据也适用于「开关开着 + 用户手动点检查」那条路
        // （`showUpdateFound` → `driverDidFindUpdate(autoDownloads: true)`）：
        // **那一刻下载同样还没开始**，所以也必须是 `nil`；真进度由
        // `driverDidStartDownload`（`showDownloadInitiated`）补上，
        // 而 `shouldPublishProgress(from: nil, …)` 恒为真 ⇒ 第一格一定发得出去。
        let foundBody = codeOnly(try functionBody("func driverDidFindUpdate(", in: source))
        #expect(
            foundBody.contains("fraction: nil"),
            "「开关开着 + 手动检查」那条路把百分比猜成了别的值 —— 那一刻下载还没开始。实得：\n\(foundBody)")
        #expect(
            !foundBody.contains("fraction: 0"),
            "「开关开着 + 手动检查」那条路又把百分比写成了 `0`（会画出一条停在 0% 的进度条）。实得：\n\(foundBody)")
    }

    /// `willDownloadUpdate` 的选择器必须与 ObjC 侧逐字对上。
    ///
    /// **与另两条同一个理由**（`failedToDownloadUpdate` / `willInstallUpdateOnQuit`）：
    /// 拼错一个字母**编译照过、测试全绿、什么都不崩**，编译器只给一条
    /// `nearly matches optional requirement` 的 warning —— 而 warning 在构建日志里
    /// 和噪音没有区别。真正的后果是方法还在、却永远不会被调：
    /// 与「这个方法根本没写」逐字相同（那条路于是又回到「设置行说已是最新」）。
    @MainActor
    @Test func 下载开始的delegate选择器真的被导出了() {
        #expect(
            UpdateController.shared.responds(
                to: NSSelectorFromString("updater:willDownloadUpdate:withRequest:")),
            """
            UpdateController 没有导出 updater:willDownloadUpdate:withRequest: ——
            选择器拼错时编译器只给 warning，运行期表现是「这一态永远不出现」。
            """)
    }

    /// `willDownloadUpdate` 的分流判据 **行为测试**（§8.83）。
    ///
    /// **为什么必须测它**：判据靠的是**顺序论证**（user driver 一声没吭 ⇒ 一定是
    /// 自动那条路）—— 而**真机根本构造不出**「`phase` 不是 `.idle` 又走到
    /// `willDownloadUpdate`」的场景（`showUpdateFound` 永远先到，§8.81.4）。
    /// 所以判据抽出纯函数**不是性能优化，是为了让断言能跑到** —— 顺推要测，
    /// **反向也要测**（防止有人把判据写成「只判开关」）。
    @Test func shouldEnterBackgroundDownload的真值表() {
        // 顺推：自动那条路（idle + 开）⇒ 进
        #expect(
            UpdateController.shouldEnterBackgroundDownload(
                phase: .idle, autoDownloads: true),
            "idle + 自动开 ⇒ 应进")

        // 反向：弹窗那条路（phase 已被 showUpdateFound 设过）⇒ 挡掉
        #expect(
            !UpdateController.shouldEnterBackgroundDownload(
                phase: .found(version: "1.1.0"), autoDownloads: true),
            "found + 自动开 ⇒ 应挡（弹窗那条路）")
        // 反向：哪怕 phase 已经是 downloading/ready/failed，也得挡掉
        #expect(
            !UpdateController.shouldEnterBackgroundDownload(
                phase: .downloading(version: "1.1.0", fraction: 0.42), autoDownloads: true),
            "downloading + 自动开 ⇒ 应挡（已经在下）")
        #expect(
            !UpdateController.shouldEnterBackgroundDownload(
                phase: .ready(version: "1.1.0"), autoDownloads: true),
            "ready + 自动开 ⇒ 应挡（已就绪）")
        #expect(
            !UpdateController.shouldEnterBackgroundDownload(
                phase: .failed(version: "1.1.0"), autoDownloads: true),
            "failed + 自动开 ⇒ 应挡（已失败）")

        // 反向：开关关着 ⇒ 无论 phase 是什么都不进
        #expect(
            !UpdateController.shouldEnterBackgroundDownload(
                phase: .idle, autoDownloads: false),
            "idle + 自动关 ⇒ 应挡")
        #expect(
            !UpdateController.shouldEnterBackgroundDownload(
                phase: .ready(version: "1.1.0"), autoDownloads: false),
            "ready + 自动关 ⇒ 应挡")
    }

    /// **「百分比未知」与「0%」必须是两种状态。**
    ///
    /// 这条是本轮的核心判据：两者如果相等，自动那条路就会画出停在 0% 的进度条 ——
    /// 而那个 0% 是**编的**（设计稿 B3：「百分比是真的，ETA 是编的」的另一面）。
    @Test func 百分比未知与零是两种状态() {
        #expect(
            UpdatePhase.downloading(version: "1.1.0", fraction: nil)
                != .downloading(version: "1.1.0", fraction: 0),
            "「不知道下了多少」与「一格都没下完」被当成同一态了 —— 界面于是只能画 0%")

        // 行态原样透传，不把 `nil` 折成 `0`。
        #expect(
            UpdateController.rowState(
                phase: .downloading(version: "1.1.0", fraction: nil),
                skippedVersion: nil, lastCheck: nil)
                == .downloading(version: "1.1.0", fraction: nil),
            "`rowState` 把 `fraction: nil` 折成了别的值 —— 视图再也分不出「未知」")

        // 第一格进度**一定**发得出去，否则进度条永远不出现
        // （自动那条路进来时是 `nil`，下一格才是真数值）。
        #expect(
            UpdateController.shouldPublishProgress(from: nil, to: 0),
            "从「未知」到 0% 被去重掉了 —— 进度条会一直不出现")
        #expect(
            UpdateController.shouldPublishProgress(from: nil, to: 0.42),
            "从「未知」到 42% 被去重掉了")
    }

    /// 视图侧：百分比未知时**不画进度条、也不给「取消」**，且**说同一句话**。
    ///
    /// 为什么必须守这一段：`fraction` 变成可选之后，视图里只要漏掉那个分支，
    /// 编译**照样过**（`if let` 少写一个 `else` 在 SwiftUI 里是合法的）——
    /// 而后果是「自动那条路什么都不画」，与「那一态还没实现」逐字相同。
    @Test func 未知百分比那一态不画进度条也不给取消() throws {
        let source = try contents("Sources/Views/SettingsView.swift")
        let block = codeOnly(
            try caseBlock("case .downloading(let version, let fraction):", in: source))

        #expect(
            block.contains("if let fraction {"),
            "`.downloading` 那一支没有按 `fraction` 分岔 —— 两种外观被画成一种。实得：\n\(block)")
        #expect(
            block.contains("progress: fraction"),
            "有百分比时不画进度条了（手动检查那条路会看不到进度）。实得：\n\(block)")

        // `else` 那一半：不许有进度条、不许有按钮。
        let elsePart = block.components(separatedBy: "} else {").last ?? ""
        #expect(
            !elsePart.contains("progress:"),
            """
            百分比未知时仍然画了进度条 —— 它会停在 0%（`SettingsProgressLine` 收到 nil
            是画不出来的，所以这一支根本不该有 `progress:`）。实得：
            \(elsePart)
            """)
        #expect(
            elsePart.contains("EmptyView()"),
            """
            百分比未知时给了按钮。那条路**不提供取消入口**
            （`showDownloadInitiatedWithCancellation:` 由 `SPUUIBasedUpdateDriver` 发出），
            给一个点了没反应的「取消」正是设计稿点名不许的。实得：
            \(elsePart)
            """)
        #expect(
            elsePart.contains("updateDownloadingFormat"),
            "两种外观说的不是同一句话 —— 同一件事写在两处，迟早分叉。实得：\n\(elsePart)")
    }

    /// 设计稿 3b 那一帧与实现的「说明行」必须**用同一个文案键**（§8.82）。
    ///
    /// **为什么必须守这一条**：那一态的「第二行」不是装饰 —— 面板是**固定高度**，
    /// 3b 只有一句话时实测比别态**矮 14.8pt**（切到它时底部多出一条空白带）。
    /// 于是这一行是**等高的一部分**，而它写在两个地方：设计稿画着它、实现读着它。
    ///
    /// ⚠️ **实测过这条守卫的必要性**（变异 M238）：把设计稿 3b 的 `.sline__desc`
    /// 整个删掉，**44 条设计稿守卫全绿、实现侧「各态一样高」也全绿** ——
    /// 因为实现没跟着删，它自己并不矮。**两边从此分叉而 CI 毫无反应**，
    /// 直到有人照着设计稿改实现，那时才矮下去（而那时已经没人记得为什么）。
    /// ⇒ 这正是「A 与 B 必须一致要配守卫」：两边各写一句「记得同步」守不住
    /// （面板尺寸就是这样分叉了一整轮，见 §8.43）。
    ///
    /// 判据取**键名同源**，不取文案内容：文案会改，键名是两边唯一的接缝。
    @Test func 设计稿3b那一帧与实现用同一个说明键() throws {
        let html = try contents("DiskEjector-UI-Design/v2/screens/08-update.html")
        let frame = try #require(
            slice(after: "3b · 后台下载中", upTo: "<!-- B4", in: html),
            "找不到 3b 那一帧 —— 改了帧标题或注释就要同步这条断言（口径失效必须是红的）")

        // 设计稿侧：那一帧里的说明行挂的是哪个键。
        let draftKey = try #require(
            slice(after: "class=\"sline__desc\" data-i18n=\"", upTo: "\"", in: frame),
            """
            3b 那一帧里没有 `.sline__desc`。那一态只有一句话会比别态**矮 14.8pt**
            （面板固定高度 ⇒ 切到它时底部多出一条空白带），所以这一行不能删。实得：
            \(frame)
            """)

        // 实现侧：`.downloading` 那一支的 else 半边用的是哪个键。
        let view = try contents("Sources/Views/SettingsView.swift")
        let block = codeOnly(
            try caseBlock("case .downloading(let version, let fraction):", in: view))
        let implKey = try #require(
            slice(after: "description: L10n.tr(.", upTo: ")", in: block),
            """
            `.downloading` 那一支没有 `description:` —— 百分比未知时既没有进度条也没有说明，
            实测矮 14.8pt。实得：
            \(block)
            """)

        #expect(
            draftKey == implKey,
            """
            设计稿 3b 画的说明键是 `\(draftKey)`，而实现用的是 `\(implKey)` ——
            两边各写一句「记得同步」守不住（面板尺寸就是这样分叉了一整轮）。
            """)
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
    ///
    /// ⚠️ **两侧必须钉在同一个语言下**（2026-09-20 修）：左边 `AppLanguage.system.displayName`
    /// 走的是 `L10n.tr` 的**默认参数** `Locale.current`，而原来的右边 `designText` 钉的是设计稿语言
    /// ⇒ 不钉左边的话，这条断言的结果由**跑测试那台机器的系统语言**决定：
    /// CI 是 `en_US` ⇒ 左边 `"Follow System"`、右边 `"跟随系统"`，**必然不等**。
    /// 实测：CI **连续 7 次推送全红**都红在这一行（`UpdateSettingsTests.swift:1104`），
    /// 而本地（中文机器）一直绿 —— 典型「本地绿、CI 红」。
    /// ⚠️ **这里故意不写 `TestLanguage.with(TestLanguage.design)`**：那个常量是「**设计稿**的语言」，
    /// 只该给「断言设计稿数字」的用例用（见它的文档注释）。本条断言的是**产品本地化表**，
    /// 与设计稿无关 ⇒ 写死 `"zh-Hans"` / `"en"` 两个**产品语言**。
    /// 附带好处：这条测试对 `design` 常量**不变** —— 用 `design = "en"` 复现 CI 的那套实验
    /// **不会**把它一起翻掉（那套实验只对「按中文实测的设计稿数字」那类断言有效；
    /// 本条当初那个 bug 是「左边**没钉**」而不是「钉错了语言」，两回事）。
    ///
    /// ⚠️ 钉**两个**语言而不是一个：只钉中文的话，「**必须本地化**」这半条其实**没被验到**
    /// —— 把 `displayName` 写成常量中文串也照样绿。
    @Test func 具体语言用该语言自己的写法而跟随系统才本地化() {
        // endonym：任何界面语言下都写自己的名字，**不随界面语言变**。
        #expect(AppLanguage.zhHans.displayName == "简体中文")
        #expect(AppLanguage.en.displayName == "English")
        #expect(AppLanguage.zhHant.displayName == "繁體中文")

        // 「跟随系统」是产品文案，必须本地化 —— 它不是语言的名字。
        let zh = TestLanguage.with("zh-Hans") { AppLanguage.system.displayName }
        let en = TestLanguage.with("en") { AppLanguage.system.displayName }
        // 前置断言：先把「翻译缺失 / 钉失效」与「文案写错了」分开 ——
        // 两者在下面两条上长得一样，但要求的处置完全相反（一个是查 `L10n`，一个是改文案）。
        #expect(
            zh != en,
            "中英下「跟随系统」应当不同，实得都是「\(zh)」—— 英文翻译缺失，或 `forcedLocale` 钉已失效")
        #expect(zh == "跟随系统", "中文下应当是「跟随系统」，实得「\(zh)」")
        #expect(en == "Follow System", "英文下应当是 \"Follow System\"，实得「\(en)」")
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

    // MARK: - 下载停摆兜底（DESIGN-SPEC 第 34 行）

    /// 没进入「无百分比的下载中」时，判定**必须恒假**。
    @Test func 停摆判定在没进入该态时恒为假() {
        #expect(
            UpdateController.isDownloadStalled(since: nil, now: Date()) == false,
            "没有计时起点时必须恒假 —— 否则会把「根本没在下载」误判成「下载停摆」")
    }

    /// 阈值边界：`>=` 而不是 `>` —— 松到「超过」会让边界那一档永远等不到。
    @Test func 停摆判定按阈值分档() throws {
        let t0 = try #require(
            Calendar.current.date(
                from: DateComponents(year: 2026, month: 9, day: 20, hour: 3, minute: 0)))
        let timeout: TimeInterval = 120
        #expect(
            UpdateController.isDownloadStalled(
                since: t0, now: t0.addingTimeInterval(119), timeout: timeout) == false)
        #expect(
            UpdateController.isDownloadStalled(
                since: t0, now: t0.addingTimeInterval(120), timeout: timeout) == true,
            "刚好到阈值就要判停摆")
        #expect(
            UpdateController.isDownloadStalled(
                since: t0, now: t0.addingTimeInterval(600), timeout: timeout) == true)
    }

    /// **接线守卫**：看门狗挂在 `phase` 的 `didSet` 上。
    ///
    /// 为什么必须钉：它不是在每个「设置 phase」的地方各调一次 —— 那种写法
    /// **漏一处就留下一个没有出口的态**，而那正是第 34 行的症状本身。
    /// 把 `didSet` 删掉之后这条会红，**而别处没有任何东西会报警**。
    ///
    /// ⚠️ 局限（如实记）：`phase` 是 `private(set)`，测试**造不出**「真的停摆 120 秒」
    /// 那个场景，所以这里守的是**纯函数 + 接线**，不是端到端行为。
    @Test func 停摆兜底挂在phase的didSet上() throws {
        let src = try contents("Sources/Services/UpdateController.swift")
        #expect(
            src.contains("didSet { syncStallWatch() }"),
            "`phase` 的 `didSet` 必须调 `syncStallWatch()`：漏一处就留下没有出口的态")
        #expect(
            src.contains("RunLoop.main.add(timer, forMode: .common)"),
            "定时器必须加到 `.common` —— 默认模式在菜单栏事件追踪期间不 firing，兜底会在最该生效的时候不生效")
        #expect(
            src.contains("Self.isDownloadStalled(since: stallSince, now: now)"),
            "`checkDownloadStall` 必须走那个纯函数（换成本地计算会让上面的判定测试失去意义）")
        #expect(
            src.contains("static let downloadStallTimeout: TimeInterval = 120"),
            "阈值必须是**具名常量**：它是设计决策（第 34 行），改一个数就能调")
    }
}
