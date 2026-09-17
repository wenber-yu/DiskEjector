import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 主窗口标题栏**水平方向**的对称契约：红灯中心距左 == 设置按钮中心距右 == 26pt。
///
/// **为什么单独一个文件**：这是 2026-09-17 用户报的
/// 「红灯距窗口左边框与设置按钮距右边框不一致」。量出来差 **10pt** ——
/// 与同一天修的竖直方向（也是 10pt）**是同一个根因的两个方向**：
/// macOS 把交通灯摆在「标准 28pt 标题栏」的位置（中心距顶 16、**中心距左 16**），
/// 而设计稿两个方向都要 26。上一轮只修了竖直方向，水平方向漏了。
///
/// > **给团队的教训**：发现「代码在迁就系统默认值」这类根因时，
/// > **要把同一个来源的所有方向一次查完**，否则同一个 bug 会分几次报上来。
///
/// **三条互补的守卫**（缺一条这个 bug 就能回来）：
/// 1. 这里（单测）：``AppDelegate/trafficLightNudge(currentCenter:windowHeight:)``
///    的算术与**幂等性** + 右侧按钮的**渲染位置**；
/// 2. 真机自检 `--preview-main-window-keys`：量真实窗口里红灯的中心；
/// 3. 令牌自洽：右侧按钮中心与设计稿锚点 ``DesignTokens/Size/titleBarInsetCenter`` 相等。
///
/// ⚠️ **红灯本身离屏问不到** —— 离屏没有窗口，也就没有 `standardWindowButton`。
/// 所以「红灯真的在 26pt」只能由真机自检守，这里守的是「算出来的偏移是对的」。
@MainActor
struct TrafficLightAlignmentTests {

    /// 系统**默认**把红灯放的位置（真机实测 2026-09-17，窗口 800×520）。
    ///
    /// 窗口坐标原点在左下：中心距左 16 → x = 16；中心距顶 16 → y = 520 − 16 = 504。
    private let systemDefaultCenter = CGPoint(x: 16, y: 504)
    private let windowHeight: CGFloat = 520

    private var targetCenter: CGFloat { DesignTokens.Size.titleBarInsetCenter }

    // MARK: - 偏移算术（纯函数，可离屏测）

