import Foundation
import Testing

@testable import DiskEjectorApp

/// **「有声明、没有消费者」这一类，钉在 CI 里。**
///
/// ## 为什么需要（2026-09-18 实扫，SPEC §8.48 / §8.49）
///
/// 这是这半年里最贵的一类 bug，已经撞了三次：
///
/// | 实例 | 症状 |
/// |---|---|
/// | `UpdateController.startIfNeeded()` | updater 从未启动 → 自动更新整条链**从未跑过** |
/// | `driverDidFailDownload` | `.failed` 那一态**没有生产者** → 下载失败时进度条无声消失 |
/// | 三组 `*BusyBar*` 令牌**接错行** | 琥珀条短 4pt，而界面上与「本来就这么长」**逐字相同** |
///
/// 共性是：**界面上与「功能坏了」逐字相同，读代码也看不出来。**
/// 而 **Swift 不为字符串级常量报警** —— 删掉一个没人用的设计令牌或偏好键，
/// 代码照样编译、测试照样绿、界面看不出任何变化。它只是躺在声明表里，
/// 而下一个读到的人会以为还有一个地方在用。
///
/// 上一轮（§8.48）删掉了 **15 个**零消费者令牌 + **2 个**零消费者文案键，
/// 但**当时没有守卫** ⇒ 下一轮还会长出来。这两个 suite 就是来堵这个口子的。
///
/// ## 两个 suite 共同的口径
///
/// - **只看 `Sources/`**（不含 `Tests/`）：一个只在测试里出现的常量，生产代码里
///   没有任何地方用它 —— 那正是要人过目的事（设计令牌那边实测有 5 个属于这一类）。
/// - **去掉整行注释**：本仓库的注释习惯是**引用**被讨论的标识符
///   （这两条注释自己就提到了 `startIfNeeded` / `driverDidFailDownload`），
///   不去掉的话「把使用删掉、注释留着」依然会绿。
/// - **去掉声明自己**：否则每个常量都「消费」了它自己。
///   `static var` 的计算属性与 `enum Key { … }` 体都可能是**多行**，按花括号配平整块去掉。
/// - **exemptions是账本，不是垃圾桶**：两个方向都查 —— 新长出来的要拦下，
///   登记了却已经不作数的要回来划掉（否则就会像 §8.33 清掉的那 6 条一样，
///   **还了账没人回来划**）。
///
/// ⚠️ **已知的松**：不区分「引用的是哪个命名空间下的同名常量」，且 `static func` 体、
/// `extension` 里的引用都算消费者 —— 也就是说这两个守卫**会漏报，但不会误报**
/// （宁可漏报：误报会让人把守卫关掉）。完整的（能抓漏报的）扫描在
/// `.build/probe/keyref_scan.py`，见 §8.48。
@Suite("设计令牌的消费者")
struct DesignTokenConsumerTests {

    private let sources = SourceReader()

    private var tokensFile: URL {
        sources.repoRoot.appendingPathComponent("Sources/Views/DesignTokens.swift")
    }

    // MARK: exemptions（**这是账本，不是垃圾桶**）

    /// 设计稿里有、实现当前**不用**的值 —— 留着是为了让「设计稿 vs 实现」的对照有出处。
    ///
    /// 这些不是死代码：它们是**设计稿的字面值记录**。删掉它们，下一轮再想核对
    /// 「设计稿写的是 46 还是 48」就得回去翻 `ds.css`。
    private static let designValueRecords: [String: String] = [
        "full": "设计稿圆角 999（用 `Capsule()` 表达），此处仅作语义索引",
        "display": "设计稿字号档 20/600 —— 实现未用（弹窗标题用 `title` 15、引导标题用 `heading` 17）",
        "confirmDialogMaxWidth": "推出确认对话框宽度上限（设计稿 400，上限 420），实现按内容自适应",
        "alertFootHeight": "弹窗操作区高度（设计稿实测 54 = 按钮 30 + 上下内边距 12），实现由内边距推导",
        "systemTrafficLightCenterFromTop": "系统交通灯垂直中心实测值（16pt），用来与设计稿的 26pt 对照",
        "compactRowHeight": "紧凑行高度（设计稿实测 46），实现由内容推导",
        "aboutRowHeight": "设置面板「关于」行高度（设计稿实测 70），实现由内边距推导",
        "e2": "设计稿三档阴影之一（悬停抬升 / 浮层），实现目前只用 `e1`",
        "e3": "设计稿三档阴影之一（窗口 / 弹窗），实现目前只用 `e1`",
    ]

