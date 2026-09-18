import Foundation
import Testing

@testable import DiskEjectorApp

/// 设计稿（HTML 原型）自身的**完整性**守卫，两个维度：
///
/// 1. **CSS 类**：「用了但没有定义」必须登记（拼错类名 / 删了 CSS 忘了改 HTML）。
/// 2. **i18n 键**：`i18n-extra.json` 里声明的键必须**有页面在用**（否则是死文案）。
///
/// 这两个都属于「**有声明、没有消费者**」—— Swift 侧已经在 §8.50 钉住了
/// （`DeclarationConsumerTests`），设计稿侧此前**一条都没有**。
/// 而 §8.51 刚证明设计稿是「唯一真相」的来源：**它腐化了，同源守卫全会被误导**。
///
/// **为什么守这一向，不守另一向**：设计稿里「定义了但没元素用」的类**多数是合理的**
/// （备用样式、无障碍 `.sr-only`、文档样例）—— §8.52.5 记过：**零消费者 ≠ 可删**，
/// 删设计稿的类会改变视觉。所以那一向只**打印**，不报警。
///
/// 反过来，「用了但没定义」**一定是问题**：要么是类名拼错（`.aboutroww`），
/// 要么是删了 CSS 忘了改 HTML。它的症状是「样式没生效」——
/// 而**「样式没生效」与「本来就没写样式」在界面上逐字相同**，读代码看不出来。
/// 这一条负责把两者分开。
///
/// **定义源有两个，别漏**（§8.52.1）：主 CSS `assets/ds.css` **加上每个 HTML 的 `<style>` 块**
/// —— 实测 9 个页面共 225 行 `<style>`，`.aboutrow` 的样式就在那里，只扫主 CSS 会误报。
@MainActor
struct DesignDraftIntegrityTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/DesignDraftClassTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var designRoot: URL {
        repoRoot.appendingPathComponent("DiskEjector-UI-Design/v2")
    }

    // MARK: 豁免表

    /// 「用了但没定义」的**账本** —— 两个方向都查（新出现的要拦下，登记了却已经
    /// 不存在的要回来划掉）。只查一个方向，这张表就会像 §8.33 清掉的那 6 条一样：
    /// **还了账没人回来划**。
    ///
    /// 这 4 个都是**纯容器 / 语义类**：只有结构作用，本来就不该有样式。
    private static let containerOnly: [String: String] = [
        "ds": "文档根容器（`<body class=\"ds\">`），只用来挂主题与语言",
        "row__evid": "完整行的「证据区」容器，样式走 `.evid*`，本身无规则",
        "spec": "index.html 的规格表容器",
        "state-tbl": "状态矩阵表格（样式写在 `06-states.html` 的 `<style>` 里，见 `table.state-tbl`）",
    ]

    // MARK: 守卫

    /// 设计稿里**用了但没有任何 CSS 定义**的类，必须全在豁免表里。
    @Test func 用了但没定义的类必须登记在案() throws {
        let scan = try load()
        // 解析器的**锚**：下面几条不成立，说明扫描逻辑退化了，
        // 而那种情况下「未定义」会**空着** —— 通过得毫无意义。
        #expect(scan.defined.count > 150, "只解析到 \(scan.defined.count) 个类 —— 扫描逻辑多半坏了")
        #expect(scan.used.count > 150, "只收集到 \(scan.used.count) 个类 —— HTML 没读到")
        #expect(
            scan.defined.contains("row"), "`.row` 都没解析到 —— 定义源（ds.css / `<style>`）没读到")
        #expect(scan.used.contains("row"), "`.row` 都没收集到 —— HTML 的 class 属性没读到")
        #expect(
            scan.defined.contains("aboutrow"),
            "`.aboutrow` 必须能解析到 —— 它的样式在 05-settings.html 的 `<style>` 里，只扫 ds.css 会漏掉（§8.52.1）"
        )

        let missing = scan.used.subtracting(scan.defined).subtracting(Self.containerOnly.keys)
        #expect(
            missing.isEmpty,
            """
            设计稿里这些类**被元素用着，但没有任何 CSS 定义**（多半是类名拼错，或删了 CSS 忘了改 HTML）：
            \(missing.sorted().joined(separator: ", "))
            已知的无样式容器类登记在 `containerOnly` 里；新增的要连同理由一起登记。
            """
        )
    }

    /// 豁免表**不许过期**：登记的类如果已经有了定义，要回来划掉。
    @Test func 豁免表里已经定义了的类要划掉() throws {
        let scan = try load()
        let stale = Self.containerOnly.keys.filter { scan.defined.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些类登记为「没有定义」，但现在**已经有定义了**：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """
        )
    }

    /// 豁免表的第三向：登记的类如果**已经没人用了**，也要回来划掉。
    ///
    /// 前两条只堵「登记了却有定义」（= 记账记错）；这一条堵「登记了但对象没了」
    /// —— 那种条目永远不会被任何断言碰到，只会**安静地烂在表里**。
    @Test func 豁免表里已经没人用的类要划掉() throws {
        let scan = try load()
        let stale = Self.containerOnly.keys.filter { !scan.used.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些类登记为「无样式容器」，但设计稿里**已经没有任何元素在用**它们：
            \(stale.sorted().joined(separator: ", "))
            要么把类也删掉，要么回来把这一条划掉 —— 留着它永远不会有人再看第二眼。
            """
        )
    }

    /// 反向（定义了但没元素用）**只打印不报警** —— §8.52.5：零消费者 ≠ 可删。
    @Test func 反向扫描只记录不报警() throws {
        let scan = try load()
        let unused = scan.defined.subtracting(scan.used).sorted()
        print("  [设计稿] 定义了但没元素用：\(unused.count) 个 —— \(unused.joined(separator: ", "))")
        // 只留一条极松的自检：数字不该是 0（那说明「定义」没扫到），也不该接近全部
        #expect(!unused.isEmpty, "一个零消费者都没有 —— 「定义」那一向多半没扫到")
        #expect(unused.count < scan.defined.count / 2, "零消费者超过一半 —— 解析多半出了问题")
    }

    // MARK: 图标

    /// 设计稿里**用了但图标表里没有**的名字，必须为零 —— 一个都不许有。
    ///
    /// 为什么这一向比另一向重要得多：`ds.js` 的 `build(name)` 里是
    /// `var body = I[name]; if (!body) return '';` —— **名字写错就返回空串**。
    /// 于是 `<i data-i="ejct">` 渲染出来**什么都没有**，而
    /// **「图标是空白」与「这块本来就没放图标」在界面上逐字相同**，读 HTML 看不出来。
    @Test func 用了但图标表里没有的名字一个都不许有() throws {
        let (defined, used) = try loadIcons()
        // 解析器的**锚**：图标表要是没解析到，下面的差集会空着，通过得毫无意义
        #expect(defined.count > 25, "只解析到 \(defined.count) 个图标 —— 图标表没读到")
        #expect(defined.contains("eject"), "`eject` 都没解析到 —— 图标表结构变了？")
        #expect(used.contains("eject"), "`eject` 明明在用却没收集到 —— data-i 的扫描坏了")

        let missing = used.subtracting(defined)
        #expect(
            missing.isEmpty,
            """
            这些图标名被 `<i data-i="…">` 用着，但 `ds.js` 的图标表里**没有**：
            \(missing.sorted().joined(separator: ", "))
            `build()` 对未知名字返回**空串** ⇒ 这些位置渲染出来是**空白**，
            而「图标是空白」与「本来就没放图标」长得一模一样。
            """
        )
    }

    /// 图标表里**定义了但没用**的名字 —— 只打印。
    ///
    /// 图标表是**库**（和 `ds.css` 一样是组件库），**库里允许有存货**；
    /// i18n 文案是**内容**，内容不允许有孤儿。判据见 §8.54.2。
    @Test func 图标表里的存货只记录不报警() throws {
        let (defined, used) = try loadIcons()
        let spare = defined.subtracting(used).sorted()
        print("  [设计稿] 图标表存货：\(spare.count) 个 —— \(spare.joined(separator: ", "))")
        #expect(!spare.isEmpty, "一个存货都没有 —— 「定义」那一向多半没扫到")
        #expect(spare.count < defined.count / 2, "存货超过一半 —— 解析多半出了问题")
    }

    // MARK: i18n

    /// `i18n-extra.json` 里**声明了但没有页面在用**的键 —— 死文案，登记在案。
    ///
    /// 与 CSS 类**不同**：删掉一个没用的文案键**不改变任何渲染**，所以这一向是
    /// 「零消费者 = 可删」。但仍然**登记而不是立刻删** —— 因为有些是
    /// 「备着给还没画的样本用的」，那是设计决策，不该由扫描器替人决定（§8.52.5 同理）。
    private static let unusedI18nKeys: [String: String] = [
        "ds.sample.cap.usedFreeC": """
        2 TB 那块盘的「已用 / 剩余」文案。它没被用掉是因为**设计稿里 2 TB 只有紧凑行样本**
        （`ds.sample.cap.compactC`），**没有菜单行样本** —— 菜单行只有 1 TB / 500 GB 两块
        （用 `usedFreeA` / `usedFreeB`）。补一行 2 TB 菜单样本、或删这个键，都是设计决策。
        """
    ]

    /// 声明了但没页面在用的文案键，必须全在豁免表里。
    @Test func 声明了但没有页面在用的文案键必须登记在案() throws {
        let (declared, referenced) = try loadI18n()
        // 解析器的**锚**
        #expect(declared.count > 30, "只解析到 \(declared.count) 个键 —— i18n-extra.json 没读到")
        #expect(
            declared.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 都没解析到 —— 键名格式变了？")
        #expect(
            referenced.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 明明被 02-menu-bar 用着却没收集到 —— 消费源扫错了")

        let dead = declared.subtracting(referenced).subtracting(Self.unusedI18nKeys.keys)
        #expect(
            dead.isEmpty,
            """
            这些文案键在 `i18n-extra.json` 里声明了，但**没有任何页面在用**（死文案）：
            \(dead.sorted().joined(separator: ", "))
            要么给它找一个 `data-i18n` 消费者，要么把键删掉 —— 留着它永远不会有人再看第二眼。
            """
        )
    }

    /// 豁免表**不许过期**：登记为「没人用」的键如果已经有页面在用了，要回来划掉。
    @Test func 已登记的文案键如果有页面在用了要划掉() throws {
        let (_, referenced) = try loadI18n()
        let stale = Self.unusedI18nKeys.keys.filter { referenced.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些键登记为「没有页面在用」，但现在已经**有消费者**了：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """
        )
    }

    /// 页面**引用了但声明集里没有**的键 —— 静默回退，一个都不许有。
    ///
    /// `tools/build_i18n.py` 的注释自己写着：「抄漏一条不会报错，只会在切到那门语言时
    /// **静默回退成中文** —— 而『回退』和『翻好了』长得一模一样」。
    /// 声明集是 **`i18n-extra.json` ∪ `Localizable.xcstrings`**（设计稿可以引用产品已有文案）。
    @Test func 页面引用了但没有声明的文案键一个都不许有() throws {
        let (_, referenced) = try loadI18n()
        let declared = try Self.declaredTextKeys(repoRoot: repoRoot)
        #expect(declared.count > 150, "只解析到 \(declared.count) 个键 —— xcstrings 没读到")
        #expect(
            declared.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 不在声明集里 —— xcstrings / i18n-extra 都没读到")

        let missing = referenced.subtracting(declared)
        #expect(
            missing.isEmpty,
            """
            这些 `data-i18n` 引用的键**在任何一处都没有声明**：
            \(missing.sorted().joined(separator: ", "))
            切到英文/繁体时会**静默回退成中文** —— 和「翻好了」长得一模一样。
            """
        )
    }

    // MARK: 扫描

    private struct Scan {
        var defined: Set<String> = []
        var used: Set<String> = []
    }

    private func load() throws -> Scan {
        let fm = FileManager.default
        var scan = Scan()

        // ① 主 CSS
        let cssURL = designRoot.appendingPathComponent("assets/ds.css")
        scan.defined.formUnion(Self.selectorClasses(in: Self.stripCSSComments(try read(cssURL))))

        // ② 每个 HTML：`<style>` 进「定义」，body 的 class 进「使用」
        let htmls = try htmlFiles()
        #expect(htmls.count >= 8, "只找到 \(htmls.count) 个 HTML —— 设计稿目录不对")
        for url in htmls {
            let raw = try read(url)
            for block in Self.styleBlocks(in: raw) {
                scan.defined.formUnion(Self.selectorClasses(in: Self.stripCSSComments(block)))
            }
            scan.used.formUnion(Self.classAttributes(in: Self.withoutStyleBlocks(raw)))
        }

        // ③ ds.js 动态注入的类也算消费者
        let jsURL = designRoot.appendingPathComponent("assets/ds.js")
        if fm.fileExists(atPath: jsURL.path) {
            scan.used.formUnion(Self.classAttributes(in: try read(jsURL)))
        }
        return scan
    }

    /// 返回（声明的键，被页面引用的键）。
    private func loadI18n() throws -> (declared: Set<String>, referenced: Set<String>) {
        let url = designRoot.appendingPathComponent("assets/i18n-extra.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            Issue.record("i18n-extra.json 顶层不是对象")
            return ([], [])
        }
        // `_comment` 是注释键，不是文案
        let declared = Set(dict.keys.filter { !$0.hasPrefix("_") })

        var referenced: Set<String> = []
        var corpus = ""
        for url in try htmlFiles() {
            corpus += Self.withoutStyleBlocks(try read(url))
        }
        let jsURL = designRoot.appendingPathComponent("assets/ds.js")
        if FileManager.default.fileExists(atPath: jsURL.path) { corpus += try read(jsURL) }

        // ① 精确形式：`data-i18n="key"`
        for m in Self.matches(in: corpus, pattern: #"data-i18n="([^"]+)""#) { referenced.insert(m) }
        // ② 精确形式：`data-i18n-attr="aria-label:key,title:key"` —— 冒号后面那半截才是键
        for raw in Self.matches(in: corpus, pattern: #"data-i18n-attr="([^"]+)""#) {
            for pair in raw.split(separator: ",") {
                if let v = pair.split(separator: ":").last { referenced.insert(String(v)) }
            }
        }
        // ③ 兜底（**偏松**）：键名以带引号的字符串形式出现就算被引用。
        //    会漏报、不会误报 —— 宁可放过，也不能把活着的键判成死的。
        for k in declared where corpus.contains("\"\(k)\"") { referenced.insert(k) }
        return (declared, referenced)
    }

    /// 返回（图标表里定义的名字，被 `data-i` 用到的名字）。
    private func loadIcons() throws -> (defined: Set<String>, used: Set<String>) {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        // 图标表：`var I = { … }`，以缩进 2 空格的 `};` 收尾
        guard let block = Self.matches(in: js, pattern: #"var I = \{([\s\S]*?)\n  \};"#).first else {
            Issue.record("ds.js 里找不到 `var I = { … }` 图标表 —— 结构变了？")
            return ([], [])
        }
        let defined = Set(Self.matches(in: block, pattern: #"^\s*(\w+)\s*:"#, lines: true))

        var used: Set<String> = []
        for url in try htmlFiles() { used.formUnion(Self.matches(in: try read(url), pattern: #"data-i="([^"]+)""#)) }
        used.formUnion(Self.matches(in: js, pattern: #"data-i="([^"]+)""#))
        // i18n 文案值里也可以嵌 `<i data-i="gear">`（回填后会重新水合）
        let extraURL = designRoot.appendingPathComponent("assets/i18n-extra.json")
        if FileManager.default.fileExists(atPath: extraURL.path) {
            used.formUnion(Self.matches(in: try read(extraURL), pattern: #"data-i="([^"]+)""#))
        }
        return (defined, used)
    }

    /// 文案键的**声明集** = `i18n-extra.json` ∪ `Localizable.xcstrings`。
    private static func declaredTextKeys(repoRoot: URL) throws -> Set<String> {
        var out: Set<String> = []
        let extraURL = repoRoot.appendingPathComponent(
            "DiskEjector-UI-Design/v2/assets/i18n-extra.json")
        if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: extraURL)) as? [String: Any] {
            out.formUnion(obj.keys.filter { !$0.hasPrefix("_") })
        }
        let xcsURL = repoRoot.appendingPathComponent("Sources/Localization/Localizable.xcstrings")
        if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: xcsURL)) as? [String: Any],
            let strings = obj["strings"] as? [String: Any]
        {
            out.formUnion(strings.keys)
        }
        return out
    }

    /// 取正则的第 1 捕获组。
    /// - parameter lines: 需要 `^` 按行匹配时打开（例如逐行取对象的键）。
    private static func matches(in text: String, pattern: String, lines: Bool = false) -> [String] {
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: lines ? [.anchorsMatchLines] : []
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func htmlFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: designRoot, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "html" }.sorted { $0.path < $1.path }
    }

    /// 去掉 `/* … */` 注释（注释里常写着别的数字 / 类名，不剥会误收）。
    private static func stripCSSComments(_ text: String) -> String {
        Self.replace(in: text, pattern: #"/\*[\s\S]*?\*/"#, with: " ")
    }

    /// 取 `<style>` 块 —— **第二个定义源**，别漏（§8.52.1）。
    private static func styleBlocks(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<style[^>]*>([\s\S]*?)</style>"#) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return re.matches(in: html, range: range).compactMap { m in
            Range(m.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func withoutStyleBlocks(_ html: String) -> String {
        Self.replace(in: html, pattern: #"<style[^>]*>[\s\S]*?</style>"#, with: " ")
    }

    /// 只取**选择器位置**的类名 —— 先抹掉声明体，否则属性值里的 `.5px` 之类会被误收。
    private static func selectorClasses(in css: String) -> Set<String> {
        var text = css
        // `@media (…) {` 的条件部分先抹掉（保留 `{`），否则里面的类会被当成属性值
        text = Self.replace(in: text, pattern: #"@media[^{]*"#, with: " ")
        text = Self.replace(in: text, pattern: #"\{[^}]*\}"#, with: "{ }")
        guard
            let re = try? NSRegularExpression(
                pattern: #"(?:^|[\s,>+~])\.([a-zA-Z][\w-]*)"#, options: [.anchorsMatchLines]
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(
            re.matches(in: text, range: range).compactMap { m in
                Range(m.range(at: 1), in: text).map { String(text[$0]) }
            })
    }

    private static func classAttributes(in html: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"class="([^"]*)""#) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var out: Set<String> = []
        for m in re.matches(in: html, range: range) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            out.formUnion(String(html[r]).split(separator: " ").map(String.init))
        }
        return out
    }

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
