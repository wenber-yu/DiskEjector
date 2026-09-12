import AppKit
import Testing

@testable import DiskEjectorApp

/// 主菜单接线的测试。
///
/// **为什么这类退化必须由测试兜住**：本 App 用自建 `NSApplication` + `app.run()` 启动，
/// 没有 nib，主菜单是手写的。macOS 的 ⌘W / ⌘H / ⌘Q / ⌘M **不是系统全局分发**的快捷键，
/// 它们的实现路径是「按键 → 在主菜单里按 `keyEquivalent` 查找 → 执行该项 action」。
/// 菜单里少一项或 action 指错，对应快捷键就静默失效 —— 不报错、不崩溃、编译也过，
/// 只有用户按下去没反应才发现（2026-09-12 实测 `NSApp.mainMenu == nil` 时 ⌘W 完全无响应，
/// 就是这个形态）。所以把接线本身钉成断言，而不是靠人肉记得按一遍。
@Suite("主菜单接线")
@MainActor
struct MainMenuTests {

    /// 把一个菜单树摊平成所有菜单项（含各级 submenu 里的项）。
    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + flatten(submenu)
        }
    }

    /// 装配主菜单，并把一个 AppDelegate 实例挂成 `NSApplication.shared.delegate`。
    ///
    /// 必须挂：菜单里「显示主窗口」与「隐藏 DiskEjector」两项的 target 取自 `NSApp.delegate`
    /// （它们在没有窗口时响应链是空的，走 nil-target 会被置灰）。测试进程里没有应用委托，
    /// 不挂的话这两项的 target 会是 nil，断言就变成空对空。
    /// 返回持有的 delegate —— `NSApplication.delegate` 是 weak，不持有会被立刻释放。
    ///
    /// 开头那句 `_ = NSApplication.shared` 不可省：`NSApp` 这个全局是**由 AppKit 在
    /// 建立共享应用实例时赋值**的，测试进程里从不碰它就一直是 nil，
    /// 于是 `NSApp.delegate = ...`（`NSApp` 是隐式解包可选）会直接崩在解包上。
    private func installWithDelegate() -> AppDelegate {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        MainMenu.install()
        return delegate
    }

    @Test func 装配后主菜单有四个顶层菜单() {
        _ = installWithDelegate()
        #expect(NSApplication.shared.mainMenu != nil)
        #expect(NSApplication.shared.mainMenu?.items.count == 4)
    }

    /// 逐个钉住用户报告过「按了没反应」的快捷键，以及其余标准项。
    @Test func 标准快捷键全部接线() throws {
        _ = installWithDelegate()
        let main = try #require(NSApplication.shared.mainMenu)
        let items = flatten(main)

        /// 取「正好是 ⌘<字符>」的那一项 —— 必须精确匹配修饰键，
        /// 否则会把 ⌘⌥H（隐藏其他）也当成 ⌘H。
        func item(_ key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
        }

        // ⌘W：指向 performClose:，交给响应链解析到当前键窗口（主窗口 / 设置窗口共用一条目）
        let close = item("w")
        #expect(close?.action == #selector(NSWindow.performClose(_:)))

        // ⌘H：**必须**是本 App 自己的分流实现，不能用 NSApplication.hide(_:)
        //（代理类 App 系统不允许隐藏，⌘H 会变成死键）
        let hide = item("h")
        #expect(hide?.action == #selector(AppDelegate.hideApp(_:)))

        // ⌘⌥H 隐藏其他仍走系统实现
        let hideOthers = item("h", modifiers: [.command, .option])
        #expect(hideOthers?.action == #selector(NSApplication.hideOtherApplications(_:)))

        // ⌘Q 退出
        #expect(item("q")?.action == #selector(NSApplication.terminate(_:)))

        // ⌘M 最小化
        #expect(item("m")?.action == #selector(NSWindow.performMiniaturize(_:)))

        // ⌘1 显示主窗口 —— 菜单栏模式下 ⌘W 关掉窗口后靠它找回
        #expect(item("1")?.action == #selector(AppDelegate.showMainWindow))
    }

    /// 两个 App 自有动作必须显式指向 delegate，否则菜单项会被置灰（拿不到接收者）。
    @Test func 自有动作指向应用委托() throws {
        let delegate = installWithDelegate()
        let main = try #require(NSApplication.shared.mainMenu)
        let items = flatten(main)

        let showMain = try #require(items.first { $0.action == #selector(AppDelegate.showMainWindow) })
        #expect(showMain.target === delegate)

        let hide = try #require(items.first { $0.action == #selector(AppDelegate.hideApp(_:)) })
        #expect(hide.target === delegate)
    }

    /// 「窗口」菜单要交给 AppKit 托管（`NSApp.windowsMenu`），
    /// 这样打开的窗口会自动出现在菜单底部 —— 少这一句菜单里就不会列出窗口。
    @Test func 窗口菜单交由系统托管() {
        _ = installWithDelegate()
        #expect(NSApplication.shared.windowsMenu != nil)
        #expect(NSApplication.shared.windowsMenu?.title == L10n.tr(.menuWindow))
    }
}