    /// 只被**测试**引用、生产代码不用的令牌 —— **记为待查，不是「没问题」**。
    ///
    /// 它们被测试拿来当**期望值**（例如 `MenuPopoverLayoutTests` 里的
    /// `let expected = DesignTokens.Size.menuRowHeight`）。这正是 §8.48 记过的那条：
    /// **守卫的期望值要取「设计稿的字面值」，不能取实现里的令牌** ——
    /// 否则令牌的值被人改错，断言照样绿（**拿常量跟自己比**）。
    /// 也就是说这 5 个的**值**目前没有任何东西在守。
    private static let testOnlyReferences: [String: String] = [
        "titleBarHeight": "只被 `TitleBarBaselineTests` / `MenuDiskRowLayoutTests` 引用",
        "diskRowBusyHeight": "只被 `MenuDiskRowLayoutTests` 当期望值引用",
        "diskRowSafeHeight": "只被 `MenuDiskRowLayoutTests` 当期望值引用",
        "diskRowUnknownHeight": "只被 `MenuDiskRowLayoutTests` 当期望值引用",
        "menuRowHeight": "只被 `MenuDiskRowLayoutTests` / `MenuPopoverLayoutTests` 当期望值引用",
    ]

    private static var exemptions: [String: String] {
        designValueRecords.merging(testOnlyReferences) { 设计稿侧, _ in 设计稿侧 }
    }

    // MARK: 守卫

    /// **新长出来的零消费者令牌要在这里被拦下。**
    @Test func 零消费者的令牌必须登记在案() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: tokensFile, encoding: .utf8))
        let tokens = SourceReader.staticDeclarations(in: code)
        #expect(
            tokens.count > 100,
            "只解析到 \(tokens.count) 个令牌 —— 解析逻辑多半坏了，下面的结论一律作废"
        )

        let declared = Set(tokens.map(\.name))

        // 解析器的**anchors**：几种声明形态各取一个已知令牌 ——
        // `let` 带类型（`full`）、`let` 无类型（`sm`）、`var` 单行计算属性（`raised`）、
        // `var` **多行**计算属性（`subtle`，走的是花括号配平那条路）、
        // 嵌套枚举里的（`window`）、`e1`。
        // 少了它们说明「收声明」的逻辑退化了（例如 `static var` 整类没收到），
        // 而那种情况下「未登记」会**空着** —— 通过得毫无意义。
        let anchors = ["full", "sm", "display", "window", "raised", "subtle", "e1"]
        let missingAnchors = anchors.filter { !declared.contains($0) }.sorted()
        #expect(missingAnchors.isEmpty, "解析器漏掉了这些已知令牌：\(missingAnchors) —— 收声明的逻辑退化了，下面的结论作废")

        let (corpus, fileCount) = try sources.corpus(
            excluding: [tokensFile.lastPathComponent: tokens.map(\.text)])
        #expect(fileCount > 30, "只读到 \(fileCount) 个 .swift —— 路径多半不对，下面的结论一律作废")

        let unregistered =
            declared
            .subtracting(Self.exemptions.keys)
            .filter { !SourceReader.isReferenced($0, in: corpus) }
            .sorted()

        #expect(
            unregistered.isEmpty,
            """
            这些设计令牌在 Sources/ 里没有任何消费者：\(unregistered)。\
            删掉它们不会编译失败、不会让任何测试变红、界面也不会有任何变化 —— \
            只是躺在令牌表里，而下一个读到的人会以为还有一个地方在用它们。
            要么接上真正的使用点，要么删掉；若确实是「designValueRecords」\
            （设计稿里有、实现当前不用），把它登记进 `designValueRecords` 并写明理由。
            """
        )
    }

    /// **exemptions不许过期** —— 账本要能自己对上。
    @Test func 令牌exemptions不许过期() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: tokensFile, encoding: .utf8))
        let tokens = SourceReader.staticDeclarations(in: code)
        let declared = Set(tokens.map(\.name))
        let (corpus, _) = try sources.corpus(
            excluding: [tokensFile.lastPathComponent: tokens.map(\.text)])

        let noLongerDeclared = Self.exemptions.keys.filter { !declared.contains($0) }.sorted()
        #expect(
            noLongerDeclared.isEmpty,
            "exemptions里登记了这些令牌，但它们已经不在 DesignTokens.swift 里了：\(noLongerDeclared)。从exemptions删掉"
        )

        let nowConsumed =
            Self.exemptions.keys
            .filter { declared.contains($0) && SourceReader.isReferenced($0, in: corpus) }
            .sorted()
        #expect(
            nowConsumed.isEmpty,
            """
            这些令牌已经有生产代码消费者了：\(nowConsumed)。\
            豁免的前提是「没有生产代码消费者」，现在不成立了 —— 回来把它们从exemptions里划掉。
            """
        )
    }
}

