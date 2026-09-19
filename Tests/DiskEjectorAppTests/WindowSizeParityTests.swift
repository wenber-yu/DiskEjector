import Foundation
import Testing

@testable import DiskEjectorApp

/// 设计稿 `ds.css` 的**窗口级尺寸** ↔ 实现 `DesignTokens.Size` 的**同源契约**。
///
/// ## 为什么要有这一层
///
/// 「同一个事实写在两个地方」在本仓库出过三次事，每次都是**同一个病**：
/// 两边各自的文档里写着「另一边还没同步」，而**没有任何机制提醒谁去还这笔账**。
///
/// | # | 事实 | 症状 | 出处 |
/// |---|---|---|---|
/// | 1 | 设置面板高 | 设计稿 826 / 实现 800，**分叉了整整一轮**（2026-09-18 拍板统一成 800，§8.43） | 旧守卫在 `SettingsLayoutTests` |
/// | 2 | 标题栏高 52 | `32 + 20 = 52` 内部自洽，**但 52 本身没有出处** —— 设计稿改成 56 时实现照样绿 | 旧守卫在 `TitleBarBaselineTests` |
/// | 3 | 菜单栏面板宽 360 | 断言写成 `#expect(s.width == 360)` —— **拿常量跟自己比**（§8.51 明令禁止），设计稿改成 380 时照样绿 | 本轮 |
/// | 4 | 主窗口 800×520 | **两头都没钉**：实现里写着「设计稿硬性规格」，但没有任何一处去读那个「稿」 | 本轮 |
///
/// 三次半都是「**单边改了没人知道**」。所以这里不去逐个补断言，而是把这一类事实
/// **收进一张表**：表里的每一项都一边是设计稿那个数、一边是实现那个数，两边同数才算过；
/// 而设计稿里**新声明**的尺寸令牌若不在表里，也要立刻红。
/// 于是「将来再加一个窗口 / 面板尺寸」这条路上，忘了另一边的人会被拦下 ——
/// 而不是等它在文档里躺一整轮。
///
/// ## 判据（改这张表前先读）
///
/// - **判「两边相等」，不是「等于 800」**：后者在有人把两边**同时**改成 900 时依然会红 ——
///   那是假失败，会把下一个人引向错误方向（§8.51「拿常量跟自己比 = 没牙」）。
/// - **读设计稿的源文件**（`ds.css`），不是常量自己跟自己比 —— 唯一真相在别处时，
///   测试就得去读那里（`UpdateFeedTests` 读 `build_app.sh` 是同一个道理）。
/// - ⚠️ token 一律写**声明处**（`--w-main:` 带冒号）：使用处是 `var(--w-main)`，
///   而它上方那段注释里还写着 800 / 826 —— 全文搜数字会搜到注释里的那个。
///
/// ## 三条守卫为什么是三条
///
/// 「同数」「新令牌要登记」「登记了却没了要划掉」是**三条变形轴**，合成一条就会互相掩护：
/// 只查同数，新增令牌没人管；只查登记，数字悄悄改了没人管。
/// 与 `DesignDraftIntegrityTests` 的豁免表同一个套路（§8.33 那 6 条就是只查一个方向，
/// 于是**还了账没人回来划**）。
struct WindowSizeParityTests {

    // MARK: - 同源表

    /// 设计稿那一头的**取值位置**。
    private enum Locator: Sendable {
        /// CSS 变量**声明处**（`--w-main:` 带冒号）。
        case token(String)
        /// 规则块内的属性（`.alert {` 里的 `width:`）—— 弹窗宽度不是变量，直接写在类里。
        case rule(selector: String, property: String)
    }

    private struct Pair: Sendable {
        /// 展示用的键（报错信息里出现）。
        let key: String
        let locator: Locator
        /// 实现那一头。**写成闭包是为了每次现取**：写 `{ 800 }` 就又变回「常量跟自己比」。
        let actual: @Sendable () -> CGFloat
        /// 这个数是谁。
        let label: String
    }

