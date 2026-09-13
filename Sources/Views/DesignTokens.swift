import AppKit
import SwiftUI

/// 全局设计令牌（与设计稿统一规范的视觉常量集中声明处）。
///
/// **设计稿统一规范（6 份设计稿共享）**：
/// - 浅色：bg=#ffffff, fg=#0f172a, card=rgba(255,255,255,0.72), popover=rgba(255,255,255,0.86),
///   primary=#0a84ff, muted=rgba(120,129,144,0.14), muted-foreground=#6b7280, border=rgba(0,0,0,0.08)
/// - 深色：bg=#0b0b0f, fg=#f8fafc, card=rgba(28,28,36,0.72), popover=rgba(28,28,36,0.86), primary=#409cff
/// - 圆角 sm/md/lg = 6/10/16
/// - 毛玻璃：主窗标题 12 / 卡片 16 / 弹窗 20+饱和度 / 设置 24
///
/// **实现策略**：
/// - 文字、边框、卡片背景用 SwiftUI 系统色（`.primary` / `.secondary` / Material），
///   跟随 macOS 明暗模式自动切换，**不依赖 asset catalog**，部署目标 macOS 14+ 即可。
/// - 强调色单独提供 hex + SwiftUI/NSColor 转换，由设置驱动（运行时变化）。
/// - 毛玻璃按 macOS 版本优雅降级：15+ 用 `.ultraThinMaterial`（接近 Liquid Glass），
///   14 用 `.regularMaterial` 兜底。
enum DesignTokens {

    // MARK: 圆角

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        /// 主窗口外框圆角（设计稿 12px，比 lg 略小）。
        static let window: CGFloat = 12
    }

    // MARK: 间距

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: 字号（与 AppFont 互补，专为新设计稿语义化）

    enum FontSize {
        /// 主窗口居中标题（如 "DiskEjector"）— 设计稿 15px / 600。
        static let titleBar: CGFloat = 15
        /// 磁盘卡片的磁盘名 — 设计稿 16px / 600。
        static let diskCardName: CGFloat = 16
        /// 容量标签（"剩余 700 GB / 共 1 TB"）— 设计稿 13px。
        static let capacity: CGFloat = 13
        /// 进程 tag 内文字 — 设计稿 12px。
        static let processTag: CGFloat = 12
        /// 主按钮文字（如"推出磁盘"）— 设计稿 13px / 500。
        static let primaryButton: CGFloat = 13
        /// 菜单栏磁盘名 — 设计稿 13px / 500。
        static let menuDiskName: CGFloat = 13
        /// 菜单栏磁盘 meta — 设计稿 11px。
        static let menuDiskMeta: CGFloat = 11
        /// 弹出面板标题（如"外置磁盘"）— 设计稿 14px / 500。
        static let menuTitle: CGFloat = 14
        /// 设置面板分组标题 — 设计稿 14px / 500。
        static let settingsTitle: CGFloat = 14
    }

    // MARK: 圆角/形状尺寸

    enum Size {
        /// 主窗口尺寸（设计稿硬性规格）。
        static let mainWindow = CGSize(width: 800, height: 520)
        /// 设置面板尺寸。
        ///
        /// **高度是量出来的，不是拍脑袋定的**：六段内容的自然高度随文案变化，
        /// 历史值 520pt 装不下（实测内容 602pt），于是面板底部的「关于 / 更新」被
        /// 折叠线挡在滚动区外 —— 用户看到的就是「设置界面排版不好看」。
        /// 602 = 头部 56 + 内容 536 + 底部留白 10，中英文版面实测一致（见 `SettingsLayoutTests`）。
        /// 改任何一段文案/内边距后，测试会要求同步更新这个值。
        static let settingsPanel = CGSize(width: 440, height: 602)
        /// 菜单栏弹出面板宽度。
        static let menuPopoverWidth: CGFloat = 360
        /// 推出确认对话框最大宽度。
        static let confirmDialogMaxWidth: CGFloat = 420
        /// FDA 授权引导面板最大宽度。
        static let fdaDialogMaxWidth: CGFloat = 380

        /// 主窗口工具栏高度（macOS 标准 unified 标题栏 38pt）。
        static let titleBarHeight: CGFloat = 38
        /// 磁盘图标容器尺寸（40 × 40，padding 12，10 圆角）。
        static let diskIconContainer: CGFloat = 40
        /// 菜单栏磁盘图标容器（32 × 32）。
        static let menuIconContainer: CGFloat = 32
        /// 进程 tag 内图标（22 × 22，与磁盘卡片头部图标同视觉重量）。
        static let processTagIcon: CGFloat = 22
        /// 进程 tag 内高（32 = 图标 22 + 上下各 5 留白）。
        ///
        /// **必须**由容器固定内高来保证内容垂直居中，而不是靠 `padding(.top/.bottom)` 凑——
        /// 见 ``ProcessTag`` 里对「padding 不对称导致内容下压」的说明。
        static let processTagHeight: CGFloat = 32
        /// 主按钮高度。
        static let primaryButtonHeight: CGFloat = 32
        /// 标题栏小图标按钮（圆形，8×8px = 32×32，但这里是 8×8 像素的 28×28）。
        static let titleBarIconButton: CGFloat = 28
    }

    // MARK: 颜色（系统色 + 自定义强调色）

    /// 系统色（半透明卡、边框、文字等）—— 自动适配明暗模式。
    enum Palette {
        /// 卡片背景（设计稿 0.72 透明度）。
        static func cardBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 28 / 255, green: 28 / 255, blue: 36 / 255).opacity(0.72)
                : Color.white.opacity(0.72)
        }
        /// 弹出面板背景（设计稿 0.86，更不透明）。
        static func popoverBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 28 / 255, green: 28 / 255, blue: 36 / 255).opacity(0.86)
                : Color.white.opacity(0.86)
        }
        /// muted 背景（设计稿 14% 灰）。
        static var mutedBackground: Color { Color.primary.opacity(0.06) }
        /// 边框（设计稿 8% 黑/白）。
        static var border: Color { Color.primary.opacity(0.08) }
        /// 主标题文字。
        static var foreground: Color { .primary }
        /// 副文字。
        static var mutedForeground: Color { .secondary }
        /// 成功（#34c759 / systemGreen）。
        static var success: Color { .green }
        /// 警告（#ff9f0a / systemOrange）。
        static var warning: Color { .orange }
        /// 错误（#ff453a / systemRed）。
        static var error: Color { .red }
    }

    // MARK: 动画

    enum Motion {
        /// 通用悬停/状态过渡（设计稿 0.15s ease）。
        static let fast: Animation = .easeInOut(duration: 0.15)
        /// 主窗 toggle/进度条过渡（设计稿 0.2s ease）。
        static let standard: Animation = .easeInOut(duration: 0.2)
    }
}

// MARK: - 辅助：NSColor 十六进制

extension NSColor {
    /// 16 进制字符串 → NSColor（公开给菜单栏 tint 等使用）。
    convenience init?(designHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
