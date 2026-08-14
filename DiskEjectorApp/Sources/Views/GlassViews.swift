import SwiftUI
import AppKit

/// 系统原生液态玻璃背景（对齐 ProxyGenerator 项目的 UI 风格）。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

/// 卡片式样式：无填充底色 + 背面投影 + 发丝描边（对齐 ProxyGenerator 的 cardStyle）。
extension View {
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
