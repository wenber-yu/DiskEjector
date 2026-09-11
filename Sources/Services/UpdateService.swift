import AppKit
import Foundation
import OSLog

/// 应用的分发渠道。
///
/// 不同渠道的更新方式完全不同，UI 必须给出正确的指引，否则用户会去找一个不存在的入口。
enum DistributionChannel: String, Sendable, CustomStringConvertible {

    /// Mac App Store 版本：更新完全由 App Store 负责，应用自身不允许自更新。
    case appStore

    /// Developer ID 签名、官网或 GitHub 直发：可自行实现更新检查（Sparkle 等）。
    case direct

    /// 本地开发或 ad-hoc 签名：无更新渠道。
    case development

    var description: String { rawValue }
}

/// 更新入口。
///
/// ## 为什么 MAS 版本不能用 Sparkle
///
/// Sparkle 的工作方式是下载新版本、替换 app bundle、重启。这在 Mac App Store 上
/// 既违反审核指南（2.4.5：不得自行下载可执行代码；应用更新必须经由 App Store），
/// 也在沙盒下无法完成替换自身的操作。因此 MAS 版本只做「打开 App Store 页面」，
/// 把更新交给系统。
///
/// ## 为什么不引入 Sparkle 依赖
///
/// 当前主分发渠道是**官网直发（Developer ID）**，引入 Sparkle 会带来：一个额外的 SPM 依赖、
/// EdDSA 密钥管理、appcast 托管、以及每次发布多一道签名流程。在确认需要自更新之前，
/// 直发版本先降级为「打开下载页」——零依赖、零签名负担，用户同样能拿到新版本。
/// 若后续要接 Sparkle，只需替换 ``openUpdateSource()`` 的直接分发分支，
/// UI 与渠道判定无需改动。
enum UpdateService {

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "Update")

    // MARK: - 需要替换的常量

    /// App Store 标识符。
    ///
    /// **上架后必须替换为真实值**。取值来源：App Store Connect → 我的 App → App 信息 →
    /// 「Apple ID」字段，是一串纯数字（如 `1234567890`）。也可以直接填 `id1234567890`，
    /// 两种写法都会被接受。
    ///
    /// 为 `nil` 时 MAS 版只显示说明文字、不提供跳转按钮——
    /// 宁可少一个按钮，也不要把用户导向错误的页面。
    private static let appStoreID: String? = nil

    /// 直发版本的下载 / Releases 页（GitHub Releases 或自有下载页）。
    ///
    /// 注意：本文件**没有集成 Sparkle**，此常量也与 Sparkle 无关——它只是直发版
    /// 「打开下载页」按钮的目标地址。未配置时按钮隐藏。
    /// 上线时填入你的 Releases 页地址即可（例如 https://github.com/<you>/DiskEjector/releases）。
    private static let downloadPageURL: URL? = nil

    // MARK: - 渠道判定

    /// 当前分发渠道。
    ///
    /// **判定依据**：Mac App Store 版本在 bundle 内带有 App Store 收据
    /// （`Contents/_MASReceipt/receipt`），`Bundle.main.appStoreReceiptURL` 即指向它。
    /// 直发与开发版本都没有这个文件。
    ///
    /// 用收据而非「是否被沙盒」来判定：沙盒只是分发的技术副产品，
    /// 语义上「这个 app 是从 App Store 买的」才是我们真正要区分的事。
    static var channel: DistributionChannel {
        // 收据路径在 Debug 运行时也会返回（指向一个尚不存在的位置），
        // 因此必须检查文件是否真的存在。
        if let receiptURL = Bundle.main.appStoreReceiptURL,
            FileManager.default.fileExists(atPath: receiptURL.path)
        {
            return .appStore
        }

        #if DEBUG
            return .development
        #else
            return .direct
        #endif
    }

    /// 是否应提供「打开更新来源」的按钮。
    ///
    /// 常量未配置时返回 `false`，UI 据此隐藏按钮，避免出现点了没反应的死链接。
    static var canOpenUpdateSource: Bool {
        switch channel {
        case .appStore: return appStoreID != nil
        case .direct, .development: return downloadPageURL != nil
        }
    }

    /// 更新来源的地址；常量未配置时为 `nil`。
    static var updateSourceURL: URL? {
        switch channel {
        case .appStore:
            return appStoreURL
        case .direct, .development:
            return downloadPageURL
        }
    }

    /// 构造 App Store 产品页地址（用 `macappstore://` 直接唤起 App Store 应用，而非浏览器）。
    private static var appStoreURL: URL? {
        guard let identifier = Self.normalizedAppStoreID(appStoreID) else { return nil }
        return URL(string: "macappstore://apps.apple.com/app/\(identifier)")
    }

    /// 归一化 App Store 标识符：接受 `1234567890` 或 `id1234567890`，统一为 `id1234567890`。
    ///
    /// App Store Connect 里显示的是纯数字，而链接路径要求 `id` 前缀。两者都接受并归一化，
    /// 避免上线时因格式差异拼出无效链接。
    static func normalizedAppStoreID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.hasPrefix("id") ? raw : "id" + raw
    }

    /// 打开更新来源（App Store 页面或下载页）。
    ///
    /// 未配置常量时不执行任何操作——由 ``canOpenUpdateSource`` 保证 UI 不会给出这个入口。
    static func openUpdateSource() {
        guard let url = updateSourceURL else {
            logger.warning("更新来源未配置，忽略打开请求")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
