import Foundation
import Testing

@testable import DiskEjectorApp

/// **「活文件」里写死的门槛数量会漂** —— 2026-09-20 实测（§8.108）。
///
/// 门槛从最初的两道（零警告构建 + `swift-format --strict`）一路加到 **5 道**
/// （中间陆续加了「注释承诺句」「脚本冒烟」「测试与覆盖率」），
/// 而三处**活文件**仍停在旧数字上：
///
/// | 文件 | 当时写的 | 实际 |
/// |---|---|---|
/// | `run.sh`（`check` 用法注释） | 「CI 的**两道**严格门槛」 | 5 道 |
/// | `build_app.sh`（`STRICT_CI` 说明，2 处） | 「CI 的**两道**严格门槛」 | 5 道 |
/// | `.github/workflows/ci.yml`（注释） | 「**三道**严格门槛」 | 5 道 |
///
/// 危害不是「数字难看」：**读的人据此低估了检查范围**。
/// `run.sh` 那行尤其糟 —— 它说 `check` 只做「构建 + 格式」，
/// 而「注释承诺句」那道**从头到尾没在任何注释里出现过**，
/// 于是「本地门槛会拦下什么」这件事只能靠读 `preflight.sh` 才知道。
///
/// ## 为什么单独守这一条，而不是「把数字改对」
///
/// 与 §8.104 同族：**同一个事实写在多处 ⇒ 一定会漂，而且会把错一起复制过去**。
/// 改数字只是把这一次改对；下一次加门槛，同样三处又会漂。
/// ⇒ 本守卫守的不是「数字对不对」，而是「**这里不许有写死的数字**」。
///
/// ## 扫描范围 = 「活文件」，而且是**机械枚举**出来的
///
/// 活文件 = **被 git 跟踪**、且满足下面任一条：
/// 1. 扩展名是 `yml` / `yaml`；
/// 2. **首行是 `#!`**（shebang）。
///
/// ⚠️ 第 2 条不是凑数：本仓库有**没有扩展名的可执行脚本**（`scripts/test/fake-gh/gh`），
/// 只按扩展名枚举会把它漏掉 —— 而「漏一个文件」与「那个文件干净」在输出上**逐字相同**
/// （§8.105 的原话）。`扫描范围必须覆盖全部活工具文件` 就是钉这件事的。
///
/// ⚠️ **`DESIGN-SPEC.md` / `2026-09-20.md` 这类文档不进范围**，不是因为「漏了」：
/// 它们写的是**当时的记录**（「三道门槛全绿」在写下那一刻是真的），
/// 改它们等于篡改历史。范围靠「是不是 shebang/YAML」机械切分，不靠手写排除表。
@Suite struct ToolingClaimTests {

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/ToolingClaimTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: 判据（纯函数 —— 样本可以直接喂给它，不必去改仓库里的文件）

    struct Claim: CustomStringConvertible {
        var line: Int
        var hit: String
        var description: String { "L\(line)：\(hit)" }
    }

    /// 「**数量 + 道门槛**」。数量可以是阿拉伯数字，也可以是中文数词
    /// （本仓库两种都真的写过：`3 道严格门槛` / `两道严格门槛`）。
    ///
    /// ⚠️ `\$\{GATE_NO\}` 这类**变量**不算写死 —— 它是从实际跑的轮数派生的，
    /// 正是我们想要的那种写法。判据里的数量类**不含**字母，所以 `N 道门槛`
    /// （文档里的占位符写法）也不会被误报。
    static let gateCountPattern = #"[0-9一二三四五六七八九十两]+[ \t]*道(?:严格)?门槛"#

