import Foundation
import Testing

/// 扫 `Tests/` 里「**主 actor 上的同步阻塞**」。
///
/// **为什么需要这一条守卫**（§8.97.3 / §8.99）：
///
/// `Tests/` 里 31 个文件整体标着 `@MainActor`（`enrich` / `icon` / 离屏渲染都只能主 actor），
/// 而主 actor 只有一条。只要有人在它上面**同步阻塞**（`usleep` / `waitUntilExit` …），
/// **其余所有 `@MainActor` 用例都排不上队** —— 症状是**偶发假红**：
/// 2026-09-17 CI 上实测过一次（`磁盘列表一变就重测占用` 失败：`arrived` 为 false），
/// 2026-09-20 / 09-21 又红两次（`polls: 2` / `elapsed: 41.7s`，见 §8.113.9 / §8.113.20）。
///
/// ⚠️ **2026-09-22 起那条等待换成了「等事件」**（`OccupancyStoreTests.waitForNextRound`）——
/// 它不再轮询，所以「排不上队」不会再把它报成失败。但本守卫**仍然要守**：
/// 排不上队的是**别人**（§8.114 量到主 actor 上一串重活，~215 条轻测试排在后面），
/// 而且**同步阻塞占的是整条主 actor 串行资源**，与「谁在等」无关。
///
/// ## ⚠️ 口径（必须写明：§8.96 的教训是「静态扫描器的错多半是口径错」）
///
/// 1. **文件级**：文件里（去注释后）有**任何一行** trim 后等于 `@MainActor` ⇒ 该文件默认在主 actor 上。
///    不分缩进 —— 缩进的 `@MainActor` 是「单个测试主 actor」，同样是主 actor 作用域。
/// 2. **豁免**：若某个阻塞调用**所在的最近一个 `func` / `init` 声明行**同时含
///    `nonisolated` **和** `async` ⇒ 不算违规。那个函数被 `await` 时跑在**协作线程池**上。
///    ⚠️ **两个关键词缺一不可**：`nonisolated` 但**同步**的函数仍然在**调用者的线程**上执行
///    —— 从主 actor 调它就是占住主 actor。这是本条口径最反直觉、也最容易漏的一点。
/// 3. 命中即违规：否则文件里出现任何**同步阻塞调用**（见 `blockingPattern`）都算。
///
/// **已知局限（故意不修）**：第 2 条只「向上找最近的 `func` / `init` 行」，不做括号配平 ⇒
/// 嵌套闭包里的 `nonisolated` 认不出来（会误报）。当前实测 0 例。
///
/// **为什么是「源码守卫」而不是运行时探针**：要测的是「主 actor 会不会被占住」，
/// 而这在任何单个测试内部都观测不到 —— 占住它的是**别的**测试。静态扫是唯一能覆盖全量的手段；
/// 代价是它可能过时，所以下面配了**双向阳性对照**。
struct MainActorBlockingTests {

    // MARK: - 扫描器（纯函数，便于用合成样本做对照）

