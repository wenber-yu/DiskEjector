import Foundation
import Testing

/// **文档里的表格必须「渲染得出来」** —— 这条此前一条守卫都没有，而它**真的丢过内容**。
///
/// ## 为什么值得守（2026-09-20 实测，见 §8.104.5）
///
/// 那张「仍开着」表上有三行，把「已关闭」说明写进了**多余的单元格**：
///
/// ```
/// | 35 | … | 我（下一轮） | §8.86.7 | ⬜ 仍开着（§8.86 新开）。… | ⚠️ **§8.89 追加**：… |
///                                                              ↑ 这个 `|` 让整行多出一格
/// ```
///
/// GFM 的规矩：**一行比表头多出的单元格会被忽略** ⇒ 渲染后**那一整段根本看不见**。
/// 用 `markdown-it`（commonmark + table）实测，三个探针**全部为 False**：
///
/// | 探针 | 源文件里 | 渲染后 |
/// |---|---|---|
/// | 第 35 行 `§8.89 追加` | 在 | **❌ 没了** |
/// | 第 38 行 `新开第 40 行` | 在 | **❌ 没了** |
/// | 第 39 行 `三分支` | 在 | **❌ 没了** |
///
/// ⇒ 三轮的「还账」在**渲染视图**里等于**没写**。这与本仓库的老毛病是同一个：
/// **「写了」不等于「生效了」** —— 只是这次的判据是**渲染器**，而它不报错、不警告，
/// 与「真没有」**逐字相同**。
///
/// ## 第二轴：**续行会把一张表撕开**
///
/// 单元格内容换行写（下一行不以 `|` 开头）看着舒服，但 GFM 的表**一行就是一行**。
/// 实测：第 34 / 36 行的续行让同一张表渲染成 **51 个 `<tr>`**（应为 **42**），
/// 续行变成独立行、正文挤进「#」列。⇒ **要换行请用 `<br>`**（本仓库别的表就是这么写的，见 §8.86.4）。
///
/// ## 两条判据都在这里，并且**自己也被验**（`表格判据的双向对照`）
///
/// 「没报缺陷」有两种可能：文档真的干净，或者**判据是瞎的**。两者输出逐字相同 ⇒
/// 必须拿「该报的样本」与「不该报的样本」各试一次。
///
/// ## ⚠️ 边界：**表尾**的续行查不出来
///
/// 「表块后面跟着一行非表格行」有两种含义 ——「表正常结束了」与「续行跑出去了」——
/// **在语法上长得一模一样**。所以判据只报**表中间**那一种（续行后面**又是** `|` 行）。
/// 表尾那一半靠的是「某张表最后一行必须是 `| 41 |`」这类**逐表**断言，本守卫不覆盖 ——
/// 别把「这条绿了」读成「所有表都渲染得出来」。
@Suite struct DocTableIntegrityTests {

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/DocTableIntegrityTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// 扫描范围 = **仓库里被 git 跟踪的 `.md`**（`git ls-files '*.md'`，当前 4 个）。
    ///
    /// ⚠️ **范围本身是判据**（§8.75）：2026-09-20 实测 —— `git ls-files '*.md'` 只有 4 个，
    /// 而此前这里只列了 2 个，**漏掉了 `README.md`（它有一个 10 行的「能力」表）**。
    /// ⇒ 凡是**被 git 跟踪**的 `.md` 都要进来；漏一份 = 那份文档里的表格永远没人守。
    ///
    /// **不进范围的**（有依据，不是漏）：`.workbuddy*/memory/*.md` —— 被 `.gitignore`
    /// 排除（`.gitignore:28` / `:30`）⇒ **CI 上根本不存在**，扫它们只会在 CI 上读不到文件。
    /// （本机实测它们有 199 个表块；要检查就手工跑 `.build/probe/round41/table_check.py`。）
    ///
    /// ⚠️ **别在这里抄表块数** —— 2026-09-20 实测：同一个数字此前在**三处**被抄成了 353
    /// （真值 354，见 §8.104.7）。要真值就用 `.build/probe/round41/blocks.swift` 打 ——
    /// **本守卫只断言下限（`>= 300`，约为当时实测总量的 83%），打印不出真值**，
    /// 所以「写错的数字」能在它这里活下来。
    private static let docs = [
        "DiskEjector-UI-Design/v2/DESIGN-SPEC.md",
        "SPEC.md",
        "README.md",
        "release-notes/README.md",
    ]

    // MARK: 判据（纯函数 —— 样本可以直接喂给它，不必改仓库里的文档）

    struct Defect: CustomStringConvertible {
        var line: Int
        var what: String
        var description: String { "L\(line)：\(what)" }
    }

    struct Result {
        var blocks = 0
        var defects: [Defect] = []
    }

    /// **未转义**的 `|` 个数。`\|` 是转义（本仓库在单元格里写 `尚未\|还没` 就是这么写的），
    /// 不算列分隔符 —— 漏了这一条会报出成片假红（本守卫的第一版就栽在这儿）。
    static func unescapedPipes(_ s: String) -> Int {
        var n = 0
        var prev: Character?
        for ch in s {
            if ch == "|", prev != "\\" { n += 1 }
            prev = ch
        }
        return n
    }

