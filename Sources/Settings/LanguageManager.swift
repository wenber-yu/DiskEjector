import AppKit
import Foundation

/// 界面语言（设置项单一事实来源）。
///
/// **为什么是「跟随系统 + 三个具体语言」而不是一个开关**：语言是 N 选一
/// （将来加语言会变成 4、5 项），二值开关表达不了；分段控件项数一多也会挤。
/// 设计稿 `05-settings.html` 用的是下拉（`.popup`），与 macOS 系统设置一致。
///
/// ⚠️ **`case system` 不是「简体中文」的别名**：它表示「不写 `AppleLanguages`，
/// 系统给什么用什么」。把它折叠成某个具体语言，用户改系统语言后本应用不会跟着变。
enum AppLanguage: String, CaseIterable, Sendable {
    /// 跟随系统（不写 `AppleLanguages`）。
    case system
    case zhHans = "zh-Hans"
    case en
    case zhHant = "zh-Hant"

    static let `default`: AppLanguage = .system

    /// 从偏好里的字符串解析，未知值回退 ``default``。
    static func resolve(_ raw: String?) -> AppLanguage {
        guard let raw, let value = AppLanguage(rawValue: raw) else { return .default }
        return value
    }

    /// 下拉里的显示名。
    ///
    /// **具体语言用该语言自己的写法（endonym）**，不做本地化：用户在英文界面里
    /// 找「中文」时，看到 "Chinese" 反而要绕一下；写成「简体中文」他直接认得。
    /// 这是 macOS 的通行做法（系统设置的「语言与地区」同样如此）。
    /// 只有「跟随系统」这一项是产品文案，必须本地化 —— 它不是语言的名字。
    var displayName: String {
        switch self {
        case .system: return L10n.tr(.followSystemLanguage)
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .zhHant: return "繁體中文"
        }
    }

    /// 写进 `AppleLanguages` 的语言码；``system`` 为 `nil`（表示**不写**这个键）。
    var localeCode: String? {
        switch self {
        case .system: return nil
        default: return rawValue
        }
    }
}

/// 界面语言的读写与生效判定。
///
/// ## 机制：`AppleLanguages` 只在启动时被读一次
///
/// macOS 在进程启动时把 `AppleLanguages`（本应用偏好域里的数组）解析成
/// `Locale.current`，**之后不再重读**。所以「改了语言」到「界面变了」之间必然隔着一次重启 ——
/// 这不是缺陷，是平台行为。
///
/// **因此必须画出第三态**：用户选了 English、界面纹丝不动，如果不告诉他「下次启动生效」，
/// 他无法分辨「切换本来就要等重启」和「这个功能坏了」。
/// 与登录项的「等待系统批准」、更新的「已跳过 1.1.0」是同一类错误：**第三态不画就等于没有**。
///
/// ## 与 `L10n` 同源
///
/// ``active`` 必须读 `Locale.current` —— 因为 `L10n.tr` 就是按它的 identifier 查表的
/// （见 `tools/gen_l10n_tool`）。**不能读 `Bundle.main.preferredLocalizations`**：
/// 本应用没有 `.lproj` 目录（文案由构建插件生成成 Swift 常量），那个 API 在这里答非所问，
/// 只会答出 `CFBundleDevelopmentRegion`。
enum LanguageManager {

    /// `AppleLanguages` 的键名。
    ///
    /// ⚠️ **不是 ``AppSettings/Key`` 里的一项**：那个枚举管的是本应用自己的偏好，
    /// 而这一个是**系统认得的键**，写错一个字母不会报错，只会静默不生效。
    /// 所以在这里单独声明一次，不许别处再写字面量。
    static let appleLanguagesKey = "AppleLanguages"

    // MARK: - 读取

    /// 用户选择的语言（可能还没生效）。
    static var preferred: AppLanguage {
        get { AppLanguage.resolve(UserDefaults.standard.string(forKey: AppSettings.Key.appLanguage)) }
        set { apply(newValue) }
    }

    /// 本次启动**实际生效**的语言。
    static var active: AppLanguage { language(for: .current) }

    /// 把「系统给的 locale」映射到本应用支持的语言。
    ///
    /// **抽成纯函数是为了可测**：`Locale.current` 由开发机决定，
    /// 直接断言 ``active`` 等于在断言「这台机器是中文」—— 换台机器必红，
    /// 而红的原因与被测代码无关（2026-09-17 CI 连续 6 次红即此因）。
    static func language(for locale: Locale) -> AppLanguage {
        let id = locale.identifier
        if id.hasPrefix("en") { return .en }
        // 繁体：脚本标注（`zh-Hant`）与地区（`zh_TW` / `zh_HK` / `zh_MO`）都算。
        // 用 `contains` 而不是 `hasSuffix("_TW")` —— identifier 的分隔符在不同系统版本上
        // 是 `-` 还是 `_` 并不稳定，绑死一种会静默漏判（漏判的后果是繁体用户看到简体）。
        if id.contains("Hant") || id.contains("TW") || id.contains("HK") || id.contains("MO") {
            return .zhHant
        }
        return .zhHans
    }

