import AppKit
import SwiftUI

/// 系统原生毛玻璃材质（NSVisualEffectView）。
///
/// **为什么用 NSVisualEffectView 而非 SwiftUI `.ultraThinMaterial`**：
/// - SwiftUI 的 Material 是窗口内的"应用级毛玻璃"；`.ultraThinMaterial` 在 macOS 14 上偏厚，
///   整窗覆盖会让窗口失去悬浮感。
/// - `NSVisualEffectView(.underWindowBackground, .behindWindow)` 让桌面直接透过窗口呈现，
///   这是最接近设计稿 `backdrop-filter: blur(30px) saturate(180%)` 的一档系统材质。
///
/// ⚠️ **本文件曾写「`.underWindowBackground` = NSPopover 系统默认背景」，这是错的**：
/// 2026-09-15 用探针打印 `NSPopover` 的窗口视图树，popover 的 `NSPopoverFrame`
/// 是一档 **`.titlebar`**（material rawValue 0）的 `NSVisualEffectView`。
/// 也就是说菜单面板与主窗口**本来就不是同一档材质** —— 这正是「两块玻璃色温不一样」的根因之一。
/// 修法见 ``NSPopover/normalizeBackdropMaterial()``。
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

// MARK: - 让系统 popover 的底衬与主窗口同档

extension NSPopover {

    /// 把系统 popover 的底衬材质改成与主窗口同一档（`.underWindowBackground`）。
    ///
    /// **为什么需要**：`NSPopover` 的窗口视图树顶层是私有的 `NSPopoverFrame`，
    /// 它本身就是一个 `NSVisualEffectView`，材质是 **`.titlebar`** —— 与主窗口的
    /// `.underWindowBackground` 不是同一档。两者各自叠上 `--bg-glass` 之后仍是两种色温。
    ///
    /// **为什么可以这么改**：`material` / `blendingMode` / `state` 都是 `NSVisualEffectView`
    /// 的**公开属性**，`NSPopoverFrame` 只是它的子类，改的是公开 API。
    /// 探针实测（2026-09-15）：改后 material 稳定停在 `.underWindowBackground`（rawValue 21），
    /// popover 的圆角、箭头、窗口阴影全部保持 —— 它们由 frame 的遮罩与窗口阴影负责，
    /// 与 material 无关。
    ///
    /// **不摘 `NSGlassView`**：那是系统新增的玻璃渲染层，也是圆角/描边的绘制者之一，
    /// 摘掉属于动系统私有视图，风险大于收益。材质对齐 + 同色叠加已经足够让两块玻璃一致。
    ///
    /// - Returns: 被改到的那个 `NSVisualEffectView`；视图树还没建好时为 `nil`。
    @discardableResult
    func normalizeBackdropMaterial() -> NSVisualEffectView? {
        guard let frame = backdropFrameView else { return nil }
        frame.material = .underWindowBackground
        frame.blendingMode = .behindWindow
        frame.state = .followsWindowActiveState
        return frame
    }

    /// **只读**当前底衬材质（不做任何修改）。
    ///
    /// **为什么要有这个只读版本**：真机自检（`--preview-popover-keys`）要验的是
    /// 「上屏路径有没有把材质归一化」。如果自检里用 `normalizeBackdropMaterial()` 去取材质，
    /// 它自己就把材质改好了 —— **断言永远为真，等于没测**。
    /// 这个坑值得记下来：自检里读一个「会被自检本身修正」的状态，就是在自证。
    var backdropMaterial: NSVisualEffectView.Material? { backdropFrameView?.material }

    /// popover 窗口视图树的**最外层** `NSVisualEffectView`，也就是私有的 `NSPopoverFrame`。
    ///
    /// 从 `window.contentView` 一路向上到根，再向下深度优先找第一个 ——
    /// 因为 `NSPopoverFrame` 既是根视图本身、又是效果视图，只能这么找。
    private var backdropFrameView: NSVisualEffectView? {
        guard let window = contentViewController?.view.window else { return nil }
        var top = window.contentView
        while let parent = top?.superview { top = parent }
        return top?.firstVisualEffectView
    }
}

extension NSView {
    /// 深度优先找到第一个 `NSVisualEffectView`（**先看自己**，因为 `NSPopoverFrame`
    /// 本身就是效果视图，而它是整棵树里最外层的那个）。
    fileprivate var firstVisualEffectView: NSVisualEffectView? {
        if let effect = self as? NSVisualEffectView { return effect }
        for sub in subviews {
            if let found = sub.firstVisualEffectView { return found }
        }
        return nil
    }
}

// MARK: - 窗口玻璃的自检入口

extension NSView {

    /// 本视图**及其子树**里所有 `NSVisualEffectView` 的 frame（**统一转成 `self` 的坐标系**）
    /// 与材质。
    ///
    /// 判定「那块玻璃」的办法是看 `material`：``GlassSurface`` 用的是
    /// `.underWindowBackground`，系统标题栏自带的那些是别的档。
    ///
    /// **为什么下沉到 `NSView`**：`NSWindow` 版本只能问「窗口里占多大」（真机自检用），
    /// 而 `MainWindowTests` 要问的是**「玻璃有没有铺满宿主」** —— 那只需要一个宿主视图，
    /// 不需要窗口（实测离屏也能建出 `NSVisualEffectView`，`layoutSubtreeIfNeeded()` 就够）。
    var glassEffectFrames: [(frame: CGRect, material: NSVisualEffectView.Material)] {
        var result: [(CGRect, NSVisualEffectView.Material)] = []
        func walk(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                // ⚠️ 必须转成统一坐标系：各层 frame 是各自父视图坐标系里的值，
                // 直接拿来求并集会得到毫无意义的矩形。
                result.append((effect.convert(effect.bounds, to: self), effect.material))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return result
    }
}

extension NSWindow {

