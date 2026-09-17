import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 标题栏「刷新」按钮**在刷新中必须有东西可看**。
///
/// ## 守的是哪个缺陷
///
/// 用户 2026-09-16 报告：「主窗口的刷新点击就消失了，刷新完成后就又出现了」。
/// 根因是 modifier 顺序：
///
/// ```swift
/// .overlay { if isRefreshing { ProgressView() } }
/// .opacity(isRefreshing ? 0 : 1)   // ← 排在 .overlay 之后，把 spinner 一起调透明
/// ```
///
/// `.opacity` 在 `.overlay` 后面，于是 overlay 里的 spinner 也被调成透明 ——
/// 刷新期间那块位置**什么都没有**。
///
/// 离屏实测（`.build/probe/spinneropacity.swift`，判据是墨迹像素数）：
/// 旧写法 **0**、`.opacity` 提到前面 **162**、if/else **162**、
/// 对照组「纯图标不透明」**224**、对照组「空视图」**0**。
///
/// ## 为什么旧写法能逃过测试
///
/// `isRefreshing` 原本是 `ContentView` 里的 `@State private`，测试够不着 ——
/// 「刷新中长什么样」这个状态**根本不可达**。所以修法不只是改顺序，
/// 还要把状态提成入参（``RefreshTitleBarButton``），这条断言才写得出来。
///
/// ⚠️ **变异验证**：把 `RefreshTitleBarButton.body` 改回
/// `.overlay { … }.opacity(isRefreshing ? 0 : 1)` 的写法，
/// `刷新中那块位置必须有东西可看` 立刻变红（实测墨迹 0）。
@MainActor
struct RefreshButtonTests {

    private var side: CGFloat { DesignTokens.Size.titleBarIconButton }
    private var box: CGSize { CGSize(width: side, height: side) }

    private func ink(_ isRefreshing: Bool) -> Int {
        OffscreenRender.inkCount(
            RefreshTitleBarButton(label: "刷新", isRefreshing: isRefreshing, action: {}), size: box)
    }

    // MARK: - 对照组（先过，后面的数字才有意义）