/// **偏好键必须有「生产代码」消费者**（`Key.<名>` 形式）。
///
/// 口径与上面那个 suite 完全一致，只有「怎么算消费者」不同：
/// 偏好键的消费者是 `Key.<名>`（可带 `AppSettings.` 前缀），**不能按裸名判** ——
/// `accentColor` / `visualStyle` 同时是 ``AppSettings`` 上的属性名，
/// 按裸名判会把「属性被读到」当成「键被用到」。
///
/// ⚠️ 另一个实测过的坑：**不能把整个声明文件排除**。`hasShownFDAOnboarding` 的消费者
/// `AppSettings.didShowFDAOnboarding` **就在同一个文件里** —— 所以只剥掉 `enum Key { … }`
/// 那一块，文件其余部分照常参与。
@Suite("偏好键的消费者")
struct PreferenceKeyConsumerTests {

    private let sources = SourceReader()

    private var settingsFile: URL {
        sources.repoRoot.appendingPathComponent("Sources/Settings/AppSettings.swift")
    }

    /// `launchAtLogin` 的键由 ``LaunchAtLoginManager`` 持有，`Key` 里那条
    /// **仅作文档索引**（它自己的文档注释就这么写的）—— 生产代码不消费它是**有意为之**。
    private static let exemptions: [String: String] = [
        "launchAtLogin": "键由 `LaunchAtLoginManager.defaultsKey` 持有，`Key` 里这条仅作文档索引"
    ]

    @Test func 零消费者的偏好键必须登记在案() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: settingsFile, encoding: .utf8))
        let keys = SourceReader.keyEnumDeclarations(in: code)
        #expect(
            keys.count >= 5,
            "只解析到 \(keys.count) 个偏好键 —— 解析逻辑多半坏了，下面的结论一律作废"
        )

        let declared = Set(keys.map(\.name))
        let (corpus, fileCount) = try sources.corpus(
            excluding: [settingsFile.lastPathComponent: keys.map(\.text)])
        #expect(fileCount > 30, "只读到 \(fileCount) 个 .swift —— 路径多半不对，下面的结论一律作废")

        let unregistered =
            declared
            .subtracting(Self.exemptions.keys)
            .filter { !SourceReader.isKeyReferenced($0, in: corpus) }
            .sorted()

        #expect(
            unregistered.isEmpty,
            """
            这些偏好键在 Sources/ 里没有任何消费者：\(unregistered)。\
            删掉它们不会编译失败、不会让任何测试变红 —— 只是躺在 `AppSettings.Key` 里，
            而下一个读到的人会以为还有一个设置项在用它们。
            """
        )
    }

    @Test func 偏好键exemptions不许过期() throws {
        let code = SourceReader.codeOnly(try String(contentsOf: settingsFile, encoding: .utf8))
        let keys = SourceReader.keyEnumDeclarations(in: code)
        let declared = Set(keys.map(\.name))
        let (corpus, _) = try sources.corpus(
            excluding: [settingsFile.lastPathComponent: keys.map(\.text)])

        let noLongerDeclared = Self.exemptions.keys.filter { !declared.contains($0) }.sorted()
        #expect(noLongerDeclared.isEmpty, "exemptions里登记了这些偏好键，但它们已经不在 `enum Key` 里了：\(noLongerDeclared)")

        let nowConsumed =
            Self.exemptions.keys
            .filter { declared.contains($0) && SourceReader.isKeyReferenced($0, in: corpus) }
            .sorted()
        #expect(nowConsumed.isEmpty, "这些偏好键已经有生产代码消费者了：\(nowConsumed)。回来从exemptions里划掉")
    }
}

// MARK: - 共用的读源工具

/// 读 `Sources/` 的小工具：两个 suite 共用同一套口径（见文件头的说明）。
private struct SourceReader {

    /// `#filePath` = `<仓库根>/Tests/DiskEjectorAppTests/<本文件>.swift`
    let repoRoot: URL

    init(filePath: String = #filePath) {
        repoRoot =
            URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()  // DiskEjectorAppTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
    }

    var sourcesRoot: URL { repoRoot.appendingPathComponent("Sources") }