    /// 同步阻塞调用 —— **都不让路**。与 `await Task.sleep` / `Task.yield()` 相对。
    ///
    /// ⚠️ 用正则而不是 `contains`：`usleep(` 里含 `sleep(`，子串匹配会把口径搅乱，
    /// 而「口径错一次」的后果是整张表都不可信。两处细节各挡一个坑：
    ///
    /// - `(?<![A-Za-z0-9_])` 挡住 `foo_sleep(` 这类标识符；
    /// - `(?<!Task\.)` 把 **`Task.sleep(` 放过去** —— 它是 `async`、**让路**的正确写法，
    ///   与 `Thread.sleep(` 只差一个前缀。第一版没有这个排除项，是被下面那条阴性对照抓出来的。
    ///
    /// ## ⚠️ 第三类：**同步等外部服务**（2026-09-22 新增，§8.127）
    ///
    /// `\.tiffRepresentation` 是**惰性光栅化**：它不「等一个进程」，但会**同步**去
    /// `iconservicesagent` 取像素。实测（本机）对一张**刚登记**的 bundle 图标要 **3.93s**，
    /// 而同一张图标的通用版只要 0.39s —— 也就是说它**既慢又不让路**，
    /// 危害与 `waitUntilExit()` 同类：3.9s 里**所有** `@MainActor` 用例排不上队。
    ///
    /// 判别实验：`--skip` 掉那条取图标的测试后，`ProcessAppResolverTests` +
    /// `OccupancyStoreTests` 的其余 **27** 条从 ~4.8s 全部掉到 **≤0.71s**。
    ///
    /// ⚠️ **这是一份「已知实例」清单，不是完备清单** —— 同族的还有别的惰性 AppKit 读取。
    /// 口径宁可窄：只收**实测过**、且**全仓只此一处**的名字（`grep` 过，
    /// `tiffRepresentation` 只在 `ProcessAppResolverTests` 出现）。
    /// 离屏渲染那几条（`NSBitmapImageRep` / `representation(using:)`）**故意不收**：
    /// 它们本来就**必须**在主 actor 上做（AppKit 渲染），收进来只会把守卫变成噪音。
    private static let blockingPattern =
        #"(?<!Task\.)(?<![A-Za-z0-9_])(?:usleep|sleep)\(|waitUntilExit\(\)|\.wait\(\)|\.tiffRepresentation"#