    /// **对照组不可省**：「0 命中」有两种含义 —— 真的没有，或**渲染通路根本没通**
    /// （`NSProgressIndicator` 是动画视图，`cacheDisplay` 有可能抓不到）。
    /// 这一条量到 >100 才说明下面那个 0 是「真的没有」。
    @Test func 渲染与计数通路有效() {
        let icon = OffscreenRender.inkCount(
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .medium))
                .frame(width: side, height: side),
            size: box)
        let blank = OffscreenRender.inkCount(Color.clear.frame(width: side, height: side), size: box)
        #expect(
            icon > 100,
            "对照组：不透明的箭头只量到 \(icon) 个墨迹像素 —— 渲染或计数通路坏了，下面所有数字都作废")
        #expect(blank == 0, "对照组：空视图量到 \(blank) 个墨迹像素 —— 计数把背景也算进去了")
    }

    // MARK: - 缺陷本体

    @Test func 刷新中那块位置必须有东西可看() {
        let refreshing = ink(true)
        print("  [刷新按钮] 常态墨迹 \(ink(false))、刷新中墨迹 \(refreshing)（盒 \(side)×\(side)）")
        #expect(
            refreshing > 0,
            """
            刷新中那 \(side)×\(side) 里一个墨迹像素都没有（实得 \(refreshing)）—— \
            用户看到的就是「点一下刷新按钮就没了」。最可能的原因：`.opacity` 又排到了 \
            `.overlay` 之后，把 spinner 一起调透明了。改回 if/else 直接换的写法。
            """
        )
    }

    @Test func 常态下箭头仍然画得出来() {
        let idle = ink(false)
        #expect(idle > 100, "常态（不刷新）下量到 \(idle) 个墨迹像素 —— 箭头没画出来")
    }

    /// 设计稿的硬要求：「按钮就地变 spinner、**保留原尺寸（换成 spinner 后不能塌陷）**」
    /// （`06-states.html` 的「推出中」）。
    @Test func 刷新中与常态的外框一样大() {
        for (name, flag) in [("常态", false), ("刷新中", true)] {
            let hosting = NSHostingView(
                rootView: RefreshTitleBarButton(label: "刷新", isRefreshing: flag, action: {}))
            hosting.layoutSubtreeIfNeeded()
            let fitted = hosting.fittingSize
            #expect(
                abs(fitted.width - side) < 0.001 && abs(fitted.height - side) < 0.001,
                """
                \(name)时外框是 \(fitted) —— 设计稿要求「换成 spinner 后不能塌陷」，\
                两个状态都必须是 \(side)×\(side)
                """
            )
        }
    }

    // MARK: - 出图开关（走查快照必须停在稳态）

    /// 标题栏右侧图标按钮的盒子（pt，原点左上）。
    ///
    /// **`fromRight: 0` 是最右边那个 —— 那是「设置」，不是「刷新」。**
    /// 从令牌推出：`800 − Spacing.md(12) − n × (28 + 2)`。
    /// 与出图里逐段扫描的结果一致（刷新 x 730…758、设置 x 760…788）。
    ///
    /// ⚠️ 本轮第一版就是在这里取反了：把 `0` 当成「刷新」，于是 `steady` 量到的是设置按钮
    /// （334），`steady >= 130` 和比值断言**双双恒真** —— 打印出来 `刷新 334 / 设置 174`
    /// 才发现。下面的「参照物自检」就是为此加的。
    private func titleBarButtonBox(fromRight index: Int) -> CGRect {
        let side = DesignTokens.Size.titleBarIconButton
        let gap: CGFloat = 2  // ContentView.titleBar 里两个按钮的 HStack spacing（字面量）
        let right =
            DesignTokens.Size.mainWindow.width - DesignTokens.Spacing.md
            - CGFloat(index) * (side + gap)
        return CGRect(
            x: right - side, y: 0, width: side,
            height: DesignTokens.Size.titleBarBandHeight)
    }

    /// 走查快照 `main-window-*.png` 里刷新按钮的位置**必须画箭头**。
    ///
    /// ## 守的是哪个缺陷
    ///
    /// ``SnapshotRenderTests`` 的 `cacheDisplay` 是**同步**截的，而 `ContentView` 的
    /// `.task` 会自动 `await refreshDisks()`。截图因此落在「盘已经列出来、刷新还没收尾」
    /// 那个窗口里 —— 走查图右上角画的是 **spinner**，而设计稿 `01-main-window.html`
    /// 里是箭头。连跑三次指纹完全一致（`4fde925d31bc`），是**确定性**的，不是随机。
    ///
    /// 修法：给 `ContentView` 开一个 ``ContentView/skipsInitialRefresh``（默认 `false`，
    /// 生产行为不变），出图侧传 `true`。**这条断言钉住「开关真的生效」** ——
    /// 有人把 `.task` 里那句 `guard !skipsInitialRefresh` 删掉就变红。
    ///
    /// ## 判据为什么是「墨迹个数」而不是「峰值亮度」
    ///
    /// 第一版照搬真机量到的「箭头峰值 245 / spinner 160」写死在 200 上 ——
    /// **离屏出图里那个数根本不存在**（同一个 `mutedForeground` 图标只有 168）。
    /// 在出图环境里重测三种判据后选了墨迹个数，选型表见
    /// ``OffscreenRender/brightPixels(_:size:in:above:appearance:background:)``。
    @Test func 出图开关让刷新按钮停在箭头() {
        let gearBox = titleBarButtonBox(fromRight: 0)
        let refreshBox = titleBarButtonBox(fromRight: 1)
        let box = CGSize(width: refreshBox.width, height: refreshBox.height)
        let whole = CGRect(origin: .zero, size: box)
        // 与出图里的玻璃底色（峰值 78）接近，保证对照组和被测对象在同一档底色上。
        let glass = Color(nsColor: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1))

        // 对照组：同一判据下「箭头」与「spinner」必须先分得开，
        // 否则下面那条断言就没有分辨力（本仓库在这上面栽过不止一次）。
        let arrow = OffscreenRender.brightPixels(
            RefreshTitleBarButton(label: "刷新", isRefreshing: false, action: {}),
            size: box, in: whole, appearance: .darkAqua, background: glass)
        let spinner = OffscreenRender.brightPixels(
            RefreshTitleBarButton(label: "刷新", isRefreshing: true, action: {}),
            size: box, in: whole, appearance: .darkAqua, background: glass)

        // 被测对象：出图开关下的主窗口，以及**同款图标的设置按钮**当参照。
        let steady = OffscreenRender.brightPixels(
            ContentView(skipsInitialRefresh: true),
            size: DesignTokens.Size.mainWindow, in: refreshBox, appearance: .darkAqua,
            background: .clear)
        let gear = OffscreenRender.brightPixels(
            ContentView(skipsInitialRefresh: true),
            size: DesignTokens.Size.mainWindow, in: gearBox, appearance: .darkAqua,
            background: .clear)

        print("  [走查快照] 对照组 箭头 \(arrow) / spinner \(spinner)；出图 刷新 \(steady) / 设置 \(gear)")

        #expect(
            arrow - spinner >= 20,
            """
            对照组没分开：箭头 \(arrow) 个墨迹像素、spinner \(spinner) 个。\
            差值必须 ≥20（出图环境实测 174 vs 93），否则本判据无法区分「画的是箭头还是 spinner」。
            """
        )
        // **参照物自检**：设置按钮画的是齿轮（同款图标里笔画最密的那个），
        // 墨迹必须 ≥280（实测 334）。量到更少说明**取错了盒子**或渲染坏了 ——
        // 这条是给上面两条兜底的：盒子取反时它们会双双恒真（本轮踩到）。
        #expect(
            gear >= 280,
            """
            设置按钮那一格只有 \(gear) 个墨迹像素（实测 334）—— \
            多半是 `titleBarButtonBox(fromRight:)` 取错了盒子（0 是最右边的**设置**），\
            或者渲染没画出来。此时下面两条断言都不可信。
            """
        )
        #expect(
            steady >= 130,
            """
            出图时刷新按钮处只有 \(steady) 个墨迹像素（箭头 ≈174、spinner ≈93、空白 0）—— \
            `ContentView(skipsInitialRefresh: true)` 没停在稳态。最可能的原因：\
            `.task` 里那句 `guard !skipsInitialRefresh` 被删了，自动刷新又跑起来了。
            """
        )
        // **相对参照**：设置按钮画的是同款图标（同字号、同字重、同颜色），
        // 刷新按钮的墨迹必须与它同量级（出图实测 174 vs 334 = 0.52；spinner 是 0.28）。
        // 加这一条是为了让判据**跟着令牌走** —— 以后图标字号/颜色变了，
        // 上面那个绝对下限 130 会失效，这条仍然成立。
        #expect(
            Double(steady) / Double(gear) >= 0.4,
            """
            刷新按钮墨迹 \(steady) 只有设置按钮 \(gear) 的 \
            \(String(format: "%.2f", Double(steady) / Double(gear))) —— \
            两个按钮是**同款图标**，量级应当相当（实测 0.52）。偏小说明刷新那格画的是 spinner（0.28）。
            """
        )
    }
}
