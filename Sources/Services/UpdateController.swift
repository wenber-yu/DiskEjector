import AppKit
import Combine
import Foundation
import OSLog
import Sparkle

/// 更新这件事**当前进行到哪一步**。
///
/// **为什么不是一个布尔 / 一个「有没有新版本」标记**：设计稿 `08-update.html` 的 C 段
/// 是一张九行状态矩阵，其中「后台下载中」「已就绪」「下载失败」三种状态**都在
/// 「有新版本」之后**，布尔量装不下。
///
/// 更要紧的是：**没有生产者去推进的状态，在界面上与「已经支持了」长得一模一样** ——
/// 所以这里只列**真有代码会设置**的档位（生产者见 `UpdateUserDriver`）。
enum UpdatePhase: Equatable {
    /// 什么都没在进行（也包含「检查完发现是最新」「已跳过」「从未检查」）。
    case idle
    /// 发现新版本，等用户决定（弹窗开着，或用户按了 Esc 之后留在设置行上）。
    case found(version: String)
    /// 正在后台下载。
    case downloading(version: String, fraction: Double)
    /// 下载并校验完成，等重启安装。
    case ready(version: String)
    /// 下载失败。
    case failed(version: String)
}

/// 弹窗要展示的那一份「新版本说明」。
///
/// **为什么不直接从 `SUAppcastItem` 读**：那个对象只活在 `showUpdateFound` 那一次回调里，
/// 而用户可能过很久才点「查看更新」（甚至按 Esc 之后隔一天再回来）。
/// 存成值类型之后，弹窗在**任何时候**都能重建，不依赖 Sparkle 还留着那个 item。
struct PendingUpdate: Equatable {
    /// 用户看到的版本号（`CFBundleShortVersionString`，如 `1.1.0`）。
    let version: String
    /// 新版本的构建号（`CFBundleVersion`）。
    let newBuild: String?
    /// 当前版本（弹窗里「当前 x → y」的左半边）。
    let currentVersion: String
    let currentBuild: String?
    /// appcast 里的日期串（原样显示，不解析 —— appcast 写的是发布者给的字符串）。
    let date: String?
    /// 安装包字节数（0 表示 appcast 没写，此时不显示体积）。
    let sizeBytes: UInt64
    /// 本次更新条目（appcast 的 `<description>` 解析而来）。
    let notes: [String]
}

/// Sparkle 自更新的**唯一持有者**。
///
/// ## 为什么单开一个类，不塞进 `UpdateService`
///
/// `UpdateService` 是纯值 / 纯函数（渠道判定 + 拼 Releases 页地址），在单测进程里随便跑；
/// `SPUUpdater` 一创建就要读宿主 bundle 的真实身份、起会话、可能弹窗 —— 碰它就是碰运行时。
/// 分开之后单测可以继续断言前者，不被后者拖下水（同种拆法见 `DiskService` §8.31）。
///
/// ## 用 `SPUUpdater` 而不是 `SPUStandardUpdaterController`
///
/// `SPUStandardUpdaterController` 会自动往**应用的主菜单**里插「Check for Updates…」，
/// 而本应用的菜单栏是 `MainMenu.swift` 自己搭的 SwiftUI 菜单，没有传统 MainMenu.nib。
/// 控制器插不进东西（不崩，但也没效果），还会持有一份我们看不见的状态 ——
/// 于是直接用 `SPUUpdater`，入口由我们自己决定放哪。
///
/// ## 用自定义 `UpdateUserDriver` 而不是 `SPUStandardUserDriver`（2026-09-18）
///
/// 设计稿 `08-update.html` 要求的弹窗与标准弹窗不是一回事：标题带版本号、
/// **本次更新**清单、提示块、「跳过此版本」，以及操作区左边那个不占按钮的 Esc 出口。
/// 更要紧的是设计稿把「后台下载中」的**百分比**画在设置行上，而 Sparkle **只在
/// user driver 里**给下载进度（`showDownloadDidReceiveExpectedContentLength` /
/// `showDownloadDidReceiveData`）—— 走标准 driver 拿不到这两个回调。两者叠加，只能自己实现。
@MainActor
final class UpdateController: NSObject, ObservableObject {

