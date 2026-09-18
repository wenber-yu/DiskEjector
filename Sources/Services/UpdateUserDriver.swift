import AppKit
import Foundation
import OSLog
import Sparkle

// 本文件是设计稿 `DiskEjector-UI-Design/v2/screens/08-update.html` 的实现侧另一半：
// 把 Sparkle 的回调翻译成 ``UpdateController`` 的状态，并在该弹窗的时候弹窗。
//
// **为什么必须自己实现 driver**：见 `UpdateController` 的类注释（下载进度只在 driver 里给）。

/// 把 Sparkle 的更新回调接到 ``UpdateController`` 的状态机上。
///
/// ## 弹窗什么时候弹（这是本页最容易做错的一条）
///
/// 设计稿 A 段的开场白写死了判据：
/// 「弹窗**只在自动更新关掉时才会出现** —— 开着的时候用户什么都不用做，
/// 这正是『后台更新』这个词的含义。」
///
/// 于是 ``showUpdateFound(with:state:reply:)`` 里**不看 `state.userInitiated`**，
/// 只看 `automaticallyDownloadsUpdates`：开关开着就静默下载（设置行显示进度），
/// 关着就弹窗。用户主动点「检查更新」时，反馈由设置行给（「正在后台下载 1.1.0」或
/// 「发现 1.1.0」），不是靠弹窗 —— 否则开关开着也会弹，与设计稿自相矛盾。
///
/// ## 关于线程隔离
///
/// `SPUUserDriver` 是 ObjC 协议，方法没有 `@MainActor` 标注，而 Sparkle 保证
/// 这些方法都在主线程回调。实测（2026-09-18，Swift 6.3）：给这个类标 `@MainActor`
/// 就**直接编译通过**，不需要 `@preconcurrency`（加上反而会报
/// 「`@preconcurrency` on conformance has no effect」—— 那是个警告，
/// 而本仓库的门槛 1 带 `-warnings-as-errors`，留着就是红）。
///
/// 也**不用**给每个方法加 `MainActor.assumeIsolated`：那会在真出问题时
/// （真的从别的线程回调）静默走进未定义行为，不如让类型系统兜着。
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "Update")

    private weak var controller: UpdateController?

    /// 下载总长 / 已收长度（`showDownloadDidReceiveData` 只给增量）。
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    init(controller: UpdateController) {
        self.controller = controller
        super.init()
    }

    // MARK: - 权限询问

    /// 是否允许自动检查更新。
    ///
    /// **正常不会被调用**：`Info.plist` 里已经写明 `SUEnableAutomaticChecks = YES`
    /// （见 `build_app.sh`），Sparkle 只在那个键缺失时才问。
    ///
    /// 但仍然要给出答案：不回答的话整个更新流程会停在这里等一个永远不来的点击 ——
    /// 而界面上什么都看不到（本应用没有「首次启动询问更新偏好」这一步）。
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - 检查

    /// 用户主动检查开始。
    ///
    /// **故意不画「正在检查…」**：这一段通常只有几百毫秒，设置行此时显示的仍是
    /// 上一轮的结果，直到 ``showUpdateFound(with:state:reply:)`` 或
    /// ``showUpdateNotFoundWithError(_:acknowledgement:)`` 给出新答案。
    /// 画一个会闪一下的中间态比不画更吵 —— 与主窗口那条「推出中不画进度」同一条理由。
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Self.logger.debug("用户主动检查更新")
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard let controller else {
            reply(.dismiss)
            return
        }

        // **只读更新**（appcast 里带 `sparkle:informational`）：没有包可下，只能把人送到网页。
        // 这条必须显式处理 —— 否则会对一个没有 enclosure 的条目走「后台下载」，
        // 然后永远停在 0%。
        if appcastItem.isInformationOnlyUpdate {
            if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
            reply(.dismiss)
            return
        }

        let update = PendingUpdate(
            version: appcastItem.displayVersionString,
            newBuild: appcastItem.versionString,
            currentVersion: AppVersionInfo.shortVersion() ?? L10n.tr(.updateUnknownVersion),
            currentBuild: AppVersionInfo.build(),
            date: appcastItem.dateString,
            sizeBytes: appcastItem.contentLength,
            notes: UpdateReleaseNotes.lines(fromHTML: appcastItem.itemDescription))

        let shouldPresent = controller.driverDidFindUpdate(
            update,
            autoDownloads: controller.automaticallyDownloadsUpdates,
            reply: reply)

        if shouldPresent {
            Task { await controller.showUpdateAlertIfNeeded() }
        } else {
            // 后台路径：直接开始下载，不弹窗（这就是「自动更新」开着时的样子）。
            reply(.install)
        }
    }

    /// appcast 里**外链**的 release notes（`<sparkle:releaseNotesLink>`）。
    ///
    /// 本应用的「本次更新」清单取自 appcast **内嵌**的 `<description>`
    /// （`SUAppcastItem.itemDescription`），所以这条不会被调用。
    /// 留空实现而不是把 HTML 塞进弹窗 —— 塞进去就要在自绘弹窗里渲染任意 HTML。
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.driverDidReset()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // 更新流程本身出错（feed 拿不到、签名不匹配、Sparkle 自己起不来…）。
        //
        // **不弹窗**：本应用的弹窗是给「要不要装」用的；错误另有落点
        // （设置行回到上一态 + 日志）。给一个「更新失败」弹窗会打断用户拔盘，
        // 而这件事与他此刻在做的事无关。
        Self.logger.error("更新出错：\(error.localizedDescription, privacy: .public)")
        controller?.driverDidReset()
        acknowledgement()
    }

    // MARK: - 下载

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard let controller else { return }
        expectedContentLength = 0
        receivedContentLength = 0
        controller.driverDidStartDownload(
            version: controller.pendingUpdate?.version ?? L10n.tr(.updateUnknownVersion),
            cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        // 总长未知（服务器没给 `Content-Length`）时不猜百分比 ——
        // 猜出来的进度条会在中途倒退，比没有进度更让人怀疑。
        guard expectedContentLength > 0 else { return }
        let fraction = min(1, Double(receivedContentLength) / Double(expectedContentLength))
        controller?.driverDidUpdateProgress(fraction)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller?.driverDidFinishDownload()
    }

    /// 解压进度：**不画**（见 `UpdateController.driverDidFinishDownload` 的说明）。
    func showExtractionReceivedProgress(_ progress: Double) {}

    // MARK: - 安装

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let controller else {
            reply(.dismiss)
            return
        }
        // **攥着 reply 不马上回答**：见 `UpdateController.readyReply` 的说明 ——
        // 重启不自动做，用户点「立即重启」时才给出 `.install`。
        controller.driverIsReady(
            version: controller.pendingUpdate?.version ?? L10n.tr(.updateUnknownVersion),
            reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // 走到这里说明用户点了「立即重启」，Sparkle 正在替换 bundle。
        // 不需要额外 UI —— 应用马上会被关掉并重新拉起，画什么都来不及看。
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        controller?.driverDidReset()
    }
}

