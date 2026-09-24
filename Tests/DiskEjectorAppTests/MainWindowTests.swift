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
    ///
    /// ⚠️ 经 ``ViewFixtures/mainWindowHandle()`` 走，**不要裸调 `AppDelegate.makeMainWindow()`** ——
    /// 后者的两个 store 都取生产单例，会真的去枚举本机磁盘（见 ``ViewFixtures`` 文件头）。
    private func makeWindow() -> NSWindow {
        // 建窗口、建 hosting 都需要 `NSApplication.shared` 存在。
        _ = NSApplication.shared
        return ViewFixtures.mainWindowHandle()
    }

    private func hosting(of window: NSWindow) -> NSHostingView<ContentView>? {
        window.contentView as? NSHostingView<ContentView>
    }

    /// 玻璃覆盖范围：**我们自己画的那块**玻璃，统一到 `host` 坐标系。
    ///
    /// 判据不是看颜色（离屏取不到桌面），而是**问 AppKit 那块玻璃视图占多大**。
    /// 「自己画的」由 ``GlassBackdrop/isOurs`` 判定（14–25 看材质档，26 起看 `identifier`）——
    /// 系统标题栏自带的玻璃必须排除，否则「我们没铺满」会被它补上。
    private func glassCoverage(in host: NSView) -> CGRect {
        host.glassBackdrops
            .filter { $0.kind.isOurs }
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
        let host = NSHostingView(rootView: ViewFixtures.mainWindow())
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

    // MARK: - 交通灯（2026-09-23：被标题栏裁掉下半部分）

    /// **标题栏区域必须够高到放得下设计稿的灯。**
    ///
    /// 守的是 2026-09-23 用户反馈的那个缺陷：macOS 标准标题栏只有 **28pt** 高，
    /// 且 `NSTitlebarView.masksToBounds == true` ⇒ 超出它的子视图被**裁掉**。
    /// 设计稿要的是「灯中心距顶 26pt」（``DesignTokens/Size/titleBarInsetCenter``），
    /// 而一个 16pt 高的按钮居中在 26pt 时占 y ∈ [18, 34] ⇒ 底部 6pt 落在 28pt 之外
    /// ⇒ 三个灯都画成了「半圆」（真机实测墨迹 **24×16px**，本该 24×24）。
    ///
    /// ⇒ 修法 ``AppDelegate/enlargeTitleBar(in:)``：把标题栏区域加高到内容带高度（52pt）。
    /// 这条断言的是**那件事的后果**，两条都要判：
    /// 1. 区域高度 == 内容带高度；
    /// 2. 区域**完整落在窗口内且顶部贴顶** —— 只加高不改原点的话它会往**下**长，
    ///    灯反而被裁得更多（那正是「修了但更糟」的形状）。
    ///
    /// ⚠️ 这条**离屏测得到**（窗口即使不上屏也有标题栏视图），而「灯真的画全了没有」
    /// 离屏测不到（离屏没有系统画的灯）⇒ 真机那半在 `--preview-main-window-keys`
    /// 的 ``WindowSelfCheck/checkRedLightInkShape``。两条合起来才是完整的守卫。
    @Test func 标题栏区域必须够高到放得下设计稿的灯() {
        let window = makeWindow()
        guard let close = window.standardWindowButton(.closeButton) else {
            Issue.record("取不到关闭按钮 —— 窗口没有标题栏？这条断言的前提不成立（不是通过）")
            return
        }
        guard let titlebar = close.superview else {
            Issue.record("关闭按钮没有父视图 —— 标题栏视图层级变了，`enlargeTitleBar` 也会失效")
            return
        }
        let band = DesignTokens.Size.titleBarBandHeight
        #expect(
            abs(titlebar.bounds.height - band) < 0.5,
            """
            标题栏区域高 \(titlebar.bounds.height)pt，内容带 \(band)pt。
            区域比灯要的高度矮的话，`masksToBounds` 会把灯的下半部分裁掉
            （2026-09-23 用户反馈的「红绿灯显示不全」）。
            检查 `AppDelegate.makeMainWindow()` 里有没有调用 `enlargeTitleBar(in:)`。
            """)
        // ⚠️ 从**窗口坐标**核对位置，而不是只看高度：只加高不改原点会让标题栏
        //    往**下**长（下缘掉到窗口外），灯被裁得更多，而高度那一项照样是 52。
        let inWindow = titlebar.convert(titlebar.bounds, to: nil)
        // ⚠️ `#expect` 的第二个参数是 `Comment`，**不能用 `+` 拼字符串**
        //    （`Comment` 只支持字面量初始化）⇒ 用多行字符串字面量。
        #expect(
            abs(inWindow.maxY - window.frame.height) < 0.5,
            """
            标题栏区域在窗口坐标里是 \(inWindow)，顶部没贴住窗口顶（高 \(window.frame.height)）——
            它是往**下**长的（只改高度、没改原点），灯只会被裁得更多。
            """)
        #expect(
            inWindow.minY >= -0.5,
            "标题栏区域下缘跑到窗口外了（minY=\(inWindow.minY)）—— 容器的高度/原点算错了")
    }

    /// **墨迹不是圆时必须报错** —— 喂合成样本，不需要真机。
    ///
    /// 为什么值得单独立一条：真机那条（``WindowSelfCheck/checkRedLightInkShape``）要窗口、
    /// 要前台、要系统把灯画成红色 —— **门槛里跑不了**。判据被切成「纯函数 + 量测」两半，
    /// 就是为了让**判据这半进得了门槛**：这里喂合成样本，把「什么形状算被裁」钉死。
    ///
    /// ⚠️ **三个方向都要有**（少一个就可能假绿）：
    /// ① 完整圆 ⇒ **不报**（否则「永远报错」也能绿）；
    /// ② 半圆 ⇒ 报，且要报**两条**（不是圆 + 中心上移）—— 这两条是同一根因的两个方向，
    ///    数量写死是为了让「只留一条」这种退化被抓出来；
    /// ③ `nil` ⇒ 不报（量测那半已经写过原因，再报一条会把一件事说成两件）。
    @Test func 红灯墨迹不是圆时必须报错() {
        let anchor = DesignTokens.Size.titleBarBandHeight / 2
        let inset = DesignTokens.Size.titleBarInsetCenter

        // ① 完整圆：12pt 的圆在 2x 下量到 12×12pt，中心正好在内容带中心。
        var ok: [String] = []
        WindowSelfCheck.checkRedLightInkShape(
            ink: .init(centerX: inset, centerYFromTop: anchor, width: 12, height: 12, count: 452),
            label: "T", mismatches: &ok)
        #expect(ok.isEmpty, "完整的圆不该报错，实得：\(ok)")

        // ② 被裁：真机实测的形态 —— 24×16px ⇒ 12×8pt，中心因下缘被裁而上移。
        var bad: [String] = []
        WindowSelfCheck.checkRedLightInkShape(
            ink: .init(centerX: inset, centerYFromTop: anchor - 4, width: 12, height: 8, count: 320),
            label: "T", mismatches: &bad)
        #expect(
            bad.count == 2,
            "被裁掉下半部分应报 2 条（不是圆 + 中心上移），实得 \(bad.count) 条：\(bad)")
        #expect(
            bad.contains { $0.contains("不是圆的") },
            "报错信息必须指出「不是圆」—— 否则读的人会顺着中心偏移去查错方向。实得：\(bad)")

        // ③ 量不到时不重复报：原因已由 `measureRedLightInk` 写过。
        var none: [String] = []
        WindowSelfCheck.checkRedLightInkShape(ink: nil, label: "T", mismatches: &none)
        #expect(none.isEmpty, "ink 为 nil 时不该报错（原因由量测那半写），实得：\(none)")
    }

    /// **AppKit 把标题栏拨回去时，必须自己补回来。**
    ///
    /// 守的是 2026-09-23 真机实测的第二个缺陷：窗口**已经在屏幕上**时切换深/浅色外观，
    /// AppKit 会把标题栏从 52pt 拨回 **28pt** ⇒ 灯又被裁成半圆（墨迹从 12×12 退回 **12×8**），
    /// 而且**切回原外观也不会自己恢复**。
    /// `showMainWindow()` 里那次收敛只发生在「显示窗口」时 —— 窗口一直开着就没人管。
    ///
    /// 修法是 ``AppDelegate/watchTitleBarResets(in:)``：盯住标题栏的
    /// `frameDidChangeNotification`，一响就把 52pt 补回去（为什么是这条信号而不是
    /// 外观 KVO，见那个函数的说明 —— 四条路只有这条响在 AppKit 改完之后）。
    ///
    /// ⚠️ **这里模拟的必须是 AppKit 真正做的事** —— 直接写 `frame`。
    /// 若改成「调一次 `enlargeTitleBar`」，那就是**拿自己的函数验自己**：
    /// 观察者有没有挂上、信号对不对，全都测不出来（本仓库那条「守卫要有辨别力」）。
    ///
    /// ⚠️ 真机上那个**触发源**（系统外观变化）在这里造不出来 —— 那要真机受控实验（见 SPEC §8.139）。
    /// 但这里测的是它的**后果**（frame 被改小）与我们修法的**接缝**，
    /// 而那段代码不依赖屏幕 ⇒ 离屏单测足够，不必再加一条真机自检。
    @Test func 标题栏被拨回时必须自己补回来() {
        let window = makeWindow()
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else {
            Issue.record("取不到标题栏 —— 这条断言的前提不成立（不是通过）")
            return
        }
        let band = DesignTokens.Size.titleBarBandHeight
        #expect(abs(titlebar.frame.height - band) < 0.5, "装配之后本该已经是 \(band)pt")

        // **前提自证**：观察者挂的是 `frameDidChangeNotification`，而它只在视图
        // `postsFrameChangedNotifications == true` 时才会发。这一条不成立的话，
        // 下面那次「改小」根本不会产生信号，测试会以「补回来了」的形式**假绿**。
        #expect(
            titlebar.postsFrameChangedNotifications,
            "标题栏关掉了 frame 变化通知 ⇒ `watchTitleBarResets` 挂的观察者永远不会响")

        // 模拟 AppKit 的重排：把标题栏改回系统默认的 28pt。
        var reset = titlebar.frame
        reset.size.height = 28
        titlebar.frame = reset

        // `queue: .main` + 在主线程 post ⇒ 同一线程上**同步**执行，所以这里可以直接断言，
        // 不需要 `await` / 重试（那样又变成一次时序赌博）。
        #expect(
            abs(titlebar.frame.height - band) < 0.5,
            """
            标题栏被拨回 28pt 之后没有补回来（实得 \(titlebar.frame.height)pt）。
            检查 `AppDelegate.makeMainWindow()` 里有没有调用 `watchTitleBarResets(in:)`、
            以及观察者挂的还是不是 `NSView.frameDidChangeNotification`。
            真机上这会让红绿灯被裁成半圆（墨迹 12×8 而不是 12×12）—— 2026-09-23 用户报的正是这个。
            """)
    }

    /// **resize 之后，观察者盯的还是同一个标题栏视图吗。**
    ///
    /// `watchTitleBarResets` 把观察者挂在**装配那一刻**的标题栏视图上。若 AppKit 在窗口尺寸
    /// 变化时**重建**标题栏（换一个新的 `NSTitlebarView`），观察者就挂在了一个已被移出层级树
    /// 的对象上 —— **它再也不会响**。而 `标题栏被拨回时必须自己补回来` 发现不了这件事：
    /// 那条不 resize，取到的仍然是装配时那一个对象。
    ///
    /// 实测（2026-09-23，离屏）：`setContentSize` 与 `setFrame` 之后都是**同一个对象**，
    /// 宽度跟着窗口走（800 → 700 → 640）、高度一直是 52pt。
    ///
    /// ⇒ 这同时给出了「resize 这条触发源已被覆盖」的证据：resize **一定会改标题栏宽度**
    /// ⇒ `frameDidChangeNotification` **必响** ⇒ 即使 AppKit 顺手把高度拨回去也会被立刻补回。
    /// （主窗口没有 `.resizable`，用户拉不动 ⇒ 真机上这条目前走不到；但
    /// ``AppDelegate/alignTrafficLights(in:)`` 的文档里记着「哪天给它加上 `.resizable`，
    /// 必须在这里补一次 resize 后的重对齐」—— 那个补法现在已经在收敛里了。）
    @Test func resize之后观察者盯的还是同一个标题栏() {
        let window = makeWindow()
        guard let before = window.standardWindowButton(.closeButton)?.superview else {
            Issue.record("取不到标题栏 —— 这条断言的前提不成立（不是通过）")
            return
        }

        window.setContentSize(NSSize(width: 700, height: 480))

        let after = window.standardWindowButton(.closeButton)?.superview
        #expect(
            before === after,
            """
            resize 之后标题栏换了对象 ⇒ `watchTitleBarResets` 的观察者挂在旧对象上，不会再响
            —— 外观一换灯就被裁成半圆，而且没人补回来。
            """)
        #expect(
            abs((after?.frame.height ?? 0) - DesignTokens.Size.titleBarBandHeight) < 0.5,
            "resize 之后标题栏高度是 \(after?.frame.height ?? -1)pt，没保持在内容带高度")
    }
}
