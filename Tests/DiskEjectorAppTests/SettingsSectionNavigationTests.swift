import Foundation
import Testing

@testable import DiskEjectorApp

/// 左栏分类的**方向键导航**（设计稿 09 页 §8.152.5：「↑/↓ 在分类间移动」，macOS 侧栏惯例）。
///
/// ## 为什么这里只测算术，不测按键
///
/// 这条功能的接线是 `.focusable()` + `.onMoveCommand`，而 `swift test` 里
/// **既没有窗口、也没有可信的方向键注入** —— 合成的 `NSEvent` 会被 SwiftUI
/// 的字段校验丢掉，看起来与「按键真的没用」**逐字相同**
/// （同一类坑在鼠标点击上已经吃过一次：见技能 `macos-swiftui-widget-click-verify`）。
/// 所以「按 ↓ 真的会动」这一段**只能真机按一下**，不在这里假装断言过。
///
/// 但「动到哪里」是纯算术，可以逐条钉死、并且能变异测试。
/// ``SettingsSection/moved(from:step:)`` 就是为此从视图里抽出来的 ——
/// 视图只调它、不做判断（本仓库那条「判定收敛成一个可单测的纯函数」的做法）。
///
/// ## 它守的是哪一类失败
///
/// 反过来的那种：**两端的越界**。C 系列下 `index + step` 绕过边界是
/// **下标越界崩溃**（好抓），但用 `%` 回绕「修好」之后就不崩了 ——
/// 而回绕是**错的**：按住 ↑ 到顶会跳回最后一项，用户手已经停了、选中项还在动。
/// 那条只有断言能拦。
struct SettingsSectionNavigationTests {

    // MARK: - 声明顺序即左栏顺序

    /// ↑/↓ 走的是 `allCases` 的**下标**，所以**顺序本身就是契约**。
    ///
    /// 设计稿 09 页左栏逐项为：通用 → 外观 → 更新 → 诊断 → 关于。
    /// 没有这条断言时，有人把 `.about` 挪到第二位**不会让任何测试变红** ——
    /// 只会在走查图上表现为「顺序变了」，而走查图不进 CI。
    @Test func 分类的声明顺序就是左栏显示顺序() {
        #expect(
            SettingsSection.allCases == [.general, .appearance, .updates, .diagnostics, .about])
    }

    // MARK: - 逐项前进 / 后退

    /// 从顶端连按 4 次 ↓，应当**恰好**走遍五项、且顺序与左栏一致。
    @Test func 向下逐项走到关于() {
        var current = SettingsSection.general
        var visited: [SettingsSection] = [current]
        for _ in 0..<(SettingsSection.allCases.count - 1) {
            current = SettingsSection.moved(from: current, step: 1)
            visited.append(current)
        }
        #expect(visited == SettingsSection.allCases)
    }

    @Test func 向上逐项走回通用() {
        var current = SettingsSection.about
        var visited: [SettingsSection] = [current]
        for _ in 0..<(SettingsSection.allCases.count - 1) {
            current = SettingsSection.moved(from: current, step: -1)
            visited.append(current)
        }
        #expect(visited == Array(SettingsSection.allCases.reversed()))
    }

    // MARK: - 两端夹住、不回绕

    /// **回绕读起来像「更周到」，实际更差**：它让「按住 ↑ 到顶」这个动作
    /// 在五项之间跳一圈。Finder 与系统设置在顶/底按方向键就是不动。
    @Test func 在两端夹住而不回绕() {
        #expect(SettingsSection.moved(from: .general, step: -1) == .general)
        #expect(SettingsSection.moved(from: .about, step: 1) == .about)
    }

    /// 一次跨多格的越界也要夹住 —— 键盘连发、以及将来若接上 Home/End
    /// 或 PageUp/PageDown 都会走到这条分支。
    @Test func 一次跨多格越界也夹在两端() {
        #expect(SettingsSection.moved(from: .general, step: -3) == .general)
        #expect(SettingsSection.moved(from: .about, step: 3) == .about)
        #expect(SettingsSection.moved(from: .updates, step: 99) == .about)
        #expect(SettingsSection.moved(from: .updates, step: -99) == .general)
    }

    /// 步长为 0 时原地不动（用作「至少不会乱跳」的基线）。
    @Test func 步长为零时每一项都不动() {
        for section in SettingsSection.allCases {
            #expect(SettingsSection.moved(from: section, step: 0) == section)
        }
    }

    // MARK: - 接线（静态扫源码）

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/SettingsSectionNavigationTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// **方向键的符号不能写反**（↑ = −1、↓ = +1）。
    ///
    /// ⚠️ 这条**必须静态扫源码**：上面那些算术全绿也拦不住它 ——
    /// 把视图里两个分支的步长对调，`moved(from:step:)` 一个字都没变，
    /// 六条算术断言**照样全绿**，而真机上方向键是**反的**。
    /// 这类「接线错、算术对」的缺陷没法从纯函数里看出来，所以直接扫那一行。
    ///
    /// 判据**先把空白归一化**再匹配：`swift-format` 的换行/缩进一变，
    /// 逐字匹配就会红，而那是**格式**问题不是**接线**问题 —— 误报会逼人关掉这条守卫。
    @Test func 上键步长为负一下键步长为正一() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Views/SettingsView.swift"),
            encoding: .utf8)
        let flat = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        // 正向锚：确认扫到的确实是那份文件（路径写错时 `flat` 会是空串，
        // 下面两条断言就变成「两个 false」，看不出是「文件没读到」）。
        #expect(flat.contains("enum SettingsSection"), "没读到 SettingsView.swift —— 装置没跑起来")
        // `.moved` 是唯一入口，确认视图真的在调它（而不是自己写了一遍算术）。
        #expect(flat.contains("SettingsSection.moved(from: selection, step:"))
        #expect(
            flat.contains("case .up: selection = SettingsSection.moved(from: selection, step: -1)"),
            "↑ 的步长不是 −1 —— 方向键会反向")
        #expect(
            flat.contains("case .down: selection = SettingsSection.moved(from: selection, step: 1)"),
            "↓ 的步长不是 +1 —— 方向键会反向")
    }
}
