import AppKit
import SwiftUI

/// 系统原生毛玻璃背景（与菜单栏 NSPopover 系统默认背景一致：.underWindowBackground + .behindWindow）。
///
/// **为什么用 NSVisualEffectView 而非 SwiftUI `.background(.ultraThinMaterial)`**：
/// - SwiftUI 的 Material 是窗口内的"应用级毛玻璃"；`.ultraThinMaterial` 在 macOS 14 上偏厚，
///   整窗覆盖会让窗口失去 Liquid Glass 的悬浮感。
/// - NSVisualEffectView(.underWindowBackground, .behindWindow) = NSPopover 系统默认背景，
///   让桌面直接透过窗口呈现，视觉上跟菜单栏 panel 完全一致。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

/// 卡片式样式：无填充底色 + 背面投影 + 发丝描边（对齐 ProxyGenerator 的 cardStyle）。
extension View {
    /// **去 SwiftUI Button 默认 focus 环**。
    ///
    /// 主窗口启动时第一个 interactive Button 会自动获得焦点环（macOS 14+ 的 SwiftUI 默认行为），
    /// 蓝色环套在 RefreshButton 上看着像"按钮被高亮选中"——但用户没点任何按钮。
    /// - `.focusable(false)` 在 macOS 13+ 上移除 focus 资格；
    /// - `.focusEffectDisabled()` 仅 macOS 14+ 可用，单独包一层 ViewModifier 包版本守卫。
    func disableFocusRingIfAvailable() -> some View {
        modifier(DisableFocusRingModifier())
    }

    /// 卡片式样式：透明底（靠液态玻璃透出）+ 外圈投影 + 发丝描边 + 14pt 圆角。
    ///
    /// 与 ProxyGenerator 保持一致：**不填充任何底色**，只靠「实体模糊投影 + 反向遮罩」
    /// 在背后做出浮动感，卡片内部始终透出窗口玻璃，暗/亮模式下都不会出现色块。
    /// 调用方负责给内容加内边距（惯例 `.padding(12)` 再 `.cardStyle()`）。
    func cardStyle() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.26))
                    .blur(radius: 12)
                    .offset(y: 6)
                    .mask(
                        Rectangle()
                            .padding(-60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
    }
}

private struct DisableFocusRingModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// 窗口配置器：把标题栏变成透明、内容延伸到标题栏、支持拖动窗口背景移动。
/// 与 ProxyGenerator 的 WindowAccessor 一致，一次性配置不重复执行。
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
