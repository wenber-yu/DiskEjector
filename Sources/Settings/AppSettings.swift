import AppKit
import SwiftUI

/// 视觉风格（设置项单一事实来源）。
///
/// 此前 `"transparent"` / `"tinted"` 两个字面量散落在 ContentView 与 SettingsView，
/// 任何一处写错都不会在编译期报错，只会在运行时静默回退到默认外观。收敛为枚举后，
/// 拼写错误变成编译错误。
enum VisualStyle: String, CaseIterable, Sendable {
    case transparent
    case tinted

    static let `default`: VisualStyle = .transparent

    /// 设置面板里的**显示名（长）**，用于无障碍朗读与提示。
    ///
    /// 与 ``AccentColor/displayName`` 同源：显示名只在这里定义一次，
    /// 视图侧不许再各写一份 `switch` —— 否则新增风格时必然出现「枚举加了、下拉里没有」。
    var displayName: String {
        switch self {
        case .transparent: return L10n.tr(.transparentMode)
        case .tinted: return L10n.tr(.tintedMode)
        }
    }

    /// 分段控件上的**短标签**（设计稿 `05-settings.html` 规定为「透明」/「色调」）。
    ///
    /// **为什么必须与 `displayName` 分开**：分段控件的宽度**不可压缩** —— 标签换行会被
    /// SwiftUI 拒绝，它只会按固有宽度撑开，把同一行里 `maxWidth: .infinity` 的弹性列
    /// （也就是「视觉效果」标签列）挤到只剩一个字宽，渲染成竖排单字。
    /// 实测：用长名时该行内容理想宽 745pt，而面板只有 440pt，溢出 305pt；
    /// 改用短标签后降到面板之内。
    /// 长名不删 —— 它是 VoiceOver 该念的完整表述，挂在这个控件的 accessibilityLabel 上。
    var shortName: String {
        switch self {
        case .transparent: return L10n.tr(.transparentModeShort)
        case .tinted: return L10n.tr(.tintedModeShort)
        }
    }
}

/// 强调色（设置项单一事实来源）。
///
/// **为什么要收敛**：此前「字符串 → 颜色」的映射存在三份实现：
/// - `AppDelegate` 里映射成 `NSColor`（菜单栏用）
/// - `ContentView` 里映射成 SwiftUI `Color`（主窗口用）
/// - `SettingsView` 里再维护一份 tag 字符串列表
///
/// 三份各自 switch，新增一个颜色要改三处，漏改就出现「设置里选了红色、菜单栏还是蓝色」。
/// 现在颜色语义、可选列表、两种框架下的色值全部收敛到这一个类，两处 UI 只读取。
///
/// **2026-09-09 简化**：与设计稿对齐，只保留 4 色（蓝/紫/橙/绿）。旧偏好 `red`/`yellow` 自动回退
/// 到 `blue`，避免「设置里选了红色、UI 仍是蓝色」的口径漂移。
enum AccentColor: String, CaseIterable, Sendable {
    case blue
    case purple
    case orange
    case green

    /// 从字符串解析（旧的 `red`/`yellow` 自动回退默认）。
    static func resolve(_ raw: String?) -> AccentColor {
        guard let raw, let value = AccentColor(rawValue: raw) else { return .default }
        return value
    }

    static let `default`: AccentColor = .blue

    /// 16 进制显示色（设计稿统一规范），供设置面板圆点、菜单栏 tint 使用。
    var hex: String {
        switch self {
        case .blue: return "#0a84ff"
        case .purple: return "#af52de"
        case .orange: return "#ff9f0a"
        case .green: return "#34c759"
        }
    }

    /// SwiftUI 侧色值（主窗口用，匹配设计稿色值而非系统 .blue/.purple 等命名色）。
    var swiftUIColor: Color { Color(hex: hex) ?? .blue }

    /// AppKit 侧色值（菜单栏用，与设计稿十六进制一致）。
    var appKitColor: NSColor { NSColor(hex: hex) ?? .systemBlue }

    /// 设置面板里的显示名（本地化）。
    var displayName: String {
        switch self {
        case .blue: return L10n.tr(.colorBlue)
        case .green: return L10n.tr(.colorGreen)
        case .purple: return L10n.tr(.colorPurple)
        case .orange: return L10n.tr(.colorOrange)
        }
    }
}

/// 16 进制 → Color / NSColor 工具（用于把设计稿统一规范的色值直接接入）。
extension Color {
    fileprivate init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

extension NSColor {
    fileprivate convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

/// 偏好设置键与默认值的唯一声明处。
///
/// 此前 `"accentColor"` / `"showDockIcon"` / `"visualStyle"` 这些字符串在源码里硬编码 6 处，
/// 其中 `AppDelegate` 用 `UserDefaults.standard.string(forKey:)` 读取、`SettingsView` 用
/// `@AppStorage` 写入——两端靠字符串字面量对齐，改一处忘一处就会出现「设置改了但菜单栏没变」。
enum AppSettings {
    enum Key {
        static let visualStyle = "visualStyle"
        static let accentColor = "accentColor"
        static let showDockIcon = "showDockIcon"

        /// 登录项偏好的键由 ``LaunchAtLoginManager`` 持有，此处仅作文档索引，不要另写字面量。
        static var launchAtLogin: String { LaunchAtLoginManager.defaultsKey }

        /// 首次启动的「完全磁盘访问」引导是否已展示过。
        /// 直发（非沙盒）版依赖 lsof 列出占用进程，而这需要用户授权 FDA；
        /// 该标记避免每次启动都弹引导窗，仅首次未授权时提示一次。
        static let hasShownFDAOnboarding = "hasShownFDAOnboarding"
    }

    /// 从 UserDefaults 读取当前强调色，无值或损坏值时回退默认色。
    ///
    /// 旧的 6 色枚举里的 `red`/`yellow` 会自动回退到 `blue`（``AccentColor/resolve(_:)``）。
    nonisolated static var accentColor: AccentColor {
        AccentColor.resolve(UserDefaults.standard.string(forKey: Key.accentColor))
    }

    /// 从 UserDefaults 读取当前视觉风格，无值或损坏值时回退默认。
    nonisolated static var visualStyle: VisualStyle {
        guard let raw = UserDefaults.standard.string(forKey: Key.visualStyle),
            let value = VisualStyle(rawValue: raw)
        else {
            return .default
        }
        return value
    }

    /// 首次启动的「完全磁盘访问」引导是否已展示（读写 UserDefaults）。
    ///
    /// 直发版依赖 lsof 列出占用进程，而它需要用户授权 FDA。
    /// 该标记确保引导窗只在首次启动时弹一次，避免每次启动都打扰用户。
    nonisolated static var didShowFDAOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hasShownFDAOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hasShownFDAOnboarding) }
    }

    /// 打开「系统设置 › 隐私与安全性 › 完全磁盘访问」面板。
    ///
    /// 该 URL scheme 是 macOS 跳转到指定隐私子面板的官方方式；
    /// 直发版需要用户在此处为 DiskEjector 开启开关，lsof 才能列出其他进程。
    nonisolated static func openFullDiskAccessSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
