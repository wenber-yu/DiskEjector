import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 设置面板的**排版契约**测试。
///
/// **为什么需要**：面板高度是常量，六段内容的自然高度却随文案与内边距变化。
/// 历史上两者脱节（内容约 718pt vs 面板 520pt），结果是「关于 / 更新」两段被折叠线
/// 挡在滚动区外 —— 用户打开设置看不到它们，反馈为「设置界面排版不好看」。
/// 光靠人眼打开面板看一遍发现不了「几乎溢出」，所以把三件事钉成测试：
/// ① 头部 + 六段内容 + 底部留白 必须 ≤ 面板高度（放不下就会有内容被藏）；
/// ② 面板高度也不许虚高（差距超过一行就该同步收窄 token，而不是留一片空白）；
/// ③ 分隔线只出现在**段与段之间**（第一段上方不该有一条线顶着头部）。
///
/// 高度断言用「≤」而不是「==」：中文与英文文案长度不同，折行数可能不同，
/// 只要**任何语言下都放得下**就成立（`SettingsView` 仍保留 `ScrollView` 兜底）。
@MainActor
struct SettingsLayoutTests {

    private let panelWidth = DesignTokens.Size.settingsPanel.width

    /// 在给定宽度下渲染并返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(NSSize(width: width, height: 0))
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize
    }

    /// 渲染成位图后，统计「整行几乎都被绘制到」的行段数 —— 也就是横向分隔线的条数。
    private func horizontalDividerCount(_ view: some View, width: CGFloat) -> Int {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            let data = rep.bitmapData
        else { return -1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel
        var dividerRows: [Int] = []
        for y in 0..<h {
            var covered = 0
            for x in 0..<w where data[y * bpr + x * spp + 3] > 8 {
                covered += 1
            }
            // 分隔线是 `Color.primary.opacity(0.08)`：整行都有很低但不为零的 alpha。
            if Double(covered) / Double(w) > 0.9 { dividerRows.append(y) }
        }
        // 相邻像素行合并成一条线。
        var count = 0
        var previous = -10
        for y in dividerRows where y != previous + 1 {
            count += 1
            previous = y
        }
        return count
    }

    @Test func 面板高度放得下头部与全部六段() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth)
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        #expect(
            need <= DesignTokens.Size.settingsPanel.height,
            "头部 \(header.height) + 内容 \(sections.height) + 底留白 \(SettingsMetrics.bottomInset) = \(need)pt，超过面板 \(DesignTokens.Size.settingsPanel.height)pt——多出来的部分会被折叠线藏在滚动区外（「关于 / 更新」曾因此整个看不见）"
        )
    }

    @Test func 面板高度不留大片空白() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth)
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        let slack = DesignTokens.Size.settingsPanel.height - need
        #expect(
            slack >= 0 && slack <= 40,
            "面板比内容高出 \(slack)pt（超过一行）。要么把 DesignTokens.Size.settingsPanel.height 收窄到 \(need)pt，要么补内容——否则面板底部会留下一条明显的空白带"
        )
    }

    @Test func 分隔线只画在段与段之间() {
        // 六段 → 段间分隔线 5 条。第一段上方那条要是画出来，头部下面会顶着一条横线
        // （头部本身不含分隔线，设计稿的规则是 `.disk-section + .disk-section`）。
        let count = horizontalDividerCount(SettingsSectionsColumn { _ in }, width: panelWidth)
        #expect(
            count == 5,
            "测到 \(count) 条横向分隔线，期望 5 条（6 段之间各一条）；多出来的那条说明第一段上方也画了线"
        )
    }
}