    /// 找出源码里所有同步阻塞调用，返回**命中的原文**（失败信息里直接展示，不用再猜）。
    static func blockingCalls(in code: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: blockingPattern) else { return [] }
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// 这个文件整体是不是在主 actor 上（口径第 1 条）。
    static func isMainActorFile(_ code: String) -> Bool {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "@MainActor" }
    }

    /// 去掉**整行**注释（行首空白后以 `//` 开头）—— 与 `DeclarationConsumerTests` 同一口径。
    ///
    /// ⚠️ **必须先剥注释**：本守卫的说明里就写着 `usleep` / `waitUntilExit`，
    /// 不剥的话**注释会把自己判成违规**（「文档越全、越容易误报」的经典形状）。
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 从 `index` 往上找**最近的** `func` / `init` 声明行（**含本行**），判断它是否
    /// `nonisolated` **且** `async`（口径第 2 条：只有这两个词同时出现，该函数才真的跑在协作线程池上）。
    ///
    /// ⚠️ 找的是 `func` / `init` 而**不是** `let` / `var`：函数体里的 `let task = Process()`
    /// 也在阻塞行上方，但它不是**包围**阻塞的那个作用域。找 `func` / `init` 能自然跳过它。
    static func enclosingDeclarationIsNonisolatedAndAsync(lines: [String], upTo index: Int) -> Bool {
        for line in lines[...index].reversed() {
            if line.contains("func ") || line.contains("init(") {
                return line.contains("nonisolated") && line.contains("async")
            }
        }
        return false
    }

    /// 一个文件里**真正算违规**的阻塞调用（已套用口径第 2 条的豁免）。
    static func violations(inFile code: String) -> [String] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard isMainActorFile(code) else { return [] }
        var hits: [String] = []
        for (index, line) in lines.enumerated() {
            let found = blockingCalls(in: line)
            guard !found.isEmpty else { continue }
            if enclosingDeclarationIsNonisolatedAndAsync(lines: lines, upTo: index) { continue }
            hits.append(contentsOf: found)
        }
        return hits
    }

    // MARK: - 守卫

    @Test("主 actor 上的测试代码里不许有同步阻塞")
    func 主actor上的测试代码里不许有同步阻塞() throws {
        // ① 装置自证：**双向**阳性对照（§8.96.4）。
        //    只报「没找到」的装置与「瞎了」的装置，输出**逐字相同** —— 必须先证明它有牙。
        #expect(
            Self.blockingCalls(in: Self.codeOnly("let x = 1\nusleep(50_000)")) == ["usleep("],
            "阳性对照：`usleep(` 必须被抓到。抓不到 ⇒ 装置瞎了，下面的「0 违规」不可信")
        #expect(
            Self.blockingCalls(in: Self.codeOnly("try task.waitUntilExit()")) == ["waitUntilExit()"],
            "阳性对照：`waitUntilExit()` 必须被抓到")
        #expect(
            Self.blockingCalls(in: Self.codeOnly("Thread.sleep(1)")) == ["sleep("],
            "阳性对照：`Thread.sleep(` 是**同步阻塞**，必须被抓到（它与 `Task.sleep` 只差一个前缀）")
        #expect(
            Self.blockingCalls(in: Self.codeOnly("let d = icon.tiffRepresentation"))
                == [".tiffRepresentation"],
            "阳性对照：`tiffRepresentation` 是**同步等 iconservicesagent** 的惰性光栅化（实测冷启动 3.93s），必须被抓到")
        #expect(
            Self.blockingCalls(in: Self.codeOnly("try? await Task.sleep(nanoseconds: 10_000_000)"))
                .isEmpty,
            "阴性对照：`await Task.sleep` 是**让路**的，不许被抓 —— 抓了就会把正确写法逼成违规")

        #expect(
            Self.isMainActorFile(Self.codeOnly("@MainActor\nstruct X {}")),
            "阳性对照：文件级 `@MainActor` 必须被认出来")
        #expect(
            Self.isMainActorFile(Self.codeOnly("    @MainActor\n    func f() {}")),
            "阳性对照：**缩进**的 `@MainActor`（单个测试主 actor）也必须被认出来")
        #expect(
            !Self.isMainActorFile(Self.codeOnly("// @MainActor\nstruct X {}")),
            "阴性对照：注释里的 `@MainActor` 不算 —— 否则文档里提一句就会误报")

        // ② 口径第 2 条（`nonisolated` 豁免）的对照。**这条最容易搞错**，两个方向都要钉。
        #expect(
            Self.violations(inFile: Self.codeOnly("@MainActor\nstruct X {\n    nonisolated func f() { usleep(1) }\n}"))
                == ["usleep("],
            "阳性对照：`nonisolated` 但**同步**的函数仍跑在**调用者线程**上 —— 从主 actor 调它就占主 actor，必须报")
        #expect(
            Self.violations(
                inFile: Self.codeOnly("@MainActor\nstruct X {\n    nonisolated func f() async { usleep(1) }\n}")
            )
            .isEmpty,
            "阴性对照：`nonisolated` **且** `async` 的函数跑在协作线程池上，不许报 —— 报了就把唯一的修法堵死了")
        // ⚠️ 这条是给**第三类**（同步等外部服务）配的阴性对照：光栅化搬进
        // `nonisolated async` 之后必须放行 —— 否则修法会被守卫堵死（同上面那条的道理）。
        #expect(
            Self.violations(
                inFile: Self.codeOnly(
                    "@MainActor\nstruct X {\n    nonisolated func f() async { await g { img.tiffRepresentation } }\n}"
                )
            )
            .isEmpty,
            "阴性对照：光栅化搬进 `nonisolated async`（并转发到独立执行体）之后不许再报")

        // ③ 真扫 `Tests/` 全部 `.swift`。
        let testsRoot =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DiskEjectorAppTests/
            .deletingLastPathComponent()  // Tests/
        guard let walker = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(testsRoot.path)")
            return
        }

        // ⚠️ **跳过本文件**：下面 `blockingPattern` 那个字符串里就写着 `usleep(`，
        // 不跳过的话守卫会**自己把自己判红**。
        let selfName = URL(fileURLWithPath: #filePath).lastPathComponent
        var scanned = 0
        var mainActorFiles = 0
        var violations: [String] = []

        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != selfName else { continue }
            scanned += 1

            let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            if Self.isMainActorFile(code) { mainActorFiles += 1 }
            let hits = Self.violations(inFile: code)
            if !hits.isEmpty {
                violations.append("\(name)：\(hits.joined(separator: "、"))")
            }
        }

        // ④ 装置自证：真的扫到了足够多的文件、也真的认出了足够多的主 actor 文件。
        //    否则「0 违规」可能只是「一个都没扫」或「一个都没认出来」——
        //    这三种情况在断言层面**完全一样**。
        #expect(
            scanned > 40,
            "只扫到 \(scanned) 个文件 —— 枚举很可能没生效，这次的「0 违规」不可信")
        #expect(
            mainActorFiles > 10,
            "只认出 \(mainActorFiles) 个主 actor 文件 —— 判据很可能失效了（实测 31 个），结果不可信")

        #expect(
            violations.isEmpty,
            """
            这些**主 actor 上的**测试代码里有同步阻塞调用：\(violations.joined(separator: "；"))。
            同步阻塞不让路 ⇒ 其余 `@MainActor` 用例全排不上队 ⇒ 偶发假红（§8.97.3 / §8.113.20）。
            三种修法（§8.99）：① 把等待改成 `await`（`Task.sleep`）；
            ② 把阻塞段挪进 `nonisolated` **且 `async`** 的函数（只有 async 才真的离开主 actor）；
            ③ 把整个套件的 `@MainActor` 摘掉 —— **前提**是套件里没有必须主 actor 的同步调用
            （先逐处确认隔离，再摘；`ProcessAppResolverTests` 就摘不掉，因为 `enrich` / `icon` 必须主 actor）。
            ⚠️ 命中的若是 `tiffRepresentation`（第三类：**同步等外部服务**），①②③ 都**不够**：
            它必须转发到**独立执行体**（`DispatchQueue.global`）上做 —— 搬进 `nonisolated async`
            只是把被占住的对象从主 actor 换成协作池的一根线程（池大小 ≈ 核数，§8.114 第 6 节）。
            现成写法见 `ProcessAppResolverTests.tiffDataOffMainActor(_:)`（§8.127）。
            """)
    }

    // MARK: - 协作池上的阻塞（§8.114 第 6 节留下的那半）

    /// 同步等子进程的调用。**只有 `waitUntilExit()`** —— 口径见下面那条守卫的说明。
    private static let processWaitPattern = #"waitUntilExit\(\)"#

    /// 找出源码里所有「同步等子进程」的调用，返回**命中的原文**（失败信息里直接展示）。
    static func processWaits(in code: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: processWaitPattern) else { return [] }
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// 测试代码里**不许同步等子进程**（`waitUntilExit()`）。
    ///
    /// ## 为什么在「主 actor 守卫」之外还要这一条（2026-09-22）
    ///
    /// 上面那条守卫的口径第 2 条把「挪进 `nonisolated` **且** `async` 的函数」当成**豁免**，
    /// 并在失败信息里把它列为**推荐修法 ②**。§8.99 就是照它改的
    /// （`ProcessAppResolverTests.adhocSign` 摘到协作池上）。
    ///
    /// ⚠️ **但「搬到协作池」不是解决，只是把被占住的对象换了一个**：`waitUntilExit()`
    /// 仍然**同步阻塞、不让路**，它占住的是**协作线程池**里的一根线程 ——
    /// 而池大小 ≈ **核数**。CI runner 的核数比开发机少，几处并发阻塞就能让整个进程停摆：
    /// §8.114 第 6 节量到整轮出现 **4.5s 零完成窗口**，并写下
    /// 「修法 ② 被当成了终点，而它不是」。
    ///
    /// 症状是**别的**测试等不到东西：`ProcessAppResolverTests.waitForExecutablePath`
    /// （`nonisolated async` ⇒ 跑在协作池上）在 CI 上等 2 秒等不到 `proc_pidpath`
    /// ⇒ 报成「进程还没就绪」，而真因是**池里没有空线程给它**。
    ///
    /// ## 修法
    ///
    /// `runAndAwaitExit(_:)`（`Process.terminationHandler` + `withCheckedContinuation`）：
    /// 等的是**回调**，不是线程 —— 一个线程都不占。
    ///
    /// ## 口径（为什么只抓 `waitUntilExit()`）
    ///
    /// - **全量**扫 `Tests/`，**不看**文件有没有 `@MainActor`：协作池是全局串行资源，
    ///   在哪个文件里阻塞都一样 —— 这正是它比上面那条守卫**更宽**的地方。
    /// - ⚠️ **不抓 `usleep(` / `Thread.sleep(`**：它们是**定时**阻塞（时长由代码写死、通常极短），
    ///   危害与「等一个外部进程（CI 上 `codesign` / `hdiutil` 各几秒，且时长不可控）」
    ///   不是一个量级；而上面那条守卫已经在主 actor 上把它们挡住了。
    ///   口径窄一点，才不会因为「写了个 1ms 的 sleep」把守卫逼成噪音。
    @Test("测试代码里不许同步等子进程（协作池也会被占）")
    func 测试代码里不许同步等子进程() throws {
        // ① 装置自证：双向阳性对照（§8.96.4）。
        //    只报「没找到」的装置与「瞎了」的装置，输出**逐字相同**。
        #expect(
            Self.processWaits(in: Self.codeOnly("try task.waitUntilExit()")) == ["waitUntilExit()"],
            "阳性对照：`waitUntilExit()` 必须被抓到。抓不到 ⇒ 装置瞎了，下面的「0 处」不可信")
        #expect(
            Self.processWaits(in: Self.codeOnly("let status = await runAndAwaitExit(task)")).isEmpty,
            "阴性对照：`runAndAwaitExit`（`terminationHandler` 那条路）不许被抓 —— 它就是修法本身")
        #expect(
            Self.processWaits(in: Self.codeOnly("try? await Task.sleep(nanoseconds: 1)")).isEmpty,
            "阴性对照：`Task.sleep` 是让路的，不许被抓")

        // ② 真扫 `Tests/` 全部 `.swift`。
        let testsRoot =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DiskEjectorAppTests/
            .deletingLastPathComponent()  // Tests/
        guard let walker = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(testsRoot.path)")
            return
        }

        // ⚠️ **跳过本文件**：`processWaitPattern` 那个字符串里就写着 `waitUntilExit()`，
        // 不跳过的话守卫会**自己把自己判红**（同上面那条守卫的同一处坑）。
        let selfName = URL(fileURLWithPath: #filePath).lastPathComponent
        var scanned = 0
        var hits: [String] = []

        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != selfName else { continue }
            scanned += 1
            let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
            let found = Self.processWaits(in: code)
            if !found.isEmpty { hits.append("\(name)：\(found.joined(separator: "、"))") }
        }

        // ③ 装置自证：真的扫到了足够多的文件。否则「0 处」可能只是「一个都没扫」——
        //    这两种情况在断言层面**完全一样**。
        #expect(
            scanned > 40,
            "只扫到 \(scanned) 个文件 —— 枚举很可能没生效，这次的「0 处」不可信")

        #expect(
            hits.isEmpty,
            """
            这些测试代码在**同步等子进程**：\(hits.joined(separator: "；"))。
            `waitUntilExit()` 不让路 ⇒ 占住**协作线程池**里的一根线程（池大小 ≈ 核数）⇒
            CI 上核数更少，几处并发阻塞就让整个进程停摆（§8.114 第 6 节量到 4.5s 零完成窗口）。
            修法：用 `runAndAwaitExit(_:)` —— 它等的是**回调**（`terminationHandler`），
            一个线程都不占。
            """)
    }
}
