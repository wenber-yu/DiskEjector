import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 主窗口**窗口层面**的契约。
///
/// 与 `OnboardingWindowTests` 同一个理由：那边量的是「视图要多大」，这边量的是
/// 「窗口给了多大、以及宿主有没有偷偷改动内容的排版」。两者可以**同时正确又同时出错**。
///
/// ## 它抓到过两个真缺陷（2026-09-15，用户截图报告「主窗口的红绿灯工具栏成了纯透明」）
///
/// 顶部 32pt 露出桌面，是**两个独立缺陷叠加**的结果 —— 各自都能单独存在：
///
/// 1. **宿主把标题栏安全区算进了尺寸**。`.fullSizeContentView` 的窗口会向 SwiftUI 报出
///    「顶部 32pt 被标题栏占着」，于是 `NSHostingView` 的固有尺寸 = 内容 520 + 安全区 32
///    = **552**，而它的默认 `sizingOptions` 会把固有尺寸回推给窗口 ——
///    **窗口在上屏那一刻被撑到 800×552**（设计稿 520）。
///    修法一句：`hosting.safeAreaRegions = []`（与引导面板同一处理）。
///    **这个缺陷旧版就存在**，只是一直没人量过窗口高度：那时玻璃挂在 `ZStack` 里跟着被撑到
///    552，肉眼看不出来。
/// 2. **玻璃只拿到内容的 520**。玻璃从 `ZStack` 改挂 `.background(...)` 之后，
///    「玻璃铺满整窗」变成了依赖「窗口高恰好等于内容高」这个巧合 —— 巧合一破就露底。
///    修法：body 改成「内层定设计稿尺寸、外层填满宿主、玻璃挂在外层」。
///
/// ## 为什么单测测得到，而离屏快照测不到
///
/// `SnapshotRenderTests` 渲染的视图**没有窗口**，于是既没有安全区、窗口也不会被回推撑高
/// （实测离屏窗口恒为 520）—— 快照永远是「满窗玻璃、全绿」，对这两个缺陷**结构性失明**。
///
/// 但离屏**仍然建得出 `NSVisualEffectView`**（`layoutSubtreeIfNeeded()` 就够），
/// 所以「玻璃有没有铺满宿主」可以脱离窗口断言：给它一个**比设计稿高 32pt 的宿主**，
/// 看玻璃跟不跟得上。这正是缺陷 2 的捕手，也是老结构唯一会红的地方。
///
/// ## 三条断言的力度不同，别拿一条的绿替另一条背书
///
/// - `玻璃必须铺满比设计稿高的宿主`：缺陷 2 与 body 结构的捕手，**充分条件**；
/// - `宿主不得把标题栏安全区算进尺寸`：抓缺陷 1 的**后果**（固有尺寸 552）；
/// - `宿主必须关掉安全区`：抓缺陷 1 的**机制**。与上一条在当前实现下等价，
///   但若将来有人引入 `sizingOptions`，上一条会因固有尺寸变成 -1 而失效，这条仍然有效。
///
/// 真机上的最终裁决仍是 `--preview-main-window-keys`（量真实窗口尺寸与玻璃覆盖）。
@MainActor
struct MainWindowTests {

    private let expected = DesignTokens.Size.mainWindow

    /// 建主窗口，**不上屏**（单测不抢用户焦点，与 `AlertLayoutTests` / `OnboardingWindowTests` 一致）。
    ///
    /// 走 `AppDelegate.makeMainWindow()` —— **真机与单测同一条装配路径**。
    /// 单测自己再搭一个「差不多的窗口」等于什么都没验。
    private func makeWindow() -> NSWindow {
        // 建窗口、建 hosting 都需要 `NSApplication.shared` 存在。
        _ = NSApplication.shared
        return AppDelegate.makeMainWindow()
    }

    private func hosting(of window: NSWindow) -> NSHostingView<ContentView>? {
        window.contentView as? NSHostingView<ContentView>
    }

    /// 玻璃覆盖范围：视图树里 `.underWindowBackground` 材质那块，统一到 `host` 坐标系。
    ///
    /// 判据不是看颜色（离屏取不到桌面），而是**问 AppKit 那块 `NSVisualEffectView` 占多大**。
    /// 系统标题栏自带的玻璃是别的材质档，所以能精确挑出「我们自己画的那块」。
    private func glassCoverage(in host: NSView) -> CGRect {
        host.glassEffectFrames
            .filter { $0.material == .underWindowBackground }
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
    }

    private func covers(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        outer.minX <= inner.minX + tolerance
            && outer.minY <= inner.minY + tolerance
            && outer.maxX >= inner.maxX - tolerance
            && outer.maxY >= inner.maxY - tolerance
    }

    // MARK: - 尺寸