    /// 唯一的账本。**增删窗口尺寸必须同时动这里和 `ds.css`** —— 只动一边，本文件的三条守卫会红。
    private static let pairs: [Pair] = [
        Pair(
            key: "--w-main", locator: .token("--w-main:"),
            actual: { DesignTokens.Size.mainWindow.width },
            label: "主窗口宽"),
        Pair(
            key: "--h-main", locator: .token("--h-main:"),
            actual: { DesignTokens.Size.mainWindow.height },
            label: "主窗口高"),
        Pair(
            key: "--w-popover", locator: .token("--w-popover:"),
            actual: { DesignTokens.Size.menuPopoverWidth },
            label: "菜单栏面板宽"),
        Pair(
            key: "--w-settings", locator: .token("--w-settings:"),
            actual: { DesignTokens.Size.settingsPanel.width },
            label: "设置面板宽"),
        Pair(
            key: "--h-settings", locator: .token("--h-settings:"),
            actual: { DesignTokens.Size.settingsPanel.height },
            label: "设置面板高"),
        Pair(
            key: "--h-titlebar", locator: .token("--h-titlebar:"),
            actual: { DesignTokens.Size.titleBarHeight },
            label: "标题栏高"),
        Pair(
            key: ".alert width", locator: .rule(selector: ".alert {", property: "width:"),
            actual: { DesignTokens.Size.alertWidth },
            label: "推出弹窗宽"),
    ]

    // MARK: - 守卫

