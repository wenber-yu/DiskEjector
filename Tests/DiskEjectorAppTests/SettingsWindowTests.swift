import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 设置窗口**窗口层面**的契约。
///
/// 与 `MainWindowTests` 同一个理由、同一套判据：那边量主窗口，这边量设置窗口。
/// 两者在真机上是**同一条 `.win` 规则**（`--bg-glass` + `blur(30) saturate(180%)`
/// + 圆角 12 + 0.5px 描边），所以窗口层面也必须一致。
///
/// ## 这个文件补的是一整排「没有任何断言」的配置（2026-09-16）
///
/// 之前 `showSettings()` 只有五行装配（`contentRect` / `styleMask` / `contentView` /
/// `center` / `isReleasedWhenClosed`），主窗口那一套一个都没做。后果逐条实测：
///
/// | 缺的东西 | 后果 |
/// |---|---|
/// | `safeAreaRegions = []` | **上屏前 480×800 → 上屏后 480×832**（多 32pt） |
/// | `backgroundColor = .clear` + `isOpaque = false` | 窗口不透明 → 毛玻璃**糊不到桌面**，看着是平色块 |
/// | `titleVisibility = .hidden` | 系统标题栏的「设置」与面板头部的「设置」**重复** |
/// | `contentView.layer.cornerRadius` | 玻璃卡片 12pt 圆角、窗口底角却是直角，两者不重合 |
///
/// 这四条**一条都不会让别的断言变红** —— 正是「配置放在不确定会执行的地方，
/// 且丢了没有任何断言会红」这个共性问题的一个实例。所以这里逐条钉住。
///
/// ## 2026-09-16 追加：三个系统按钮必须**藏着**（`DESIGN-SPEC.md` §8.17）
///
/// 用户报告：「设置窗口标题栏右侧的完成按钮和左侧红灯关闭功能上有点重复了吧，
/// 我看设计稿里左侧是设置标题，右侧是完成按钮」。设计稿的 `.shead` 里确实没有 `traffic`
/// —— 而实现当初给红绿灯让了位，于是「完成」与红灯成了**同一个动作的两个出口**。
/// 现在由 ``SettingsWindow`` 在 `init` 里把三个按钮藏掉，这里钉住两件事：
///
/// | 断言 | 抓什么 |
/// |---|---|
/// | ``三个系统按钮必须藏起来`` | 窗口类被换回 `KeySilentWindow` / `NSWindow`，或按钮又被放出来 |
/// | ``隐藏交通灯之后关闭流程仍然完整`` | 「藏了按钮顺手把 ⌘W 也弄坏了」—— 主菜单「关闭窗口 ⌘W」的 action 就是 `NSWindow.performClose(_:)` |
///
/// ## 为什么离屏快照测不到
///
/// `SnapshotRenderTests` 渲染的视图**没有窗口**，于是既没有标题栏安全区、
/// 窗口也不会被固有尺寸回推撑高（实测离屏恒为设计稿高）—— 快照永远是「尺寸正确、玻璃满窗」，
/// 对上面这几条**结构性失明**。但离屏**仍然建得出 `NSVisualEffectView`**，
/// 所以「玻璃有没有铺满宿主」可以脱离窗口断言：给它一个**比设计稿高 32pt 的宿主**，
/// 看玻璃跟不跟得上。
///
/// **三个系统按钮更是离屏完全问不到**：`standardWindowButton(_:)` 属于「窗口」，
/// 离屏没有窗口，调用它会返回 `nil`。
///
/// 真机上的最终裁决是 `--preview-settings-keys`（量真实窗口尺寸、玻璃覆盖，
/// 以及三个系统按钮是否都已隐藏）。
@MainActor
struct SettingsWindowTests {

    private let expected = DesignTokens.Size.settingsPanel

    /// 建设置窗口，**不上屏**（单测不抢用户焦点，与 `MainWindowTests` / `OnboardingWindowTests` 一致）。
    ///
    /// 走 `AppDelegate.makeSettingsWindow()` —— **真机与单测同一条装配路径**。
    /// 单测自己再搭一个「差不多的窗口」等于什么都没验。
    private func makeWindow() -> NSWindow {
        // 建窗口、建 hosting 都需要 `NSApplication.shared` 存在。
        _ = NSApplication.shared
        return AppDelegate.makeSettingsWindow()
    }

    private func hosting(of window: NSWindow) -> NSHostingView<SettingsView>? {
        window.contentView as? NSHostingView<SettingsView>
    }

    /// 玻璃覆盖范围：**我们自己画的那块**玻璃，统一到 `host` 坐标系。
    ///
    /// 判据不是看颜色（离屏取不到桌面），而是**问 AppKit 那块玻璃视图占多大**。
    /// 「自己画的」由 ``GlassBackdrop/isOurs`` 判定 —— 系统标题栏自带的必须排除。
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

