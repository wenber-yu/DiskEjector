import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 两块玻璃（主窗口 / 设置面板）的标题与**系统红绿灯**的纵向对齐契约。
///
/// **为什么单独一个文件**：这个缺陷横跨两个视图，而两边原本的写法并不一致 ——
/// 主窗口 `titleBar` 是「28pt 内容带 + 24pt 留白」（标题中心距顶 14），
/// 设置面板是「52pt 整体居中」（标题中心距顶 26），而系统红绿灯的中心在距顶 **16pt**
/// （真机实测：三个按钮并集 `y 9…23`，窗口坐标原点在左下）。
/// 于是两个标题各偏 2pt / 10pt，用户看到的正是「标题没有和红绿灯在同一水平基线上」。
///
/// 修法是让两边共用 ``DesignTokens/Size/titleBarBandHeight``（32 = 16 × 2），
/// 本文件把「共用」与「落在正中」这两件事钉住。
///
/// **为什么必须量像素**：SwiftUI 的 `Text` 在 AppKit 视图树里没有任何对应视图
/// （实测 `NSHostingView.subviews` 是空的、整棵树里找不到 `NSTextField`、
/// 无障碍子树也是懒建的），「标题的垂直中心在哪」问不到 AppKit，只能看**渲染结果**。
///
/// **红绿灯本身的位置离屏问不到**（离屏没有窗口就没有交通灯），那一半由真机自检
/// `--preview-main-window-keys` 每次量一遍（见 `AppDelegate.checkTrafficLightBaseline`）。
/// 两个方向合起来才闭环：真机断言「系统灯 == 内容带中心」，这里断言「我们的标题 == 内容带中心」。
///
/// ⚠️ **设置面板这一半从 2026-09-16 起换了理由**（`DESIGN-SPEC.md` §8.17）：
/// 它**不再画红绿灯**（`SettingsWindow` 把三个系统按钮藏了），所以「与系统灯对齐」
/// 这回事在它身上不存在。内容带仍取 32，是为了让**两个窗口的头部内容落在同一条水平线上**
/// —— 设计稿把 `.titlebar`（主窗口）与 `.shead`（设置面板）写成同样的
/// `height: 52px; align-items: center`，意图就是「两块玻璃的头部一模一样」。
/// 断言本身不变：它守的是「头部内容在内容带里居中」，而不是「为什么是 32」。
@MainActor
struct TitleBarBaselineTests {

    /// 内容带中心 —— 两块玻璃的标题墨迹中心都该落在它上面。
    private var bandCenter: CGFloat { DesignTokens.Size.titleBarBandHeight / 2 }

    /// 标题墨迹中心相对内容带中心允许的偏差窗口。**数字是实测出来的，不是拍的。**
    ///
    /// **为什么不是对称的 ±ε**：15pt 系统字体的行盒 19pt，而 CJK 字形的墨迹**不在行盒正中**。
    /// 实测（离屏，scale 2）：主窗口「外置磁盘」墨迹 `9.5…23.5`（中心 16.5，比带中心低 0.5）、
    /// 设置面板「设置」墨迹 `10.0…23.5`（中心 16.75，低 0.75）—— 同一字号同一字重，
    /// 差在字形本身。所以下界只留 0.5pt：比这更低就已经不是字形度量能解释的了。
    ///
    /// **上界为什么卡在 1.5**：要守的回归是「内容带高度被改回旧写法」——
    /// 主窗口旧写法 `.frame(height: 28)` + `.padding(.bottom, 24)` 会把带中心抬到 14
    /// （墨迹随之落到 14.5，即 **−1.5**），设置面板旧写法（在 52pt 里整体居中）压到 26（**+10.75**）。
    /// 窗口必须**容得下实测的 +0.75、挡得住 −1.5**，所以上界取 1.5。
    ///
    /// ⚠️ **变异验证记录**：容差原本写成对称的 ±1.5，结果主窗口那条**变异后依然通过**
    /// （−1.5 恰好落在边界内）—— 断言看着在守，其实守不住。改成这个窗口后复验：
    /// 改回 `.frame(height: 28)` 立刻变红。**动这几个数之前先跑一遍变异验证。**
    private let bandCenterSlackLow: CGFloat = -0.5
    private let bandCenterSlackHigh: CGFloat = 1.5

    // MARK: - 量墨迹