    /// 分隔行 `|---|---|`。
    static func isSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let inner = t.dropFirst().dropLast()
        return !inner.isEmpty && inner.allSatisfy { $0 == "-" || $0 == "|" || $0 == " " || $0 == ":" }
    }

    /// 剥掉围栏代码块（围栏里的 `|` 不是表格）。**保留行数**，这样报出来的行号仍是对的。
    static func stripFences(_ raw: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                out.append("")
                continue
            }
            out.append(inFence ? "" : line)
        }
        return out
    }

    /// 扫一份文档，返回表块数与结构缺陷。
    static func scan(_ raw: String) -> Result {
        let lines = stripFences(raw)
        var res = Result()
        var i = 0
        while i < lines.count {
            guard lines[i].hasPrefix("|") else {
                i += 1
                continue
            }
            let start = i
            while i < lines.count, lines[i].hasPrefix("|") { i += 1 }
            let end = i - 1
            res.blocks += 1

            // ① 撕表：表块后面紧跟一行「非空、不以 `|` 开头」，而**再下一行又是** `|`
            //    ⇒ 那一行是续行，渲染时会把表撕成两张（本仓库实测 51 个 <tr> vs 应有的 42）。
            if i < lines.count,
                !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                !lines[i].hasPrefix("|"),
                i + 1 < lines.count, lines[i + 1].hasPrefix("|")
            {
                res.defects.append(
                    Defect(line: end + 2, what: "表被非表格行打断 —— 续行会渲染成独立行，请改用 `<br>`"))
            }

            // ② 列数：每一行必须与**本块表头**一样多（多出的单元格渲染时会被丢掉）
            guard end > start else { continue }
            let want = unescapedPipes(lines[start])
            for j in (start + 1)...end where !isSeparator(lines[j]) {
                let got = unescapedPipes(lines[j])
                if got != want {
                    res.defects.append(
                        Defect(
                            line: j + 1,
                            what: "未转义管道 \(got) ≠ 表头 \(want) —— 多出的单元格渲染时会被丢掉（等于没写）"))
                }
            }
        }
        return res
    }

    // MARK: 守卫

    @Test func 文档里的表格必须渲染得出来() throws {
        var blocks = 0
        var defects: [String] = []
        for doc in Self.docs {
            let raw = try read(doc)
            let r = Self.scan(raw)
            blocks += r.blocks
            defects += r.defects.map { "\(doc) \($0)" }
        }

        // 正向锚：表块数不能塌 —— 否则「没缺陷」只是「没扫到」（假绿）
        #expect(blocks >= 300, "只解析到 \(blocks) 个表块 —— 扫描口径失效了（假绿）")

        #expect(
            defects.isEmpty,
            """
            文档里有 \(defects.count) 处表格结构缺陷（最多列 10 条）：
            \(defects.prefix(10).joined(separator: "\n"))
            这些内容在**渲染视图里看不见**（多余单元格被丢 / 续行把表撕开），
            而源文件读起来一切正常 —— 「写了」不等于「生效了」。
            """)
    }

    /// ⚠️ **判据自己也要验**：拿「该报的」与「不该报的」各试一次。
    /// 少了这一步，「全绿」与「装置瞎了」是分不开的（本仓库 §8.96.4 的原话）。
    @Test func 表格判据的双向对照() {
        // 该报 ①：撕表（续行）
        let torn = [
            "| a | b |",
            "|---|---|",
            "| 1 | 2 |",
            "这一行不以 | 开头，是续行",
            "| 3 | 4 |",
        ].joined(separator: "\n")
        #expect(!Self.scan(torn).defects.isEmpty, "撕表的样本没被报出来 —— 判据在这一轴上是瞎的")

        // 该报 ②：多余单元格
        let extraCell = [
            "| a | b |",
            "|---|---|",
            "| 1 | 2 | 多出来的这一格会被渲染丢掉 |",
        ].joined(separator: "\n")
        #expect(!Self.scan(extraCell).defects.isEmpty, "多余单元格的样本没被报出来 —— 判据在这一轴上是瞎的")

        // 不该报：干净的表
        let clean = [
            "| a | b |",
            "|---|---|",
            "| 1 | 2 |",
            "| 3 | 4 |",
        ].joined(separator: "\n")
        #expect(Self.scan(clean).defects.isEmpty, "干净的样本被误报 —— 判据过严（会变成假红）")

        // 不该报：转义的 `\|` 不是分隔符（本仓库真的这么写）
        let escaped = [
            "| a | b |",
            "|---|---|",
            #"| 1 | `尚未\|还没` |"#,
        ].joined(separator: "\n")
        #expect(Self.scan(escaped).defects.isEmpty, "`\\|` 被当成了分隔符 —— 会报成片假红")

        // 不该报：围栏代码块里的 `|` 不是表格
        let fenced = [
            "```",
            "| 这不是表 | 真的不是 |",
            "```",
        ].joined(separator: "\n")
        #expect(Self.scan(fenced).blocks == 0, "围栏代码块被当成表格扫了")
    }
}