    /// 窗口内容视图树里所有 `NSVisualEffectView` 的**窗口坐标** frame。
    ///
    /// **用途**：回答「窗口玻璃有没有覆盖整窗」这个**只有真机才能问**的问题。
    /// 离屏渲染里没有窗口，也就没有「标题栏安全区」这回事 ——
    /// 玻璃少画了标题栏那一带，离屏出图**完全看不出来**（实测踩过：
    /// `GlassSurface` 从 `ZStack` 挪到 `.background(...)` 时丢了 `.ignoresSafeArea()`，
    /// 真机上标题栏整条露出桌面，而离屏快照仍是满窗玻璃）。
    ///
    /// **必须转成窗口坐标再比**：内容视图树里各层的坐标系互不相同，
    /// 而 `NSHostingView` 还是 flipped 的（原点在左上），拿它的 `bounds` 去比 y 轴会反过来。
    var glassEffectFrames: [(frame: CGRect, material: NSVisualEffectView.Material)] {
        guard let root = contentView else { return [] }
        // 复用 `NSView` 那一份的遍历（坐标先归到 `root`，再转窗口坐标）——
        // 两个版本各写一份 `walk` 迟早会漂移。
        return root.glassEffectFrames.map {
            (root.convert($0.frame, to: nil), $0.material)
        }
    }
}

// MARK: - 窗口/面板的统一玻璃底

/// 一块「窗口级毛玻璃」：**材质 + `--bg-glass` 叠加色 + 0.5px 外描边**。
///
/// **为什么必须是一个共用组件**：设计稿里主窗口、菜单面板、设置面板的外壳是同一条规则 ——
/// ```css
/// .win { border-radius: var(--r-window); border: 0.5px solid var(--border-strong);
///        background: var(--bg-glass); backdrop-filter: blur(30px) saturate(180%); }
/// ```
/// 但实现侧三处各写各的：主窗口只有 `NSVisualEffectView`（缺 `--bg-glass` 叠加，
/// 于是显示为系统材质那层偏冷的灰）、菜单面板什么都没有（靠 `NSPopover` 自带材质，
/// 又是另一档 `.titlebar`）、设置面板用了 `--bg-glass-thick`（白一档）。
/// 三块玻璃三种色温 —— 用户一眼就看出来了。
///
/// **材质之上为什么还要叠一层色**：`--bg-glass` 在设计稿里是铺在模糊之上的**半透明色**，
/// 它才是决定「暖白 / 暖深灰」的那一层。只放系统材质等于只做了模糊、没上色。
///
/// ⚠️ **挂法：一律用 `.background(GlassSurface(...))`，不要放进 `ZStack`。**
/// 里面是 `NSViewRepresentable`，放进 `ZStack` 后会被父级用「建议高度 = 无限大」量一次
/// （`sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))`），
/// SwiftUI 会拿这个 1.79e308 去建 AppKit 约束，AppKit 抛
/// `NSLayoutConstraint ... exceeds internal limits` 并**把进程打死**（实测 signal 5）。
/// `.background` 传下去的是内容已经算好的有限尺寸，不会触发。
struct GlassSurface: View {

    /// 圆角。主窗口 12（`--r-window`）、菜单面板 14（`--r-lg`）、设置面板 12。
    var cornerRadius: CGFloat

    /// 是否画 0.5px 外描边（设计稿 `.win` 的 `border: 0.5px solid var(--border-strong)`）。
    ///
    /// 默认画。只有「本身已在外框里、再画会重复」的场合才关掉。
    var showsBorder: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    /// **「视觉效果」偏好必须在这一层读** —— 设置面板只负责写它。
    ///
    /// 2026-09-17 用户报「切换透明和色调没有任何变化」，根因就是这个令牌
    /// **全仓库只有写入点、没有任何读取点**：`SettingsSectionsColumn` 用
    /// `@AppStorage` 把它存进 UserDefaults，而 ``GlassSurface`` 一律画毛玻璃。
    /// 一个只写不读的偏好，在 UI 上和「没做这个功能」没有区别。
    ///
    /// 放在这里而不是让三个调用点各自传参，是因为「窗口底色是什么」必须只有一个答案 ——
    /// 主窗口、菜单面板、设置面板是同一个设计规则（`.win`），
    /// 任何一处漏传都会退回毛玻璃，又会变成「三块玻璃三种色温」。
    @AppStorage(AppSettings.Key.visualStyle) private var visualStyleRaw = VisualStyle.default.rawValue

    private var style: VisualStyle { VisualStyle(rawValue: visualStyleRaw) ?? .default }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // **两种风格都保留这一层系统材质**，只换上面那层色：
            // - 透明：半透明 `--bg-glass` 铺在模糊之上 → 桌面透出来，是毛玻璃；
            // - 色调：不透明的 `--bg-base` 把它完全盖住 → 固定的实体面。
            //
            // 不按风格摘掉它，是因为「玻璃铺满整窗」这条不变量由 `MainWindowTests`
            // 与 `--preview-main-window-keys` 靠**找 `NSVisualEffectView`** 来断言。
            // 摘掉的话，那两条断言就会随用户的偏好值变绿变红 —— 自检不该依赖运行态偏好。
            VisualEffectBackground()
            style == .tinted
                ? DesignTokens.Palette.windowBase(for: colorScheme)
                : DesignTokens.Palette.windowGlass(for: colorScheme)
        }
        .clipShape(shape)
        .overlay {
            if showsBorder {
                shape.strokeBorder(
                    DesignTokens.Palette.borderStrong,
                    lineWidth: DesignTokens.Size.glassBorderWidth)
            }
        }
        // 纯背景：不能吃掉任何点击，否则窗口里所有控件都点不动。
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