    /// 量出**标题文字**的墨迹范围（列 + 行），两步走，避免把图标 / 按钮算进来。
    ///
    /// 1. 在标题栏那几行里扫**左半侧**的首列墨迹 —— 它一定是标题的第一个字；
    /// 2. 从首列往右取 `titleWidth` pt，在这几列里扫首 / 末行墨迹 —— 就是标题的上下界。
    ///
    /// 用「首列墨迹」而不是写死的 x，是为了不依赖标题文案与字体的具体宽度。
    ///
    /// ## 出图与读像素都走 `OffscreenRender`（2026-09-23 收敛，§8.131）
    ///
    /// 本函数原先自带一套 `NSHostingView` + `NSBitmapImageRep(bitmapDataPlanes:)` + 逐像素
    /// `colorAt`，与 ``OffscreenRender/bitmap(_:size:appearance:background:)`` **逐字相同**。
    /// 现在只出图**一次**（原先两步各出一遍）并复用同一张位图 —— 这也是
    /// ``OffscreenRender/inkColumnRange(_:rows:maxX:scale:)`` 那两条要接 `rep` 的原因。
    ///
    /// ## 两处「必须避开」的边界
    ///
    /// - **纵向必须避开标题栏底部那条 `Hairline`**：它横跨整宽，会把 x=0 也算成墨迹
    ///   ⇒ 调用方传的 `rows` 上界是 `容器高 − 8`。
    /// - **横向只看左半侧**（`maxX: 300`）：标题栏右侧的图标按钮比标题更靠右，
    ///   不限制的话首列墨迹仍是标题（没问题），但**末列会变成按钮**。
    ///
    /// **坐标系**：位图原点在**左上角**（与 `NSView` 相反），而 `cacheDisplay` 会把
    /// flipped 的 `NSHostingView` 按视觉方向画进位图 —— 所以 y 直接就是「距顶」，不需要再翻。
    /// 这一点由本文件的断言**自证**：算错方向时中心会落在 `height − 16`（≈36），测试立刻红。
    private func titleInk(
        _ view: some View, width: CGFloat, height: CGFloat,
        rows: ClosedRange<CGFloat>, who: String, titleWidth: CGFloat = 40
    ) -> (columns: (first: CGFloat, last: CGFloat), rows: (first: CGFloat, last: CGFloat))? {
        guard
            let rep = OffscreenRender.bitmap(view, size: CGSize(width: width, height: height)),
            let cols = OffscreenRender.inkColumnRange(rep, rows: rows, maxX: 300),
            let inkRows = OffscreenRender.inkRowRange(
                rep, columns: cols.first...(cols.first + titleWidth), rows: rows)
        else { return nil }
        // **自证字段**：把量到的四个数打出来。像素量测最容易的失败方式是「量错了东西」
        // （列窗口落在空白上、纵向范围把 Hairline 包进来），那种失败与「对齐坏了」
        // 长得一模一样 —— 有这四个数才能当场分辨。
        print(
            "  [\(who)] 标题墨迹 列 \(cols.first)…\(cols.last) 行 \(inkRows.first)…\(inkRows.last) "
                + "中心 \((inkRows.first + inkRows.last) / 2)（高 \(inkRows.last - inkRows.first)）"
        )
        return (cols, inkRows)
    }

    // MARK: - 令牌之间不许打架