    static let shared = UpdateController()

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "Update")

    private var updater: SPUUpdater?

    /// 必须强引用住：`SPUUpdater` 对 user driver 是**弱引用**，driver 一被释放，
    /// Sparkle 就没有 UI 可用了（下一次更新会静默什么都不显示）。
    private var driver: UpdateUserDriver?

    /// 上一次启动失败的原因（避免每次点按钮都重试一遍然后再次失败）。
    private var startError: String?

    /// 更新进行到哪一步。**设置面板与弹窗都读它**，不各自维护一份。
    @Published private(set) var phase: UpdatePhase = .idle

    /// 弹窗的内容（`showUpdateFound` 时填充）。
    private(set) var pendingUpdate: PendingUpdate?

    /// 「后台下载中」那行「取消」要调的东西。
    private var downloadCancellation: (() -> Void)?

    /// 「已就绪」状态下，Sparkle 等着我们回答的那个 reply。
    ///
    /// **为什么要攥着不马上回答**：设计稿 B4 说得很清楚 ——
    /// 「下载可以完全后台，但重启会关掉用户手上的一切」，所以
    /// **重启不自动做，只提供入口**。攥着 reply 意味着用户点「立即重启」时
    /// 我们能给出真正的 `.install`（Sparkle 会装完并重新拉起应用），
    /// 而不是「先 dismiss 再想办法把更新找回来」。
    ///
    /// ⚠️ **代价（已核实，不是猜的）**：`SPUUpdater` 的文档写明
    /// 「`checkForUpdates` does not do anything if there is a `sessionInProgress`」，
    /// 而攥着 reply 就等于会话没结束。所以处于「已就绪」时点「检查更新」是**没有反应**的 ——
    /// 这就是为什么这一态下设置行不再显示「检查更新」按钮（改显示「立即重启」），
    /// 否则就会出现「按钮点了没反应，而用户无从分辨原因」。
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?

    /// 「发现新版本」时弹窗要回答的那个 reply。
    private var alertReply: ((SPUUserUpdateChoice) -> Void)?

    private override init() { super.init() }

    // MARK: - 生命周期

    /// 创建并启动 updater（幂等；失败时记下原因，返回 `nil`）。
    ///
    /// **预览模式不建**：`--preview-*` 跑的是未签名的命令行产物，
    /// `Bundle.main` 不是合规的 app bundle，Sparkle 会为此报错 ——
    /// 而那句报错跟「更新能不能用」无关，只会污染自检输出（真机自检有 6 个场景要读输出）。
    private func ensureUpdater() -> SPUUpdater? {
        if let updater { return updater }
        if startError != nil { return nil }

        if AppDelegate.isPreviewRun {
            startError = "预览模式（--preview-*）"
            return nil
        }

        let driver = UpdateUserDriver(controller: self)
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            // **不能是 `nil`**：下载失败这件事 Sparkle 同时走两条路 ——
            // user driver 的 `showUpdaterError` 和 delegate 的
            // `updater(_:failedToDownloadUpdate:error:)`。delegate 给 `nil` 就等于
            // 主动放弃后者，而它才是**文档上写明的**「下载失败」信号
            // （`SPUUpdaterDelegate`：「Called after the specified update failed to download」）。
            delegate: self)
        do {
            // ObjC 是 `- (BOOL)startUpdater:(NSError **)error`，Swift 侧被重命名成 `start()`。
            try updater.start()
        } catch {
            startError = error.localizedDescription
            Self.logger.error("Sparkle 启动失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.driver = driver
        self.updater = updater
        Self.logger.info(
            "Sparkle 已启动，feed: \(updater.feedURL?.absoluteString ?? "（Info.plist 未配置 SUFeedURL）", privacy: .public)")
        return updater
    }

    // MARK: - 用户动作

    /// 用户手动「检查更新」。
    ///
    /// updater 起不来时**退回打开 Releases 页**并记一条 error —— 不是静默什么都不做：
    /// 用户点了按钮却毫无反应，比跳到网页更让人困惑。
    func checkForUpdates() {
        // **先清跳过标记再检查**：用户手动点了这一下，意思就是「我不跳了，再看一眼」。
        // 不清的话 Sparkle 仍会按跳过记录把这个版本压住 —— 界面上的「已跳过 1.1.0」
        // 永远不消失，用户会以为检查更新坏了（设计稿 B5 那条 spec-note 明确要求可撤销）。
        clearSkippedVersion()
        // 上一轮的失败 / 发现态也要清掉，否则旧状态会盖住新一轮的结果。
        pendingUpdate = nil
        phase = .idle

        guard let updater = ensureUpdater() else {
            Self.logger.error("检查更新不可用：\(self.startError ?? "未知原因", privacy: .public)")
            UpdateService.openUpdateSource()
            return
        }
        updater.checkForUpdates()
    }

    /// 启动后的静默检查（由「自动更新」开关决定是否真的会跑）。
    ///
    /// Sparkle 自己在 `start()` 之后就会按 `SUScheduledCheckInterval` 排期，
    /// 这里**不额外调用** `checkForUpdatesInBackground()` ——
    /// 那样每次启动都打一次网络请求，而「启动就联网」正是本应用不该有的行为
    /// （它是一个本地磁盘工具，用户没理由在拔盘时被插网）。
    func startIfNeeded() {
        _ = ensureUpdater()
    }

    /// 「查看更新」：把弹窗重新拉起来（用户按过 Esc 之后）。
    ///
    /// 没有待展示的内容时退回一次普通检查 —— **不能什么都不做**：
    /// 按钮点了没反应，与功能坏了长得一模一样。
    func presentFoundUpdate() {
        guard pendingUpdate != nil, alertReply != nil else {
            checkForUpdates()
            return
        }
        Task { await showUpdateAlertIfNeeded() }
    }

    /// 「立即重启」：回答 Sparkle 的 `.install`，它会装完并重新拉起应用。
    func installReadyUpdate() {
        guard let reply = readyReply else { return }
        readyReply = nil
        reply(.install)
    }

    /// 「取消」：中断正在进行的下载。
    func cancelDownload() {
        downloadCancellation?()
        downloadCancellation = nil
        phase = .idle
    }

    /// 「重试」：重新走一次检查（失败多半是网络，重来一次最直接）。
    func retryDownload() {
        checkForUpdates()
    }

    // MARK: - 设置项（设置面板「自动更新」开关绑这两个）

    /// Sparkle 的设置读写口。
    ///
    /// 用 `SPUUpdaterSettings` 而不是 `updater.automaticallyChecksForUpdates`：
    /// 前者**不需要先把 updater 跑起来**就能读写（两者用的是同一份 UserDefaults），
    /// 于是「用户没点过检查更新就先去设置里开开关」这条路也成立。
    private var settings: SPUUpdaterSettings { SPUUpdaterSettings(hostBundle: Bundle.main) }

    /// 是否自动检查更新。
    var automaticallyChecksForUpdates: Bool {
        get { settings.automaticallyChecksForUpdates }
        set { settings.automaticallyChecksForUpdates = newValue }
    }

    /// 是否自动下载更新。
    ///
    /// 与设计稿那句「有新版本时自动下载，并在下次启动时安装」是同一件事。
    ///
    /// ⚠️ **2026-09-19 订正**：这里原来写的是「`SUAutomaticallyUpdate` 保持默认的 `NO`
    /// （不静默强装），于是 Sparkle 只后台下载、等应用退出时再装」—— **反了**。
    /// 实测（把开关置 `true`／`false` 各跑一遍，见 `DESIGN-SPEC.md` §8.79）：
    ///
    /// - `SUAutomaticallyUpdate = NO`（**默认**）⇒ 发现新版本时**弹窗**（不自动下载）。
    /// - `SUAutomaticallyUpdate = YES` ⇒ 后台静默下载，全程没有界面。
    ///
    /// 依据是 Sparkle 源码而不是文档措辞：`SPUUpdaterSettings.m:327` 把它算成
    /// `_allowsAutomaticUpdates && [_host boolForKey:SUAutomaticallyUpdateKey]`，
    /// 而 `SPUUpdater.m:622` 只在它为真时才选 `SPUAutomaticUpdateDriver`（静默下载那条），
    /// 否则走 `SPUScheduledUpdateDriver` → `SPUUIBasedUpdateDriver` → 弹窗。
    ///
    /// 「等应用退出时再装」这一半**两种设置下都成立**（同样 §8.79 实测：
    /// `.18.4/81` 退出后变成 `.19.1/119`）—— 因为它是**安装器工具自己**在
    /// `AppInstaller.m:392-412` 里盯着目标进程退出后接着装，
    /// 与应用回不回答 `showReady` 的 reply 无关。
    var automaticallyDownloadsUpdates: Bool {
        get { settings.automaticallyDownloadsUpdates }
        set { settings.automaticallyDownloadsUpdates = newValue }
    }

    /// 宿主是否**允许**自动更新（未正确签名时为 `false`）。
    ///
    /// 为 `false` 时开关应当禁用并说明原因，而不是让用户开了一个永远不生效的开关
    /// （判据同登录项第三态：**「设了没生效」和「功能坏了」在界面上不能长得一样**）。
    var allowsAutomaticUpdates: Bool { settings.allowsAutomaticUpdates }

    /// 上次检查的时间（设置行里显示「上次检查：…」用；未启动时为 `nil`）。
    var lastUpdateCheckDate: Date? { updater?.lastUpdateCheckDate }

    // MARK: - 「检查更新」这一行显示什么

    /// 设置面板「检查更新」行的状态。
    ///
    /// **抽成枚举而不是在视图里拼字符串**：视图拼字符串就没法断言 ——
    /// 测试只能去比「上次检查：今天 14:30」这种**本地化 + 日期格式**双重依赖的文本，
    /// 换台机器或换个语言必红，而红的原因与被测代码无关
    /// （2026-09-17 CI 连续 6 次红就是这个病根）。枚举可以逐态断言，视图只负责翻译。
    ///
    /// 七个分支与设计稿 C 段那张九行矩阵一一对应（「尚未检查 / 已是最新」两行共用
    /// `lastCheck` 的有无；「稍后」不单独成态 —— 它就是留在 `found` 上）。
    enum CheckRowState: Equatable {
        /// 从未检查过。
        case neverChecked
        /// 检查过，已是最新。
        case upToDate(Date)
        /// 用户点过「跳过此版本」，记着跳的是哪一版。
        case skipped(version: String)
        /// 发现了新版本，等用户决定。
        case found(version: String, lastCheck: Date?)
        /// 正在后台下载。
        case downloading(version: String, fraction: Double)
        /// 已下载完成，等重启安装。
        case ready(version: String)
        /// 下载失败。
        case failed(version: String)
    }

    /// 用户点过「跳过此版本」的那个版本号（没跳过时为 `nil`）。
    ///
    /// **是版本号而不是布尔**：布尔记不住「跳过的是哪一版」，下个版本发布后
    /// 那个布尔还是 `true`，用户会被**永久静音**（他以为只是跳过了 1.1.0）。
    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: AppSettings.Key.skippedVersion) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: AppSettings.Key.skippedVersion)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.Key.skippedVersion)
            }
        }
    }

    /// 当前该显示哪一态。
    var rowState: CheckRowState {
        Self.rowState(phase: phase, skippedVersion: skippedVersion, lastCheck: lastUpdateCheckDate)
    }

    /// 状态的判定逻辑（**纯函数**，与 `UserDefaults` / Sparkle 无关）。
    ///
    /// **为什么要抽出来**：判定里最关键的是**优先级**，而真实环境里很难构造出
    /// 「两个条件同时成立」（`lastUpdateCheckDate` 来自 Sparkle，测试里造不出来）。
    /// 留在计算属性里就只能测到「跳过标记生效了没有」，测不到顺序。
    ///
    /// **顺序有语义**：
    /// 1. 进行中的四态（下载 / 就绪 / 失败 / 发现）**盖过**其它一切 ——
    ///    否则用户会看到「已跳过 1.1.0」的同时有个下载进度条在跑。
    /// 2. 跳过态**盖过**「已是最新」—— 用户跳过 1.1.0 之后界面上必须留着那条痕迹，
    ///    否则他无法分辨「跳过生效了」和「检查更新坏了」
    ///    （与登录项「等待系统批准」同一类判据：**第三态不画就等于没有**）。
    /// 3. 「已是最新」盖过「尚未检查」—— 两者的区别只有 `lastCheck` 的有无，
    ///    而这正是设计稿点名要分开的两行（`已是最新版本` vs `尚未检查`）。
    ///
    /// ⚠️ **`nonisolated`**：它是纯函数（只看三个入参），不该被 `@MainActor` 绑住。
    /// 不标的话，测试里从非主 actor 上下文调它要 `await` —— 一个纯逻辑却要异步，
    /// 会让人误以为它碰了运行时。
    nonisolated static func rowState(
        phase: UpdatePhase, skippedVersion: String?, lastCheck: Date?
    ) -> CheckRowState {
        switch phase {
        case .downloading(let version, let fraction):
            return .downloading(version: version, fraction: fraction)
        case .ready(let version):
            return .ready(version: version)
        case .failed(let version):
            return .failed(version: version)
        case .found(let version):
            return .found(version: version, lastCheck: lastCheck)
        case .idle:
            break
        }
        if let skippedVersion { return .skipped(version: skippedVersion) }
        if let lastCheck { return .upToDate(lastCheck) }
        return .neverChecked
    }

    /// 下载进度是否值得发一次通知。
    ///
    /// **不是优化，是必需品**：`showDownloadDidReceiveData` 是**按数据块**回调的，
    /// 一个大 dmg 能回调上千次；每次都写 `@Published` 会让设置面板每秒重绘几十次。
    /// 而界面上显示的只是整数百分比 —— 只有整数位变了，画面才真的会变。
    ///
    /// 抽成纯函数是为了能断言它（「42.1% → 42.9% 不该发」这种边界，
    /// 在真机上根本构造不出来）。
    nonisolated static func shouldPublishProgress(from old: Double, to new: Double) -> Bool {
        Int(old * 100) != Int(new * 100)
    }

    /// 这次报错该不该算成「下载失败」。
    ///
    /// **判据取自我们自己的状态**（是不是正在下载），不新增一个「这一错是不是下载错」的位 ——
    /// 能派生就别用「手动开关」（同 §「能派生就别用『手动开关』」）。
    ///
    /// **为什么抽成纯函数**：真实环境里「下载中报错」**构造不出来**（要真的下载、且真的失败），
    /// 而它正是 `.failed` 那一态的来源。留成驱动里一句 `if case` 的话，
    /// 「分支写反了」或「被删掉了」都不会有任何断言变红
    /// —— 2026-09-18 实扫发现 `driverDidFailDownload` 当时**全仓库没有调用点**，就是这么发生的。
    nonisolated static func isDownloadFailure(phase: UpdatePhase) -> Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// 手动「检查更新」时清掉跳过标记。
    ///
    /// **跳过必须可撤销**：不清的话用户点「检查更新」也看不到那个版本，
    /// 只能去改偏好文件才能反悔 —— 而界面上没有任何地方告诉他这一点。
    func clearSkippedVersion() { skippedVersion = nil }
}