    /// 宿主不得要求比设计稿更高的尺寸。
    ///
    /// 固有尺寸 = 内容 + 安全区（800 + 32 = 832），`NSHostingView` 的默认 `sizingOptions`
    /// 会把它回推给窗口 —— 窗口在**上屏那一刻**被撑到 598，而离屏量不出来。
    @Test func 宿主不得把标题栏安全区算进尺寸() {
        let window = makeWindow()
        guard let hosting = hosting(of: window) else {
            Issue.record("设置窗口的 contentView 不是 NSHostingView<SettingsView>")
            return
        }
        let intrinsic = hosting.intrinsicContentSize.height
        #expect(
            intrinsic <= expected.height + 0.5,
            "宿主固有高度 \(intrinsic)，设计稿 \(expected.height) —— 多的 32pt 就是标题栏安全区")
    }

    /// 安全区不关，SwiftUI 会把内容**整体下推 32pt**（头部「设置」跟着下移），
    /// 而窗口尺寸可能还是对的。这是**配置断言**，抓的是机制。
    @Test func 宿主必须关掉安全区() {
        let window = makeWindow()
        guard let hosting = hosting(of: window) else {
            Issue.record("设置窗口的 contentView 不是 NSHostingView<SettingsView>")
            return
        }
        if #available(macOS 13.3, *) {
            #expect(
                hosting.safeAreaRegions == [],
                "宿主没关掉安全区 —— 窗口会让 SwiftUI 把内容整体下推 32pt，头部与红绿灯就错位了")
        }
    }

    /// 玻璃必须铺满宿主，而不是「刚好等于内容的 480×800」。
    ///
    /// 用一个**比设计稿高 32pt 的宿主**来问 —— 这正是真机上窗口被撑到 598 时的样子。
    @Test func 玻璃必须铺满比设计稿高的宿主() {
        // `fillsHost: true` —— 与 `makeSettingsWindow` 同一条装配。
        let host = NSHostingView(rootView: SettingsView(onDone: {}, fillsHost: true))
        // 与 `makeSettingsWindow` 的配置保持一致：这里问的是**视图结构**，不是宿主配置。
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

    /// 设置窗口该有的配置。每一条去掉都会**静默**劣化（不会让别的断言变红）。
    ///
    /// 这些配置**全部**在 ``AppDelegate/makeSettingsWindow()`` 里 —— 建窗时确定生效，
    /// 可直接断言。（原先它们是内联在 `showSettings()` 里的五行，且缺了下面这一整排。）
    @Test func 窗口配置符合设置窗口() {
        let window = makeWindow()

        #expect(
            window.styleMask.contains(.titled),
            "少了它就没有标题栏 —— 拖动、⌘W、圆角阴影、Mission Control 与「窗口」菜单里的条目会一起丢（红绿灯另由 SettingsWindow 藏掉）")
        #expect(
            window.styleMask.contains(.closable),
            "少了它 `performClose(_:)` 就真的关不掉窗口了 —— ⌘W 会静默失效")
        #expect(
            window.styleMask.contains(.fullSizeContentView),
            "少了它内容不会铺满整窗，顶上多一条实心标题栏，玻璃也盖不住标题栏那一带")
        #expect(window.titlebarAppearsTransparent, "标题栏不透明会在顶上压一条底色")
        #expect(
            window.titleVisibility == .hidden,
            "标题栏会画出「设置」，与面板头部那个「设置」重复 —— 同一个词出现两遍")
        #expect(
            window.backgroundColor.alphaComponent == 0,
            "不清掉 windowBackgroundColor 的话，NSVisualEffectView 会被它盖住，桌面透不上来 —— 面板看起来只是一块平的浅色，不是玻璃")
        #expect(!window.isOpaque, "不透明窗口看不到毛玻璃")
        #expect(window.isMovableByWindowBackground, "少了它拖窗口只能拖标题栏那一条窄带")
        #expect(window.defaultButtonCell == nil, "有默认按钮的话回车会触发它，而窗口里没有「默认动作」")
        #expect(
            !window.isReleasedWhenClosed,
            "默认 true 会在关窗时释放窗口，复用 `settingsWindow` 时是悬垂引用")
        #expect(hosting(of: window) != nil, "contentView 必须是 NSHostingView<SettingsView>")
        // 标题字符串保留（只是不绘制）：Mission Control、窗口菜单、辅助功能读到的仍是它。
        #expect(window.title == L10n.tr(.settings))

        // 玻璃卡片的 12pt 外圆角：窗口是非不透明的，只有给 contentView 的 layer
        // 设圆角 + 遮罩，窗口四角才会真的跟着圆（否则玻璃圆角与窗口直角不重合）。
        #expect(
            window.contentView?.layer?.cornerRadius == DesignTokens.Radius.window,
            "contentView 没有设 12pt 圆角 —— 玻璃卡片是圆的、窗口底角是直角")
        #expect(window.contentView?.layer?.masksToBounds == true, "圆角没被遮罩裁掉，四角仍会露出方形玻璃")

        // **建窗不上屏**：单测跑到这里如果窗口可见，就是抢了用户的焦点。
        #expect(!window.isVisible)
    }

    // MARK: - 系统交通灯（2026-09-16：按设计稿藏掉）

    /// 三个系统按钮必须都藏着 —— 设计稿的 `.shead` 里没有 `traffic`。
    ///
    /// **为什么这条不能只靠视图层的测试**：按钮是**系统画的**，
    /// 开关在窗口类（``SettingsWindow/init``）里，视图层完全看不见。
    /// 把它改回可见，任何快照与布局测试都不会红 —— 用户会再报一次「红绿灯和完成重复」。
    ///
    /// 实测（macOS 15）：`isHidden` 设上之后**不会**被 AppKit 自己改回来 ——
    /// 反复上屏 / 成为 key / 关窗再上屏都还是隐藏的（`.build/probe/closebtn.swift`）。
    @Test func 三个系统按钮必须藏起来() {
        let window = makeWindow()
        #expect(
            window is SettingsWindow,
            "设置窗口的类不是 SettingsWindow（实得 \(type(of: window))）—— 按钮不会被藏，红绿灯会重新出现"
        )
        for type in SettingsWindow.hiddenButtonTypes {
            #expect(
                window.standardWindowButton(type)?.isHidden == true,
                "\(type) 还在画 —— 设计稿的 `.shead` 里没有 traffic，它的关窗与头部的「完成」是同一个动作的两个出口"
            )
        }
    }

    /// 藏掉交通灯之后，**关闭流程必须仍然完整**。
    ///
    /// 主菜单里「关闭窗口 ⌘W」的 action 是 `NSWindow.performClose(_:)`（见 ``MainMenu``），
    /// 所以「藏按钮」最大的风险就是**顺手把 ⌘W 也弄哑了**。
    /// 实测（macOS 15，`.build/probe/closebtn3.swift`）：隐藏关窗按钮之后
    /// `performClose(_:)` **照样走完整流程** —— `windowShouldClose(_:)` 被咨询一次，
    /// 且与「窗口可见 / 从未上屏 / 上屏后 `orderOut`」都无关。
    ///
    /// ⚠️ **不能用 `isVisible` 判**：窗口从未上屏时它本来就是 `false`，
    /// 「关掉了」和「什么都没做」长得一模一样（实测踩过）。
    /// 必须问一件**只有走完流程才会发生**的事 —— 这里用 delegate 回调。
    @Test func 隐藏交通灯之后关闭流程仍然完整() {
        let window = makeWindow()

        final class CloseWatcher: NSObject, NSWindowDelegate {
            var asked = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool {
                asked += 1
                return true
            }
        }
        // `NSWindow.delegate` 是 weak —— 这里必须持有它，否则回调还没来就被回收了。
        let watcher = CloseWatcher()
        window.delegate = watcher

        window.performClose(nil)

        #expect(
            watcher.asked == 1,
            """
            `performClose:` 没有走完关闭流程（`windowShouldClose(_:)` 被咨询 \(watcher.asked) 次，期望 1）。\
            主菜单的「关闭窗口 ⌘W」就是它 —— 那说明藏掉关窗按钮之后 ⌘W 哑了。\
            实测 macOS 15 不会这样；真被 Apple 改回去，就在 SettingsWindow 里把 performClose 接回 close()。
            """
        )
    }

    // MARK: - 入口

    /// 三条设置入口（主窗口齿轮 / 菜单栏面板 / ⌘,）都落在 `AppDelegate.showSettings`。
    ///
    /// **这里原先有一条测试，已删除（2026-09-16）—— 它是个假守卫**：
    ///
    /// ```swift
    /// #expect(AppDelegate.instancesRespond(to: #selector(AppDelegate.showSettings)))
    /// ```
    ///
    /// `#selector(...)` 这个表达式**本身就要编译通过**：方法不存在、或不是 `@objc`，
    /// 代码根本编不过。所以 `instancesRespond` 恒为真，它拦不住任何回归，
    /// 却会让人以为「入口已经有测试盯着了」。
    ///
    /// 真正守住这条线的是两处：
    /// - **编译期**：齿轮的 `sendAction` 与主菜单项都用 `#selector(AppDelegate.showSettings)`，
    ///   改名/删掉会直接编译失败；
    /// - **运行期**：`ContentView.openSettings()` 里的 `assert(delivered, ...)`，
    ///   把「`sendAction` 找不到接收者时只是安静返回 false」这个静默失败变成崩溃。
    ///
    /// 主菜单那一条另有 `MainMenuTests` 盯着（`item(",")?.action == #selector(...)`）——
    /// 那条是**真**断言：它拦的是「有人把菜单项改成别的 action」，那种改动编译得过。
}