    /// 三个数字必须自洽：`内容带 + 留白 == 标题栏总高 == 设置面板头部高`。
    ///
    /// 这条**不量像素**，抓的是「改了带高忘了改总高」这类漂移。
    /// 例如把 `titleBarBandHeight` 调成 34（若将来 macOS 把灯挪到 17pt）却忘了减留白，
    /// 标题栏就变成 54pt，磁盘列表整体下移 2pt —— 那种偏差肉眼看不出，但两个窗口的
    /// 头部会对不齐。真正的外框尺寸另有 `MainWindowTests` / `SettingsWindowTests` 守。
    @Test func 内容带加留白等于设计稿的标题栏总高() {
        let sum = DesignTokens.Size.titleBarBandHeight + DesignTokens.Size.titleBarBandBottomPadding
        #expect(
            abs(DesignTokens.Size.titleBarHeight - sum) < 0.001,
            "标题栏总高 \(DesignTokens.Size.titleBarHeight) ≠ 内容带 \(DesignTokens.Size.titleBarBandHeight) + 留白 \(DesignTokens.Size.titleBarBandBottomPadding) = \(sum)。设计稿 `.titlebar { height: 52px }` 会被破坏，标题栏下方内容整体位移"
        )
        #expect(
            abs(SettingsMetrics.headerHeight - DesignTokens.Size.titleBarHeight) < 0.001,
            "设置面板头部高 \(SettingsMetrics.headerHeight) ≠ 主窗口标题栏 \(DesignTokens.Size.titleBarHeight)。设计稿把两者写成同一条 `.win` 规则，两块玻璃的头部必须一样高"
        )
        #expect(
            DesignTokens.Size.titleBarBandHeight >= DesignTokens.Size.titleBarIconButton,
            "内容带 \(DesignTokens.Size.titleBarBandHeight) 比标题栏里的 28pt 图标按钮还矮 —— 按钮会被压扁"
        )
    }

    // MARK: - 两块玻璃的标题各自落在内容带正中

    /// 设置面板：头部标题（「设置」）的墨迹垂直中心必须落在内容带中心。
    ///
    /// 偏下约 10pt 就是「头部在 52pt 里整体居中」（中心 26）—— 用户报告的正是这个。
    @Test func 设置面板标题墨迹中心落在内容带中心() {
        let headerHeight = SettingsMetrics.headerHeight
        guard
            let ink = titleInk(
                SettingsHeaderBar(onDone: {}),
                width: DesignTokens.Size.settingsPanel.width, height: headerHeight,
                rows: 0...(headerHeight - 8), who: "设置面板")
        else {
            Issue.record("设置面板头部离屏渲染后，标题那几列没扫到任何墨迹 —— 渲染没成功，或列窗口落在了空白处，这条断言不能算通过")
            return
        }
        assertIsTextLine(ink.rows, who: "设置面板头部标题", containerHeight: headerHeight)

        let center = (ink.rows.first + ink.rows.last) / 2
        let delta = center - bandCenter
        #expect(
            delta >= bandCenterSlackLow && delta < bandCenterSlackHigh,
            """
            「设置」墨迹的纵向范围 \(ink.rows.first)…\(ink.rows.last)pt，中心 \(center)pt，\
            比内容带中心 \(bandCenter)pt 偏 \(delta)pt（允许 \(bandCenterSlackLow)…\(bandCenterSlackHigh)）。\
            偏下≈10 说明头部又变回「在 \(headerHeight)pt 里整体居中」（中心 \(headerHeight / 2)）；\
            偏到 \(headerHeight - bandCenter) 附近说明量墨迹时 y 轴方向反了。
            """
        )
    }

    /// 主窗口：标题栏标题（「外置磁盘」）的墨迹垂直中心必须落在内容带中心。
    ///
    /// 与设置面板同一条判据 —— 两边共用同一个令牌，这条测试就是「共用」的守卫。
    @Test func 主窗口标题墨迹中心落在内容带中心() {
        let height = DesignTokens.Size.mainWindow.height
        guard
            let ink = titleInk(
                ViewFixtures.mainWindow(),
                width: DesignTokens.Size.mainWindow.width, height: height,
                rows: 0...(DesignTokens.Size.titleBarHeight - 8), who: "主窗口")
        else {
            Issue.record("主窗口离屏渲染后，标题那几列没扫到任何墨迹 —— 渲染没成功，或列窗口落在了空白处，这条断言不能算通过")
            return
        }
        assertIsTextLine(ink.rows, who: "主窗口标题栏标题", containerHeight: DesignTokens.Size.titleBarHeight)

        let center = (ink.rows.first + ink.rows.last) / 2
        let delta = center - bandCenter
        #expect(
            delta >= bandCenterSlackLow && delta < bandCenterSlackHigh,
            """
            「外置磁盘」墨迹的纵向范围 \(ink.rows.first)…\(ink.rows.last)pt，中心 \(center)pt，\
            比内容带中心 \(bandCenter)pt 偏 \(delta)pt（允许 \(bandCenterSlackLow)…\(bandCenterSlackHigh)）。\
            偏到 −1.5 附近说明这里又变回 `frame(height: 28)` + `padding(.bottom, 24)` —— \
            旧写法比红绿灯高 2pt，正是用户报告的「主窗口标题没和红绿灯同一基线」。
            """
        )
    }

    // MARK: - 自证

    /// 断言量到的确实**是一行文字**，而不是空白、整块填充或底部分隔线。
    ///
    /// **为什么必须有这一步**：这个文件里所有结论都建立在「扫到的墨迹就是标题」之上。
    /// 列窗口选歪（落在 `Color.clear` 让位块上）、渲染没完成、或纵向范围把 `Hairline`
    /// 包了进来，量出来的中心都会是另一个数 —— 而那种失败**看起来也像断言失败**，
    /// 会被误读成「对齐坏了」。先卡住形状，失败信息才不会骗人。
    private func assertIsTextLine(
        _ rows: (first: CGFloat, last: CGFloat), who: String, containerHeight: CGFloat
    ) {
        let inkHeight = rows.last - rows.first
        #expect(
            inkHeight >= 8 && inkHeight <= 24,
            """
            \(who)的墨迹纵向跨 \(inkHeight)pt（\(rows.first)…\(rows.last)）—— 这不像一行 15pt 文字\
            （实测约 14pt）。若接近容器高 \(containerHeight)pt，说明把底部的 `Hairline` 也扫了进来；\
            若接近 0，说明扫到的是抗锯齿边缘。下面的对齐断言都无意义。
            """
        )
        #expect(
            rows.last < containerHeight,
            "\(who)的墨迹下界 \(rows.last)pt 已经触到容器底 \(containerHeight)pt —— 扫描范围没避开 `Hairline`"
        )
    }

    // 「52 这个数是从哪来的」不在这里答 —— 它属于**窗口尺寸同源**那一族，
    // 与 `--w-main` / `--h-main` / `--w-popover` 收在同一张表里，见
    // `DesignSizeParityTests.设计稿与实现的尺寸必须同数()`。
    // 这里只守「内容带 + 留白 = 总高」的**内部自洽**。
}
