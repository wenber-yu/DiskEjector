import AppKit

/// 设置面板的窗口类：**照设计稿，不画系统交通灯**。
///
/// ## 为什么设置面板没有红绿灯（2026-09-16，用户指出）
///
/// 用户原话：
/// > 「设置窗口标题栏右侧的完成按钮和左侧红灯关闭功能上有点重复了吧，我看设计稿里
/// > 左侧是设置标题，右侧是完成按钮，这个你为什么不按照设计稿实现呢？」
///
/// 他是对的，而且是两件事叠在一起：
///
/// 1. **设计稿里设置面板本来就不画红绿灯**。`05-settings.html` 的 `.shead` 是
///    `height: 52px; display: flex; align-items: center; padding: 0 16px`，
///    里面**只有**「设置」+「完成」，一个 `traffic` 元素都没有
///    （对比 `01-main-window.html` 的 `.titlebar`，那里明写了 `<div class="traffic">`；
///    全仓库 `grep -c traffic screens/*.html` = 01:2、06:2、07:1、**05:0**）。
/// 2. 实现当初为了保住系统标题栏，给红绿灯**让出 52pt**（见 `DESIGN-SPEC.md` §8.11.4），
///    却顺手让「完成」与红色关窗按钮**变成同一个动作**（都关窗）——
///    一个功能两个出口，用户一眼就看出来了。
///
/// 所以这里把三个系统按钮**藏掉**，界面上只剩设计稿画的那两个东西：「设置」+「完成」。
///
/// ## 为什么是「藏按钮」而不是改用 `.borderless`
///
/// `.borderless` 能天然没有红绿灯，但会**一并丢掉**系统给的那一整套：标题栏拖动、
/// 12pt 圆角与窗口阴影、⌘W 关窗、Mission Control / 「窗口」菜单里的条目。
/// 而**藏按钮一条都不丢** —— 窗口仍是普通的 `.titled` 窗口，只是不画那三个圆点。
///
/// ## 三条实测结论（`.build/probe/closebtn*.swift`，macOS 15，2026-09-16）
///
/// | 问题 | 实测 |
/// |---|---|
/// | 关窗按钮隐藏后 `performClose(_:)` 还关得掉吗？ | **关得掉** —— 但**前提是 `.closable` 留在 `styleMask` 里**。Apple 文档那句 *"If the window's close button is disabled or hidden, this method does nothing"* 在本组合（`.titled` + `.closable`）下不成立：实测 `windowShouldClose(_:)` 被正常咨询一次、窗口正常关掉（窗口可见 / 从未上屏 / 上屏后 `orderOut`，四种情形一致）。**所以不要为此加 override**。⚠️ 反过来，把 `.closable` 去掉就**真的关不掉**了（实测 `windowShouldClose(_:)` 一次都没被咨询，`watcher.asked → 0`）—— 那一条由 `SettingsWindowTests` 里的两条断言一起盯着。 |
/// | ⌘M 会怎样？ | `performMiniaturize(_:)` **什么都不做**（最小化按钮本来就是 `enabled = false`）。面板不会被最小化到找不回来。 |
/// | `isHidden` 会被 AppKit 自己改回来吗？ | **不会**。反复上屏 / 成为 key / 关窗再上屏，三个按钮始终 `hidden = true`。 |
///
/// 三条都有断言盯着（`SettingsWindowTests`）+ 真机自检（`--preview-settings-keys`）：
/// 哪条被 macOS 改掉，测试或自检立刻变红，而不是等用户再报一次。
///
/// ## 与 ``KeySilentWindow`` 的关系
///
/// 继承它，于是「没人接管的按键不敲钟」（`DESIGN-SPEC.md` §8.15）在设置窗口上继续成立。
final class SettingsWindow: KeySilentWindow {

    /// 要隐藏的三个系统按钮。
    ///
    /// 抽成常量是为了让**视图、单测、真机自检共用同一份清单** ——
    /// 三处各写一遍 `[.closeButton, .miniaturizeButton, .zoomButton]`，迟早会漂移。
    static let hiddenButtonTypes: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton,
    ]

    /// 在 `init` 里就藏好。
    ///
    /// **为什么放在 `init` 而不是让调用方再调一次**：这样**不存在「忘了藏」的建窗路径**。
    /// 「配置放在不确定会执行的地方」是本项目反复踩过的坑（见 `DESIGN-SPEC.md` §8.11.2）——
    /// 这里直接把它焊死在唯一入口上。
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        for type in Self.hiddenButtonTypes {
            standardWindowButton(type)?.isHidden = true
        }
    }

    /// 三个系统按钮是不是**都还藏着**。
    ///
    /// 真机自检与单测共用这一份判据。取不到按钮（`standardWindowButton(_:)` 返回 `nil`）
    /// 判为 **false** —— 那是「问不出结论」，不该算通过。
    static func standardButtonsAreHidden(in window: NSWindow) -> Bool {
        hiddenButtonTypes.allSatisfy { window.standardWindowButton($0)?.isHidden == true }
    }
}