    /// 从系统默认位置出发，应算出「往右 10、往下 10」。
    ///
    /// **符号是这条测试的重点**：`NSTitlebarView` **不是** flipped（原点在左下），
    /// 与窗口坐标 y 同向，所以「往下挪 10pt」得到的 `dy` 是 **−10**，
    /// 结果可以直接喂给 `frame.offsetBy`。算反了会差 20pt。
    @Test func 从系统默认位置算出的偏移是右下各十点() {
        let nudge = AppDelegate.trafficLightNudge(
            currentCenter: systemDefaultCenter, windowHeight: windowHeight)
        #expect(
            abs(nudge.width - 10) < 0.001,
            "水平偏移应是把中心从 16 补到 \(targetCenter)，即 +10，实得 \(nudge.width)")
        #expect(
            abs(nudge.height + 10) < 0.001,
            """
            竖直偏移应为 −10（窗口坐标 y 减小 = 往下挪），实得 \(nudge.height)。\
            若得到 +10，说明把 `NSTitlebarView` 当成 flipped 处理了 —— 灯会跑到窗口外。
            """)
    }

    /// **幂等**：已经在对的位置时返回零偏移。
    ///
    /// 这条守的是「反复调用不会把灯越推越远」—— 装配处会在上屏前后各调一次，
    /// 不幂等就会变成 +20。
    @Test func 已经对齐时返回零偏移() {
        let aligned = CGPoint(x: targetCenter, y: windowHeight - DesignTokens.Size.titleBarBandHeight / 2)
        let nudge = AppDelegate.trafficLightNudge(
            currentCenter: aligned, windowHeight: windowHeight)
        #expect(
            abs(nudge.width) < 0.001 && abs(nudge.height) < 0.001,
            "已在目标位时应返回零偏移，实得 \(nudge) —— 不幂等会让每次调用都再推一次")
    }

    /// **被拨回一部分时只补差额** —— 这条是本次 bug 的直接回归守卫。
    ///
    /// **为什么会有这种状态**：`NSHostingView` 上屏时会重排，把灯的 x **拨回 4pt**
    /// （实测请求 +10、实得 +6，中心落在 22 而不是 26）。写死的补偿量看不见这件事 ——
    /// 它只在「对齐之前」算一次，之后对不对没人知道。
    ///
    /// 改成「量当前位置再补差额」之后，只要再调一次就能从 22 收敛到 26。
    @Test func 被布局拨回一部分时只补差额() {
        let partial = CGPoint(x: 22, y: windowHeight - DesignTokens.Size.titleBarBandHeight / 2)
        let nudge = AppDelegate.trafficLightNudge(
            currentCenter: partial, windowHeight: windowHeight)
        #expect(
            abs(nudge.width - 4) < 0.001,
            """
            中心已在 22 时应只补 +4（到 \(targetCenter)），实得 \(nudge.width)。\
            若仍是 +10，说明又变回写死的补偿量 —— 上屏重排拨回 4pt 的情况会永久差 4pt。
            """)
        #expect(
            abs(nudge.height) < 0.001,
            "竖直方向已经对了就不该再动，实得 \(nudge.height)")
    }

    // MARK: - 令牌自洽

    /// 右侧设置按钮的**光学中心**必须落在设计稿锚点上。
    ///
    /// 判据用**中心**而不是「盒子边缘」：红灯是 12pt 圆点、设置按钮是 28pt 的盒子
    /// （里面 14pt 图标），两者贴边留白天然不同 —— 边缘会差 8pt，但光学上是齐的。
    /// 拿边缘去比会得出「设计稿自己就不对称」的错误结论，然后改错实现。
    @Test func 设置按钮中心落在设计稿锚点上() {
        let center =
            DesignTokens.Spacing.titleBarTrailing
            + DesignTokens.Size.titleBarIconButton / 2
        #expect(
            abs(center - targetCenter) < 0.001,
            """
            设置按钮中心距右 \(center)pt ≠ 设计稿锚点 \(targetCenter)pt。\
            调 DesignTokens.Spacing.titleBarTrailing（现在 \(DesignTokens.Spacing.titleBarTrailing)）。
            """
        )
        // 盒子不能贴到窗口边：留白至少要有图标本身的一半，否则图标会被窗口圆角啃到。
        #expect(
            DesignTokens.Spacing.titleBarTrailing > 0,
            "标题栏右侧留白必须大于 0")
    }

    // MARK: - 量真实渲染

    /// 离屏渲染主窗口，量**右侧设置按钮的墨迹**离窗口右边缘有多远。
    ///
    /// **为什么必须有这条**：上面几条测的都是常量与算术 ——
    /// 万一 `ContentView` 根本没用 `titleBarTrailing`（比如被后来者改回 `Spacing.md`），
    /// 令牌自洽那条照样是绿的。**只有量渲染结果才知道按钮真的在哪。**
    ///
    /// **为什么只量按钮、不量红灯**：红灯是系统画的，离屏没有窗口就没有交通灯。
    /// 那一半由真机自检 `--preview-main-window-keys` 守。
    @Test func 设置按钮墨迹中心距右边缘约二十六点() {
        // ⚠️ **高度必须给足整个窗口**（520），不能只给标题栏的 52：
        // 给 52 时 SwiftUI 会把整棵视图压进这个高度里，标题栏的实际布局会变
        // （实测：给 52 时右侧扫不到任何墨迹）。这与 `TitleBarBaselineTests` 的做法一致。
        let width = DesignTokens.Size.mainWindow.width
        let height = DesignTokens.Size.mainWindow.height
        let scale: CGFloat = 2

        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: ContentView(skipsInitialRefresh: true).background(Color.white))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(width * scale),
                pixelsHigh: Int(height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else {
            Issue.record("离屏位图分配失败")
            return
        }
        rep.size = CGSize(width: width, height: height)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        // 只扫标题栏中段，避开顶部留白与底部 Hairline（Hairline 横跨整宽，会把右边缘算成墨迹）。
        let y0 = Int(12 * scale)
        let y1 = Int(40 * scale)
        var lastCol: Int?
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            let hasInk = (y0..<y1).contains { y in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75
            }
            if hasInk {
                lastCol = x
                break
            }
        }
        guard let lastCol else {
            Issue.record("标题栏右侧没扫到任何墨迹 —— 渲染没成功，这条断言不能算通过")
            return
        }
        let inkRight = CGFloat(lastCol) / scale
        let gapFromRight = width - inkRight
        // 图标 14pt 居中于 28pt 盒子 → 墨迹右边缘比盒子右边缘再往里 7pt。
        let expectedGap =
            DesignTokens.Spacing.titleBarTrailing
            + (DesignTokens.Size.titleBarIconButton - 14) / 2
        print("  [设置按钮] 墨迹右边缘距窗口右边缘 \(gapFromRight)pt（期望 ≈\(expectedGap)pt）")
        #expect(
            abs(gapFromRight - expectedGap) <= 2,
            """
            设置按钮墨迹右边缘距窗口右边缘 \(gapFromRight)pt，期望 ≈\(expectedGap)pt\
            （右边距 \(DesignTokens.Spacing.titleBarTrailing) + 28pt 盒里 14pt 图标的半圈留白）。\
            差得多说明 `ContentView` 的标题栏右侧 padding 被改了，或按钮尺寸不是 28pt。
            """
        )
    }
}
