import Foundation
import Testing

/// **本地门槛 = CI 门槛** —— 这条约定此前只在**文字里**承诺，没有任何机器检查。
///
/// 现在有四处写着它：
/// 1. `SPEC.md` §6.4：「本地门槛 `./run.sh check`，或直接 `./scripts/preflight.sh`；
///    **与 CI 调用同一文件**，判据不会分叉」
/// 2. `.github/workflows/ci.yml` line 57 调用 `./scripts/preflight.sh --with-tests`
/// 3. `ci.yml` line 52–55 的注释：本地跑的是同一个文件，「否则 13 条并发错误会潜伏三天」
/// 4. `run.sh` line 22：`check` 分支 `exec scripts/preflight.sh`
///
/// ⚠️ 但**四处都是人写的字** —— 谁改了其中一处，其余三处不会有任何报错，
/// 而后果正是注释里写的那个：本地一路绿灯、CI 判据其实更严（或更松），
/// 「本地绿」与「CI 绿」从此**不是同一件事**，且**界面上/日志上都看不出来**。
///
/// §8.51 立过：**「A 与 B 必须一致」的约定要配守卫，不能靠两边各写一句「记得同步」。**
/// 这一条就是那句话的落地 —— 把四处**互相钉住**，而不是再写第五句「记得同步」。
///
/// ## ⚠️ 本文件第一版是**纸老虎**（变异 6 条只红 1 条，§8.60 记了全过程）
///
/// 三条断言写完**全绿**，看着很好；变异才暴露出 3 条里 2 条没牙：
///
/// | 变异 | 第一版 | 病根 |
/// |---|---|---|
/// | CI 改调别的命令 | 🟢 绿 | **进程崩溃**（`range(at: 1)` 越界）被判红口径当成「绿」 |
/// | 删掉 `--with-tests` 分支 | 🟢 绿 | `contains("--with-tests")` —— 脚本的**用法注释里**也有这个串 |
/// | 文档改脚本名 | 🟢 绿 | `contains` —— 文档里有**第二处**写法不同的引用 |
///
/// ⇒ 三条改法：**① 解析改成全量集合，不取「第一个匹配」；② 参数分支查结构且剥注释；
/// ③ 文档侧查「引用集合必须唯一」，不是「至少有一处对」。**
/// 更根本的：**「断言全绿」不是证据，变异红才是。**
///
/// ### ⚠️ 收得过头也是假红：「唯一」是相对于**角色**，不是相对于整个文件
///
/// 第二版把「SPEC.md 里所有 `scripts/*.sh` 引用必须唯一」当断言 ⇒ 立刻红，
/// 报出 `build_icon.sh` / `coverage.sh` / `make_appcast.sh` —— 它们是**别的脚本**，
/// 从来没自称过「门槛」。⇒ 收集范围必须是「**自称门槛的那些行**」，不是「全文」。
/// 与 §8.59 那条正好互补：那边是「来源比想的多」（假绿），这边是「范围比该管的宽」（假红）。
struct GateParityTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/GateParityTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: 守卫

    /// `run.sh check` 转调的脚本，必须出现在 **CI 实际调用的脚本集合**里。
    ///
    /// ⚠️ 这里用**集合包含**而不是「两边各取第一个相匹配」——
    /// 第一版就是取「第一个匹配」：CI 里那处调用被改掉后，扫描器静默滑到
    /// 后面另一个 `.sh`（打包验证的 `build_app.sh`）上，比较仍然「有意义」但**比错了对象**。
    @Test func 本地门槛与CI门槛必须调用同一个脚本() throws {
        let scan = try load()

        // 负向锚：两边都得真读到脚本名（读不到 = 解析口径失效，不是「一致」）
        #expect(!scan.ciScripts.isEmpty, "ci.yml 的非注释行里找不到任何 `./xxx.sh` 调用 —— 解析口径失效（假绿）")
        #expect(scan.runScript != nil, "run.sh 里找不到 `exec $SCRIPT_DIR/xxx.sh` —— check 分支改写法了？")

        guard let run = scan.runScript else { return }
        #expect(
            scan.ciScripts.contains(run),
            """
            CI 实际调用的脚本 **\(scan.ciScripts.sorted())** 里，没有本地门槛用的 `\(run)`。
            本地跑的与 CI 跑的从此不是同一个文件 —— 判据可以分叉，
            而两边都不会报错（本仓库曾因此让 13 条并发错误在本地绿灯下潜伏三天）。
            要改就**两边一起改**，或者让其中一个继续转调到另一个。
            """)
    }

    /// CI **不许绕过门槛脚本**直接跑测试 / 格式 —— 那等于门槛被架空。
    ///
    /// ⚠️ 第一版这条**会崩**：`range(at: 1)` 取捕获组，而 `swift test` 这条正则
    /// 根本没有捕获组 ⇒ `NSInvalidArgumentException` ⇒ 进程 SIGABRT。
    /// 危害不在崩本身，而在**崩被判红口径当成「绿」**（见文件头表格第一行）。
    @Test func CI不许绕过门槛脚本直接跑测试或格式() throws {
        let scan = try load()
        #expect(
            scan.bypass.isEmpty,
            """
            ci.yml 直接跑了门槛命令，绕过了 `\(scan.runScript ?? "门槛脚本")`：
            \(scan.bypass.joined(separator: " / "))
            一旦 CI 与本地各跑各的，判据就会分叉 ——
            而「本地绿」与「CI 绿」从此**不是同一件事**，谁都不会报错。
            """)
    }

    /// 门槛脚本必须**真的**解析 `--with-tests` —— 否则「两边都调 preflight.sh」
    /// 也可能只是「两边都调了一个不跑测试的壳」。
    ///
    /// ⚠️ 第一版用 `contains("--with-tests")` ⇒ 脚本顶部的**用法注释**里也有这个串，
    /// 把参数分支整行删掉仍然绿（假阴性）。现在查的是**结构**：非注释行里的 case 分派。
    @Test func 门槛脚本必须真的解析withTests参数() throws {
        let scan = try load()
        guard let run = scan.runScript else { return }
        let script = try read(run)
        let body = Self.stripComments(script)
        let dispatched = body.contains("--with-tests)") && body.contains("WITH_TESTS=1")

        #expect(
            dispatched,
            """
            `\(run)` 的非注释正文里找不到 `--with-tests` 的参数分派。
            只查「文件里有这个串」不够 —— 它的用法注释里也写着这个串，
            **注释会假扮成实现**（与 §8.50.3「注释会蒙过『方法体里有这句调用』」同族）。
            """)
    }

    /// 文档（SPEC.md §6.4）承诺的门槛命令必须与实际**同一个文件**，且**只能有一个说法**。
    ///
    /// ⚠️ 第一版用 `contains` ⇒ 文档里有**第二处**写法不同的引用（`scripts/preflight.sh`
    /// 不带 `./`），改掉第一处仍绿。现在查「引用集合**必须唯一**且等于实际脚本」。
    ///
    /// ⚠️ 收集范围只限**自称门槛的行**：全文扫会捞到 `build_icon.sh` / `coverage.sh` 等
    /// 别的脚本（它们没自称门槛），那是假红 —— 见文件头「唯一是相对于角色」。
    @Test func 文档承诺的门槛命令必须与实际一致() throws {
        let scan = try load()
        guard let run = scan.runScript else { return }
        let spec = try read("SPEC.md")

        // 「自称门槛」的行：§6.4 表格里的「本地门槛」行，以及 CI 那行的「代码门槛」。
        var refs = Set<String>()
        var claimLines: [String] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard Self.gateClaimKeywords.contains(where: { s.contains($0) }) else { continue }
            claimLines.append(s)
            for m in Self.allMatches(in: s, pattern: #"[A-Za-z0-9_./-]*scripts/[A-Za-z0-9_]+\.sh"#) {
                refs.insert(Self.normalize(m))
            }
        }

        // 负向锚：找不到承诺行 / 承诺行里没有脚本引用 = 口径失效，不是「没有不一致」
        #expect(
            !claimLines.isEmpty,
            "SPEC.md 里找不到自称「门槛」的行 —— §6.4 那句承诺被删了，或关键词失效（假绿）")
        #expect(
            !refs.isEmpty,
            "自称门槛的那些行里没有 `scripts/xxx.sh` 引用 —— 只写「与 CI 同一文件」却不写是哪个文件（假绿）")

        #expect(
            refs == [run],
            """
            文档自称门槛的地方写的是 \(refs.sorted())，实际门槛脚本是 \(Set([run]))。
            §6.4 写着「与 CI 调用同一文件，判据不会分叉」—— 对不上的那个说法会让读者
            按文档跑一遍，跑的却不是 CI 那个判据。改了脚本位置就把文档**所有**说法一起改。
            """)
    }

    /// 「自称门槛」的标志词。目录树那行（`preflight.sh # CI 严格门槛预检…`）不含这些词，
    /// 因此不进收集范围 —— 它没在**承诺**什么，只是列目录。
    private static let gateClaimKeywords = ["本地门槛", "代码门槛", "同一文件"]

    // MARK: 扫描

    private struct Scan {
        var ciScripts: Set<String> = []  // ci.yml 非注释行里调用的脚本（已归一化）
        var runScript: String?  // run.sh check 分支 exec 的脚本
        var bypass: [String] = []  // ci.yml 里直接跑的门槛命令
    }

    private func load() throws -> Scan {
        let ciRaw = try read(".github/workflows/ci.yml")
        // 注释行不算「跑了命令」—— ci.yml 里大量中文注释会提到这些命令名（假红来源）。
        let ciBody = Self.stripComments(ciRaw)

        var scan = Scan()
        for m in Self.allMatches(in: ciBody, pattern: #"\./([A-Za-z0-9_./-]+\.sh)"#) {
            scan.ciScripts.insert(Self.normalize(m))
        }
        for p in ["swift test", #"swift-format\s+lint"#, #"swift-format\s+format"#] {
            scan.bypass.append(contentsOf: Self.allMatches(in: ciBody, pattern: p))
        }

        let runRaw = try read("run.sh")
        // `exec "$SCRIPT_DIR/scripts/preflight.sh" "$@"` —— 整个仓库只有这一处这种写法。
        let hits = Self.allMatches(
            in: runRaw, pattern: #"exec\s+"\$SCRIPT_DIR/([A-Za-z0-9_./-]+\.sh)""#)
        scan.runScript = hits.first.map(Self.normalize)
        return scan
    }

    // MARK: 工具

    /// 剥掉**整行**注释（`#` 开头，含缩进）。
    ///
    /// ⚠️ 不剥行内尾注：shell 里 `#` 未必是注释（`$#`／`${x#y}`），
    /// 粗剥会把真代码削掉 ⇒ 假阴性。本仓库这几处都是整行注释，够用。
    private static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// 路径归一化：`./scripts/preflight.sh` 与 `scripts/preflight.sh` 是同一个文件。
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        return p
    }

    /// ⚠️ 取**整个匹配**（range 0），不用捕获组 ——
    /// 调用方极易写出「没有捕获组的正则」，`range(at: 1)` 会直接抛异常把测试进程带崩。
    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            // 有捕获组就用它（好读），没有就退回整个匹配（不崩）。
            let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range(at: 0)
            return Range(r, in: text).map { String(text[$0]) }
        }
    }
}