    static func gateCountClaims(in text: String) -> [Claim] {
        guard let re = try? NSRegularExpression(pattern: gateCountPattern) else { return [] }
        var out: [Claim] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
                let r = Range(m.range, in: s)
            else { continue }
            out.append(Claim(line: i + 1, hit: String(s[r])))
        }
        return out
    }

    // MARK: 范围

    /// `git ls-files <patterns…>`（不传 patterns = 全部被跟踪文件）；拿不到输出返回 `nil`。
    ///
    /// ⚠️ **用 git，而不是自己遍历文件系统**：`.gitignore` 的规则**由 git 自己解释**，
    /// 自己写一份「跳过哪些目录」等于又添一份会漂的手写清单 —— 那正是本节要防的病（§8.105）。
    static func gitLsFiles(_ patterns: [String] = []) async -> [String]? {
        let output = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let run = SubprocessOutput(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", repoRoot.path, "-c", "core.quotePath=false", "ls-files"] + patterns,
                timeout: 15
            ) { c.resume(returning: $0) }
            run.start()
        }
        guard let output else { return nil }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// 文件首行；读不到返回 `nil`。只读 512 字节 —— 判断 shebang 用不着整个文件
    /// （仓库里有几百 KB 的 `DESIGN-SPEC.md`，逐个整读纯属浪费）。
    static func firstLine(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 512) else { return nil }
        return String(decoding: data, as: UTF8.self).prefix { $0 != "\n" }.description
    }

    /// 「活文件」清单：被 git 跟踪，且（扩展名是 `yml`/`yaml` **或** 首行是 `#!`）。
    static func liveToolingFiles() async -> [String]? {
        guard let all = await gitLsFiles() else { return nil }
        var live: [String] = []
        for rel in all {
            let url = repoRoot.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            if ["yml", "yaml"].contains(url.pathExtension) {
                live.append(rel)
                continue
            }
            if firstLine(of: url)?.hasPrefix("#!") == true {
                live.append(rel)
            }
        }
        return live
    }

    // MARK: 守卫

    @Test func 活文件里不得写死门槛数量() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「没有写死门槛数量」）")

        // 正向锚：文件数不能塌 —— 否则下面那句「没写死」只是「没扫到」（假绿）
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        var claims: [String] = []
        for rel in live {
            claims += Self.gateCountClaims(in: try read(rel)).map { "\(rel) \($0)" }
        }

        #expect(
            claims.isEmpty,
            """
            这些**活文件**里写死了门槛数量（\(claims.count) 处）：
            \(claims.joined(separator: "\n"))
            门槛会加，数字会漂 —— 2026-09-20 实测：门槛已加到 5 道，而 `run.sh` 仍写「两道」、
            `ci.yml` 仍写「三道」，读的人据此**低估了检查范围**。
            改法：别写数字，指向唯一实现（「过 CI 的门槛，见 `scripts/preflight.sh`」），
            或在注释里说明「要清单就跑 `./run.sh check`」——它逐道打印标题。
            """)
    }

    /// ⚠️ **判据自己也要验**：拿「该报的」与「不该报的」各试一次。
    /// 少了这一步，「全绿」与「正则根本没编译成功」是分不开的（§8.96.4 的原话）。
    @Test func 门槛数量判据的双向对照() {
        // 该报 ①：阿拉伯数字（`ci.yml` 真的这么写过）
        #expect(
            !Self.gateCountClaims(in: "# 3 道严格门槛：零警告构建…").isEmpty,
            "阿拉伯数字没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ②：中文数词（`run.sh` / `build_app.sh` 真的这么写过）
        #expect(
            !Self.gateCountClaims(in: "# 不启动，只过 CI 的两道严格门槛").isEmpty,
            "中文数词没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ③：不带「严格」二字（`ci_status.sh` 真的这么写过）
        #expect(
            !Self.gateCountClaims(in: "本地门槛每轮都报「4 道门槛全绿」").isEmpty,
            "「N 道门槛」没被报出来 —— 判据只认「严格门槛」这一种写法")

        // 不该报 ①：`${GATE_NO}` 是**从实际轮数派生**的，正是该用的写法
        #expect(
            Self.gateCountClaims(in: #"echo " ✅ ${GATE_NO} 道门槛全部通过""#).isEmpty,
            "把变量当成了写死的数字 —— 会变成假红，逼人关掉守卫")
        // 不该报 ②：只是提到「门槛」，没有数量
        #expect(
            Self.gateCountClaims(in: "本脚本是**全部门槛的唯一实现**").isEmpty,
            "没有数量也被报了 —— 判据太松")
        // 不该报 ③：`N` 是文档里的占位符，不是某个具体数字
        #expect(
            Self.gateCountClaims(in: "别在任何活文件里写死「N 道门槛」").isEmpty,
            "占位符 `N` 被当成了数字")
    }

    /// ⚠️ **范围本身是判据**（§8.75 / §8.105 / §8.106）。
    ///
    /// 上面那条守卫的结论是「活文件里没有写死门槛数量」——
    /// 而「**活文件**」这个词是**我定义**的。定义窄了，它就变成一句空话，
    /// 且输出与「真的没有」逐字相同。所以这里把定义本身也钉住：
    ///
    /// 1. 交叉自证：`git ls-files '*.sh' '*.yml' '*.yaml'` 的结果必须**全在**枚举结果里
    ///    （若 shebang 判定坏了、或只认 `.yml`，这里当场报出来）；
    /// 2. **无扩展名的脚本必须在范围里** —— 它正是「不能用扩展名当判据」的理由。
    @Test func 扫描范围必须覆盖全部活工具文件() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「范围没问题」）")
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        let byGlob = try #require(
            await Self.gitLsFiles(["*.sh", "*.yml", "*.yaml"]),
            "拿不到 `git ls-files '*.sh' '*.yml' '*.yaml'` 的输出 —— 交叉自证没跑起来")
        #expect(byGlob.count >= 8, "按扩展名只列出 \(byGlob.count) 个文件 —— 交叉自证自己失效了（假绿）")

        let missed = byGlob.filter { !live.contains($0) }
        #expect(
            missed.isEmpty,
            """
            这些文件**按扩展名该进范围**却没进：\(missed.joined(separator: "、"))
            范围窄了 ⇒ 上面那条守卫的「没写死」只是「没扫到」。
            """)

        #expect(
            live.contains("scripts/test/fake-gh/gh"),
            """
            无扩展名的 `scripts/test/fake-gh/gh` 没进范围 ——
            枚举退化成「只看扩展名」了。它是**可执行脚本**（首行 `#!`），
            正是「不能拿扩展名当判据」的理由。
            """)
    }
}