    /// 去掉**整行**注释（行首空白后以 `//` 开头）。
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `Sources/` 全部 `.swift` 去注释后的正文拼成的语料。
    ///
    /// `excluding`：`文件名 → 要从该文件里剥掉的整块文本`（常量自己的声明）。
    func corpus(excluding blocks: [String: [String]] = [:]) throws -> (text: String, fileCount: Int) {
        guard let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(sourcesRoot.path)")
            return ("", 0)
        }
        var pieces: [String] = []
        var fileCount = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            fileCount += 1
            var code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            for block in blocks[url.lastPathComponent] ?? [] {
                code = code.replacingOccurrences(of: block, with: "")
            }
            pieces.append(code)
        }
        return (pieces.joined(separator: "\n"), fileCount)
    }

    /// 语料里有没有这个标识符的**独立**出现（前后不是标识符字符）。
    static func isReferenced(_ name: String, in corpus: String) -> Bool {
        matches(
            pattern: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])", in: corpus)
    }

    /// 偏好键的消费者写法：`Key.<名>`（可带 `AppSettings.` 前缀）。
    ///
    /// ⚠️ 负向断言里**不能带 `.`**：`(?<![\w.])Key\.x` 本意是「别匹配 `FooKey.x`」，
    /// 实际会把 `AppSettings.Key.x` 也整个挡掉 —— 实测让 7 个键**全部误报**零引用。
    /// `(?<![A-Za-z0-9_])` 既能挡住 `myKey.x`，又放得过 `AppSettings.Key.x`。
    static func isKeyReferenced(_ name: String, in corpus: String) -> Bool {
        matches(
            pattern: "(?<![A-Za-z0-9_])Key\\.\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])",
            in: corpus)
    }

    private static func matches(pattern: String, in corpus: String) -> Bool {
        corpus.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: 收声明

    /// 一条声明：名字 + **整块原文**（多行声明会连体一起给出，供语料剥离）。
    struct Declaration {
        let name: String
        let text: String
    }

    /// 声明模式。
    ///
    /// ⚠️ 用 `[ \t]*` 而**不是** `\s*`：`\s` 含换行，匹配起点会落到上一行空行上，
    /// 行号跟着错（实测踩过，零消费者名单因此对不上）。
    private static let declarationPattern = #"^[ \t]*static (?:let|var) ([A-Za-z_][A-Za-z0-9_]*)"#

    /// 收 `static let` / `static var` 声明（全文）。
    static func staticDeclarations(in code: String) -> [Declaration] {
        declarations(in: code.components(separatedBy: "\n"))
    }

    /// 收 `enum Key { … }` 块里的 `static let` / `static var`。
    ///
    /// ⚠️ **只剥这一块，不能整文件排除**：`Key.hasShownFDAOnboarding` 的消费者
    /// `AppSettings.didShowFDAOnboarding` **就在同一个文件里** ——
    /// 整文件排除会让它误报零引用（实测踩过）。
    static func keyEnumDeclarations(in code: String) -> [Declaration] {
        let lines = code.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { Self.isKeyEnumOpening($0) }) else { return [] }
        // `enum Key {` 这一行自身带一个 `{`，从它开始配平即可取到整块。
        var end = start
        var depth = braceDelta(lines[start])
        var next = start + 1
        while next < lines.count, depth > 0 {
            depth += braceDelta(lines[next])
            end = next
            next += 1
        }
        return declarations(in: Array(lines[start...end]))
    }

    private static func isKeyEnumOpening(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^[ \t]*enum Key[ \t]*\{"#) else {
            return false
        }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            != nil
    }

    /// 按花括号配平把整条声明吃下来（`static var` 的计算属性可能是多行 ——
    /// 不整块剥掉的话，它体内对**别的**常量的引用会留在语料里，
    /// 把那些常量判成「有消费者」）。
    private static func declarations(in lines: [String]) -> [Declaration] {
        guard let regex = try? NSRegularExpression(pattern: declarationPattern) else { return [] }
        var found: [Declaration] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let whole = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: whole),
                let nameRange = Range(match.range(at: 1), in: line)
            else {
                index += 1
                continue
            }
            // `static var` 的计算属性可能是多行 → 按花括号配平吃完整块，
            // 否则它体内对**别的**常量的引用会留在语料里，把那些常量判成「有消费者」。
            var end = index
            var depth = braceDelta(line)
            if depth > 0 {
                var next = index + 1
                while next < lines.count, depth > 0 {
                    depth += braceDelta(lines[next])
                    end = next
                    next += 1
                }
            }
            found.append(
                Declaration(
                    name: String(line[nameRange]),
                    text: lines[index...end].joined(separator: "\n")))
            index = end + 1
        }
        return found
    }

    /// 一行里花括号的净增量。
    private static func braceDelta(_ line: String) -> Int {
        line.reduce(0) { $0 + ($1 == "{" ? 1 : ($1 == "}" ? -1 : 0)) }
    }
}