    @Test func 窗口尺寸为设计稿() {
        let window = makeWindow()
        #expect(
            window.frame.width == expected.width,
            "窗口宽 \(window.frame.width)，设计稿 \(expected.width)")
        #expect(
            window.frame.height == expected.height,
            "窗口高 \(window.frame.height)，设计稿 \(expected.height)")
        #expect(!window.isVisible, "建窗不该上屏 —— 单测跑到这里窗口可见就是抢了用户焦点")
    }

    /// **缺陷 1 的后果**：宿主不得要求比设计稿更高的尺寸。
    ///
    /// 固有尺寸 = 内容 + 安全区（520 + 32 = 552），`sizingOptions` 默认会把它回推给窗口。
    @Test func 宿主不得把标题栏安全区算进尺寸() {
        let window = makeWindow()
        guard let hosting = hosting(of: window) else {
            Issue.record("主窗口的 contentView 不是 NSHostingView<ContentView>")
            return
        }
        let intrinsic = hosting.intrinsicContentSize.height
        #expect(
            intrinsic <= expected.height + 0.5,
            "宿主固有高度 \(intrinsic)，设计稿 \(expected.height) —— 多的 32pt 就是标题栏安全区")
    }

    /// **缺陷 1 的机制**：安全区不关，SwiftUI 会把内容**整体下推 32pt**
    /// —— 标题文字与红绿灯错位，而窗口尺寸可能还是对的。
    ///
    /// 这是**配置断言**，不是效果断言：那个效果（内容起点下移 32pt）在离屏拿不到稳定的观测量。
    /// 与 `OnboardingWindowTests.挂到窗口上之后量高不变` 互补：那边断言后果，这边钉住机制。
    @Test func 宿主必须关掉安全区() {
        let window = makeWindow()
        guard let hosting = hosting(of: window) else {
            Issue.record("主窗口的 contentView 不是 NSHostingView<ContentView>")
            return
        }
        if #available(macOS 13.3, *) {
            #expect(
                hosting.safeAreaRegions == [],
                "宿主没关掉安全区 —— 窗口会让 SwiftUI 把内容整体下推 32pt，标题就与红绿灯错位了")
        }
    }

    /// **缺陷 2 的捕手**：玻璃必须铺满宿主，而不是「刚好等于内容的 800×520」。
    ///
    /// 用一个**比设计稿高 32pt 的宿主**来问 —— 这正是真机上窗口被撑到 552 时的样子。
    /// 老结构（单层 `frame(width:height:)`、玻璃挂在它里面）在这里得到
    /// 「玻璃 y 16…536、上下各露 16pt」；新结构（内层定设计稿尺寸、外层填满宿主、
    /// 玻璃挂在外层）铺满。
    ///
    /// 容差 0.5pt 留给坐标取整。
    @Test func 玻璃必须铺满比设计稿高的宿主() {
        let host = NSHostingView(rootView: ContentView())
        // 与 `makeMainWindow` 的配置保持一致：这里问的是**视图结构**，不是宿主配置。
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }

        host.frame = NSRect(
            x: 0, y: 0,
            width: expected.width,
            height: expected.height + 32
        )
        host.layoutSubtreeIfNeeded()

        let glass = glassCoverage(in: host)
        #expect(
            !glass.isNull,
            "宿主视图树里没找到自定义玻璃（material=.underWindowBackground）—— 背景根本没铺上")
        #expect(
            covers(glass, host.bounds),
            "宿主 \(host.bounds) 里的玻璃只覆盖 \(glass) —— 没铺满宿主，真机上这块会露出桌面")
    }

    // MARK: - 配置

    /// 主窗口该有的配置。每一条去掉都会**静默**劣化（不会让别的断言变红）。
    ///
    /// 这些配置**全部**在 ``AppDelegate/makeMainWindow()`` 里 —— 建窗时确定生效，可直接断言。
    /// 它们原先散在 `ContentView` 的 `WindowAccessor` 里（一个 `NSViewRepresentable`，
    /// 要等视图进窗口、还走一次 `DispatchQueue.main.async`）：实测那个时机**不可靠** ——
    /// 推完布局又跑 run loop，`titlebarAppearsTransparent` / `backgroundColor` / `isOpaque`
    /// **依然没生效**。而它们决定了「窗口看起来是玻璃，还是一块不透明白板」。
    ///
    /// 留在 `WindowAccessor` 里的只剩 `contentView` 的圆角（要设在已进过窗口的视图上），
    /// 那条离屏测不到，靠肉眼与快照走查。
    @Test func 窗口配置符合主窗口() {
        let window = makeWindow()

        #expect(window.styleMask.contains(.titled), "少了它就没有红绿灯")
        #expect(
            window.styleMask.contains(.fullSizeContentView),
            "少了它内容不会铺满整窗，顶上多一条实心标题栏，玻璃也盖不住红绿灯那一带")
        #expect(window.titlebarAppearsTransparent, "标题栏不透明会在顶上压一条底色")
        #expect(
            window.titleVisibility == .hidden,
            "标题栏会画出应用名，与内容里那行「外置磁盘 · N 块」重复")
        #expect(
            window.backgroundColor.alphaComponent == 0,
            "不清掉 windowBackgroundColor 的话，NSVisualEffectView 会被它盖住，桌面透不上来")
        #expect(!window.isOpaque, "不透明窗口看不到毛玻璃")
        #expect(window.isMovableByWindowBackground, "少了它拖窗口只能拖标题栏那一条窄带")
        #expect(window.defaultButtonCell == nil, "有默认按钮的话回车会触发它，而窗口里没有「默认动作」")
        #expect(
            !window.isReleasedWhenClosed,
            "默认 true 会在关窗时释放窗口，复用 `mainWindow` 时是悬垂引用")
        #expect(
            window.minSize == NSSize(width: expected.width, height: expected.height),
            "最小尺寸被改了 —— 窗口可以被拉成非设计稿尺寸")
        #expect(hosting(of: window) != nil, "contentView 必须是 NSHostingView<ContentView>")
        // 标题字符串保留（只是不绘制）：Mission Control、窗口菜单、辅助功能读到的仍是它。
        #expect(window.title == L10n.tr(.appName))

        // **建窗不上屏**：单测跑到这里如果窗口可见，就是抢了用户的焦点。
        #expect(!window.isVisible)
    }
}