// MARK: - 给 `UpdateUserDriver` 用的落点
//
// 这些方法**只该由 driver 调**（它们是 Sparkle 回调的落点），单独成段，
// 避免和「用户动作」混在一起看串。

extension UpdateController {

    /// 发现了新版本。
    ///
    /// - Parameter autoDownloads: 自动更新开着时走**后台路径**（不弹窗）。
    /// - Returns: `true` 表示「弹窗交给调用方展示」。
    @discardableResult
    func driverDidFindUpdate(
        _ update: PendingUpdate,
        autoDownloads: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) -> Bool {
        pendingUpdate = update
        alertReply = reply
        if autoDownloads {
            // 设计稿：「开着的时候用户什么都不用做，这正是『后台更新』这个词的含义」。
            phase = .downloading(version: update.version, fraction: 0)
            return false
        }
        phase = .found(version: update.version)
        return true
    }

    /// 下载开始。
    func driverDidStartDownload(version: String, cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        phase = .downloading(version: version, fraction: 0)
    }

    /// 下载进度。
    func driverDidUpdateProgress(_ fraction: Double) {
        guard case .downloading(let version, let old) = phase else { return }
        guard Self.shouldPublishProgress(from: old, to: fraction) else { return }
        phase = .downloading(version: version, fraction: fraction)
    }