    /// 偏好真正指向的语言（``AppLanguage/system`` 解析成当前生效的那个）。
    ///
    /// **`system` 必须在这里被消解掉**：不消解的话「跟随系统」与「当前生效」
    /// 永远是两个不同的值，``isRestartPending(preferred:)`` 会一直为真，
    /// 界面上就永远挂着「待重启」。
    static var resolved: AppLanguage {
        switch preferred {
        case .system: return active
        default: return preferred
        }
    }

    /// 偏好是否指向一个**还没生效**的语言。
    ///
    /// 为真时设置面板要显示第三态（「将在重启后切换为 …」+「立即重启」）。
    static var isRestartPending: Bool { isRestartPending(preferred: preferred) }

    /// 纯函数版本（视图用）。
    ///
    /// **视图必须走这一个**：视图侧的语言来自 `@AppStorage`（`appLanguageRaw`），
    /// 而 ``preferred`` 是直接读 `UserDefaults` 的 —— 两者在 SwiftUI 的刷新时序里
    /// 可能差一帧。更要紧的是：把判定写成纯函数，测试才能不依赖开发机的
    /// `Locale.current` 就断言四种组合（跟随系统 / 选当前 / 选另一个 / 选繁体）。
    static func isRestartPending(preferred: AppLanguage, active: AppLanguage = active) -> Bool {
        switch preferred {
        case .system: return false
        default: return preferred != active
        }
    }

    // MARK: - 写入

    /// 记下用户的选择并写 `AppleLanguages`（下次启动生效）。
    static func apply(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: AppSettings.Key.appLanguage)
        if let code = language.localeCode {
            UserDefaults.standard.set([code], forKey: appleLanguagesKey)
        } else {
            // 「跟随系统」= 把这个键**删掉**，而不是写一个猜测值。
            // 写死 ["zh-Hans"] 的话，用户之后改系统语言本应用不会跟 —— 名字还叫「跟随系统」。
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }
    }

    // MARK: - 立即重启

    /// 重启应用，让新语言当场生效。
    ///
    /// **为什么不直接用 `NSWorkspace.openApplication`**：本进程还没退出时，
    /// 它只会把现有实例拉到前台（什么都不发生）；开 `createsNewApplicationInstance`
    /// 则会开出**第二个实例**（两个菜单栏图标，用户得自己杀掉一个）。
    ///
    /// 正确做法是**先起一个等待者**：它盯着本进程的 pid，等我们退出后再 `open` 这个 bundle。
    /// 所以这里的顺序是「起等待者 → 立即 `terminate`」，中间不能等等待者结束。
    ///
    /// ⚠️ 不收集子进程输出 —— 所以不需要 `SubprocessOutput` 的超时机制
    /// （那套解决的是「读输出会挂死」，见 `ENGINEERING-NOTES.md`）。
    /// ⚠️ **`@MainActor`**：最后一句要 `NSApp.terminate`，而 `NSApp` 与
    /// `AppDelegate.isPreviewRun` 都是主 actor 隔离的。不加的话编译器只给**警告**
    /// （隐式异步），但语义上就是「从非主线程去关应用」—— 那是不该发生的事，
    /// 所以这里显式标出来，让调用方也必须站在主 actor 上。
    @MainActor
    static func restart() {
        guard let bundlePath = relaunchableBundlePath else {
            // 非 bundle 形态（单测 runner / 裸可执行）：没有可重开的东西。
            LogService.shared.log(disk: nil, message: "重启被跳过：当前不是 .app bundle")
            return
        }
        guard !AppDelegate.isPreviewRun else {
            LogService.shared.log(disk: nil, message: "重启被跳过：预览模式（--preview-*）")
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(bundlePath)\"",
        ]
        do {
            try waiter.run()
        } catch {
            // **不静默吞掉**：起了等待者才算「重启已安排」，起不来就要说出来，
            // 否则用户点了「立即重启」什么都不会发生，且没有任何线索。
            LogService.shared.log(disk: nil, message: "重启失败：\(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// 可重开的 bundle 路径；非 `.app`（单测 runner、裸可执行）时为 `nil`。
    ///
    /// **判据是扩展名，不是「存不存在」**：测试进程里 `Bundle.main.bundleURL`
    /// 指向 xctest 的 `.xctest` 包，`open` 它只会报错 —— 那种情况下应当什么都不做。
    private static var relaunchableBundlePath: String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        return url.path
    }
}