    /// 表里的每一项，设计稿那一头与实现那一头**必须同数**。
    ///
    /// ⚠️ 判据只能是「**两边相等**」。写成「等于 800」的话，有人把两边**同时**改成 900
    /// 依然会红 —— 那是假失败，会把下一个人引向错误方向（§8.51）。
    @Test func 设计稿与实现的窗口尺寸必须同数() throws {
        let css = try loadCSS()
        for p in Self.pairs {
            let design = try #require(
                Self.value(p.locator, in: css),
                "设计稿里取不到 \(p.key) 的值 —— token 改名/删了就要同步这张表")
            let impl = p.actual()
            print("  [窗口尺寸] \(p.label)：设计稿 \(design)px ｜ 实现 \(impl)pt")
            #expect(
                design == Double(impl),
                """
                \(p.label)：设计稿 \(p.key) = \(design)px，实现 = \(impl)pt —— 两边必须同数。
                改一边就要改另一边，别在文档里留一句「另一边还没同步」（§8.43 分叉一整轮的教训）。
                """
            )
        }
        // 负向锚：表被删空了，上面的循环一次都不跑，照样「全绿」。
        #expect(
            Self.pairs.count >= 6,
            "同源表只剩 \(Self.pairs.count) 项 —— 有人删行没补回来")
        // 负向锚：值取成 0 也算「同数」（两边都是 0），那不是通过。
        #expect(
            Self.pairs.allSatisfy { $0.actual() > 0 },
            "同源表里有取到 0 的项 —— 常量改名或注掉了，这里会假装一致")
    }

    /// 设计稿里**新声明**的 `--w-*` / `--h-*` 令牌，必须登记进同源表。
    ///
    /// 只查「同数」的话，有人在 `ds.css` 里加一个 `--w-onboarding: 620px`
    /// 而实现里根本没有对应常量 —— 表里没有这一项，同数守卫**一条都不会红**。
    /// 这一条负责让「新增了一个尺寸」这件事**必须走这张表**。
    @Test func 设计稿新声明的尺寸令牌必须登记进同源表() throws {
        let css = try loadCSS()
        let declared = Self.declaredSizeTokens(in: css)
        // 负向锚：正则扫不到东西时，差集是空的 —— 通过得毫无意义。
        #expect(
            declared.count >= 6,
            "只扫到 \(declared.count) 个 --w-* / --h-* 令牌 —— 解析口径失效（假绿）")

        let orphans = declared.subtracting(Self.tokenKeys).sorted()
        #expect(
            orphans.isEmpty,
            """
            ds.css 声明了这些尺寸令牌，但同源表里没有：\(orphans.joined(separator: "、"))。
            要么给它在 `DesignTokens.Size` 里配一个常量并登记进 `pairs`，
            要么说明它为什么不需要两边一致 —— **不要**放着不管，那正是 §8.43 的病。
            """)
    }

    /// 同源表里**登记了但设计稿已经没有**的令牌，要回来划掉。
    ///
    /// 只查一个方向的表会像 §8.33 那 6 条一样：**还了账没人回来划**。
    /// 留着过期条目本身无害，但它会让上面那条「新令牌要登记」形同虚设 ——
    /// 因为下一次有人删掉 CSS 里的令牌时，谁也不知道这里还记着一笔。
    @Test func 同源表里已经不存在的令牌要划掉() throws {
        let css = try loadCSS()
        let declared = Self.declaredSizeTokens(in: css)
        #expect(declared.count >= 6, "只扫到 \(declared.count) 个尺寸令牌 —— 解析口径失效（假绿）")

        let stale = Self.tokenKeys.subtracting(declared).sorted()
        #expect(
            stale.isEmpty,
            """
            同源表里记着 \(stale.joined(separator: "、"))，但 ds.css 里已经没有这几个令牌了。
            把 `pairs` 里对应那几行删掉 —— 留着它们会让「新令牌必须登记」这条守卫失去意义。
            """)
    }

    /// 同一个尺寸令牌**只能声明一次**。
    ///
    /// ⚠️ 这不是洁癖：`pxValue` 取的是「token 之后第一个 px」，
    /// 若 `:root[data-theme="dark"]` 里又写了一遍 `--w-main`，取到哪个取决于文件顺序 ——
    /// 而**两条守卫都会照常绿**（取的仍是一个真实存在的值，只是不是你想的那个）。
    /// 这种「取到错误但仍自洽」的失败，比取不到更难发现。
    @Test func 设计稿的尺寸令牌不能声明两次() throws {
        let css = try loadCSS()
        var duplicated: [String] = []
        for key in Self.tokenKeys.sorted() {
            let needle = key + ":"
            let n = css.components(separatedBy: needle).count - 1
            if n != 1 {
                duplicated.append("\(key)（\(n) 次）")
            }
        }
        #expect(
            duplicated.isEmpty,
            """
            这些令牌在 ds.css 里声明了不止一次：\(duplicated.joined(separator: "、"))。
            守卫取的是第一次出现的值 —— 深色主题里覆盖一份会让「同数」比错对象而照样绿。
            要覆盖就改成同一处声明、主题里换值，别再声明一次。
            """)
    }

    // MARK: - 解析

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCSS() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("DiskEjector-UI-Design/v2/assets/ds.css"),
            encoding: .utf8)
    }

    /// 同源表里**令牌型**那几项的键（`--w-main` 这种，**不含冒号** ——
    /// 与 `declaredSizeTokens` 的口径一致，否则两条差集守卫会**永远为空而全绿**）。
    private static var tokenKeys: Set<String> {
        var out: Set<String> = []
        for p in pairs {
            if case .token(let t) = p.locator {
                out.insert(t.hasSuffix(":") ? String(t.dropLast()) : t)
            }
        }
        return out
    }

    private static func value(_ locator: Locator, in css: String) -> Double? {
        switch locator {
        case .token(let t):
            return pxValue(in: css, token: t)
        case .rule(let selector, let property):
            guard
                let open = css.range(of: selector),
                let close = css[open.upperBound...].range(of: "}")
            else { return nil }
            // 只在**这个块内**找，否则会一路找到后面别的类里的 width。
            return pxValue(in: String(css[open.upperBound..<close.lowerBound]), token: property)
        }
    }

    /// 从 CSS 文本里取 `token` **之后**第一个 `<数字>px`。
    ///
    /// ⚠️ 只在 token 之后找：使用处是 `var(--h-titlebar)`（没有数字），
    /// 而 token 上方那段注释里还写着 800 / 826 —— 全文搜数字会搜到注释里的那个，
    /// 于是「改了 CSS 不改注释」也照样绿。
    private static func pxValue(in css: String, token: String) -> Double? {
        guard let t = css.range(of: token) else { return nil }
        let rest = css[t.upperBound...]
        guard
            let m = rest.range(of: #"[0-9]+(?:\.[0-9]+)?px"#, options: .regularExpression)
        else { return nil }
        return Double(rest[m].dropLast(2))
    }

    /// 设计稿里**声明**的 `--w-*` / `--h-*` 令牌名（不含冒号）。
    ///
    /// 只认声明处（`--w-main:`）：使用处 `var(--w-main)` 后面没有冒号，
    /// 于是「用了但没声明」不会被这里当成「已声明」。
    private static func declaredSizeTokens(in css: String) -> Set<String> {
        var out: Set<String> = []
        let pattern = #"--[wh]-[a-z]+(?:-[a-z]+)*\s*:"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let range = NSRange(css.startIndex..., in: css)
        for m in re.matches(in: css, range: range) {
            guard let r = Range(m.range, in: css) else { continue }
            let raw = css[r].trimmingCharacters(in: .whitespaces)
            out.insert(raw.hasSuffix(":") ? String(raw.dropLast()) : raw)
        }
        return out
    }
}