    /// 下载完成、开始解压。
    ///
    /// 解压进度**不单独画**：设计稿只承诺百分比，而它说的是下载的百分比
    /// （「百分比是真的，ETA 是编的」），解压是秒级的，再画一条只会闪一下。
    func driverDidFinishDownload() {
        guard case .downloading(let version, _) = phase else { return }
        phase = .downloading(version: version, fraction: 1)
    }

    /// 下载失败。
    func driverDidFailDownload(version: String?) {
        let resolved = version ?? pendingUpdate?.version ?? "?"
        downloadCancellation = nil
        phase = .failed(version: resolved)
    }

    /// 下载并校验完成，等重启。
    func driverIsReady(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        downloadCancellation = nil
        readyReply = reply
        phase = .ready(version: version)
    }

    /// 回到「什么都没在进行」（检查完没有新版本、或用户关掉了错误提示）。
    func driverDidReset() {
        downloadCancellation = nil
        phase = .idle
    }

    /// 用户跳过当前这个版本。
    ///
    /// **跳过记的是版本号**，并且把进行中的状态一起清掉 —— 否则界面会同时说
    /// 「已跳过 1.1.0」和「正在后台下载 1.1.0」。
    func skipPendingVersion() {
        if let version = pendingUpdate?.version { skippedVersion = version }
        pendingUpdate = nil
        phase = .idle
    }

