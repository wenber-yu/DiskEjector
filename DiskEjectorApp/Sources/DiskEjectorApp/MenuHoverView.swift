import AppKit

/// 菜单行 hover 高亮视图。
///
/// `NSMenuItem` 使用自定义 view（`menuItem.view = ...`）后，系统不再提供默认的
/// hover 高亮背景。该视图通过 tracking area 恢复这一交互：鼠标移入显示系统菜单
/// 选中背景（圆角），移出恢复透明。
final class MenuHoverView: NSView {

    /// 圆角半径，与系统菜单项高亮一致。
    var cornerRadius: CGFloat = 6

    /// hover 高亮背景色，默认使用系统 accent 色（macOS 11+ 菜单高亮样式）。
    var hoverBackgroundColor: NSColor = .controlAccentColor.withAlphaComponent(0.22)

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // 使用 .activeAlways，确保菜单打开（tracking 模式下菜单窗口非 key）也能收到事件。
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateBackground()
    }

    private func updateBackground() {
        wantsLayer = true
        layer?.backgroundColor = isHovering
            ? hoverBackgroundColor.cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = cornerRadius
    }
}

/// 菜单内嵌按钮的 hover 高亮按钮。
///
/// `NSButton` 在菜单中不会自动响应 hover；该子类通过 tracking area 在鼠标移入时
/// 编程式触发 push-in 高亮（`highlight(true)`），移出时恢复，提供与普通按钮一致的
/// hover 视觉反馈。
final class MenuHoverButton: NSButton {

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // 使用 .activeAlways，确保菜单打开（tracking 模式下菜单窗口非 key）也能收到事件。
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // 仅在有交互时触发高亮；禁用状态下无需反馈
        guard isEnabled else { return }
        highlight(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        highlight(false)
    }
}