// MARK: - 更新说明：appcast 的 HTML → 一行一条

/// 把 appcast 里的 `<description>`（HTML）解析成「一行一条」的更新清单。
///
/// **为什么是纯函数**：这是整条链上唯一一处「输入不可控」的转换 ——
/// appcast 是 `generate_appcast` 按 git commit 正文生成的，
/// 里面可能是 `<ul><li>…</li></ul>`，也可能只是一段裸文本。
/// 抽成纯函数之后，「三种输入各自解析成什么」可以被逐条钉住，
/// 而不是等到真发版时靠肉眼看弹窗。
enum UpdateReleaseNotes {

    /// 解析成条目。**空输入返回空数组**（调用方据此不画「本次更新」区块）——
    /// 返回一个 `[""]` 会让弹窗多出一行空白。
    static func lines(fromHTML html: String?) -> [String] {
        guard let raw = html?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }

        // ① 先把「条目边界」变成换行，**再**剥标签。
        //    顺序反了的话所有条目会粘成一行，看起来像「只有一条更新」——
        //    而这是最容易漏的一步：剥完标签的文本读起来完全正常，只是少了分隔。
        var marked = raw
        for boundary in ["<li", "<br", "</p", "</div", "<tr", "<h1", "<h2", "<h3"] {
            marked = marked.replacingOccurrences(of: boundary, with: "\n" + boundary)
        }

        // ② 剥标签 → ③ 解实体 → ④ 逐行清理。
        return stripTags(marked)
            .components(separatedBy: .newlines)
            .map { line in trimBullet(decodeEntities(line)) }
            .filter { !$0.isEmpty }
    }

    /// 剥掉 `<…>` 之间的内容（不做正则：标签名不重要，只要成对扫掉）。
    private static func stripTags(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// 解 HTML 实体。
    ///
    /// ⚠️ **`&amp;` 必须最后解**：先解它的话，`&amp;lt;` 会先变成 `&lt;`
    /// 再变成 `<` —— 一个本该显示成 `&lt;` 的文本被多解了一层。
    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&nbsp;", " "),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 去掉行首的列表符号。
    ///
    /// 弹窗自己会画 `·`（设计稿 `.changelog`），所以源文本里自带的符号必须去掉 ——
    /// 不去掉的话每条会变成「· · 修复了…」。
    private static func trimBullet(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, "-*•·".contains(first) {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