    /// 把弹窗拉起来（`showUpdateFound` 那条路）。
    ///
    /// 用户的选择映射到 Sparkle 的三个 reply：
    /// 「后台更新并重启」→ `.install`、「跳过此版本」→ `.skip`、Esc / 关窗 → `.dismiss`。
    func showUpdateAlertIfNeeded() async {
        guard let update = pendingUpdate, let reply = alertReply else { return }
        let model = UpdateAlertBuilder.model(for: update)
        let choice = await EjectAlertPresenter.shared.present(model)
        alertReply = nil
        switch choice {
        case .installAndRestart:
            // 这一条对应设计稿的「后台更新并重启」：**语义是「后台下载，重启时安装」**，
            // 不是「立刻重启」—— 立刻重启由 B4 那一态的「立即重启」按钮负责。
            reply(.install)
        case .skipVersion:
            skipPendingVersion()
            reply(.skip)
        default:
            // Esc / 关窗 = 稍后。**状态留在设置行上**（phase 仍是 `.found`），
            // 否则用户既不知道有新版本、也没有再打开的入口，只能等下次启动。
            reply(.dismiss)
        }
    }
}

// MARK: - Sparkle 的 delegate 侧（与 user driver 互为兜底）
//
// `SPUUpdaterDelegate` 在头文件里标了 `NS_SWIFT_UI_ACTOR`，所以它到 Swift 侧就是
// `@MainActor` 协议 —— 这个类本身也是 `@MainActor`，实现起来不需要跳线程。

extension UpdateController: SPUUpdaterDelegate {

    /// 下载失败。**这是「下载失败」那一态在文档上写明的来源**
    /// （`SPUUpdaterDelegate`：「Called after the specified update failed to download」）。
    ///
    /// ## 为什么这条和 `UpdateUserDriver.showUpdaterError` 里那条分流都要有
    ///
    /// 2026-09-18 实扫发现 `driverDidFailDownload` **全仓库只有定义、没有任何调用点**：
    /// 于是设计稿 `08-update.html` 给「下载失败」配的那一整行（文案 + 「重试」按钮）
    /// **永远画不出来**，而界面上完全看不出来 —— 下载出错时流程落进
    /// `driverDidReset()` → `phase = .idle`，表现是「进度条无声消失」，
    /// 与「下载完成了」长得一模一样。
    ///
    /// ⚠️ **未核实**：下载失败时 Sparkle 到底走 user driver 那条、还是 delegate 这条
    /// （也可能两条都走）。本环境读不到应用日志、`--preview-*` 又不建 updater，
    /// 真机验证需要一个「真的下载、且真的失败」的场景。**两条都接上，是为了不依赖这个假设**；
    /// 万一两条都触发，也只是把同一个状态设两遍（幂等）。
    ///
    /// ⚠️ 选择器必须与 ObjC 侧逐字对上。**2026-09-18 实测**：把 `failedToDownloadUpdate`
    /// 改一个字母（`…Updates`），**编译照过、测试全绿、什么都不崩** —— 编译器只给一条
    /// `nearly matches optional requirement` 的 **warning**，而 warning 在构建日志里
    /// 和噪音没有区别。真正的后果是方法还在、却永远不会被调：
    /// 与「这个方法根本没写」逐字相同。所以 `UpdateSettingsTests` 用 `responds(to:)`
    /// 去问**运行时**，而不是读源码猜（那条断言实测有牙：拼错即红）。
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.logger.error("下载失败：\(error.localizedDescription, privacy: .public)")
        driverDidFailDownload(version: item.displayVersionString)
    }
}
