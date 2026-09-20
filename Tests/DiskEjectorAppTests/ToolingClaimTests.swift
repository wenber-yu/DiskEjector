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

    // MARK: 第二轴：bash 3.2 在 UTF-8 locale 下会连坐变量名

    /// ⚠️ **`$变量` 紧跟全角标点时，bash 3.2 会把那个字符算进变量名**（实测，本轮 CI 红）。
    ///
    /// ```
    /// $ LC_ALL=en_US.UTF-8 bash -c 'set -u; f(){ local n="$1"; echo "✘ $n：x"; }; f abc'
    /// bash: n?: unbound variable        ← 变量名被解析成 `n` + 全角冒号
    /// $ LC_ALL=C       …同上…             ✘ abc：x        ← 换 C locale 就没事
    /// $ LC_ALL=en_US.UTF-8 bash -c '… echo "✘ ${n}：x" …'  ✘ abc：x        ← 加花括号即可
    /// ```
    ///
    /// 病根：bash 3.2 用 `isalnum(字节)` 判断变量名字符，而在**多字节 locale** 下
    /// 它对高位字节返回真 ⇒ `$n` 后面的全角冒号 / 全角括号 / 全角逗号 / 中文，
    /// 全都被当成变量名的一部分。
    ///
    /// **它为什么躲过了本地门槛**：本机环境**没有** `LANG` / `LC_*`（locale 是 C），
    /// 而 CI runner 设了 `LC_ALL: en_US.UTF-8` ⇒ **本地全绿、CI 红**。
    /// 2026-09-20 实测：门槛 4（脚本冒烟）在 CI 上报
    /// `ci_status_smoke.sh: line 65: name: unbound variable`，本地一次都没红过。
    ///
    /// ⚠️ 比「红」更糟的是**不红**：脚本若没开 `set -u`，bash 会把它当成
    /// **另一个不存在的变量**静默展开成空 —— 输出少几个字，不报错。
    /// 本仓库 `scripts/ci_status.sh` 那几处正是这样（`set -u` 下才会红，
    /// 而它只在**开发者本机**跑，本机 locale 是 C ⇒ 一直没暴露）。
    static func unbracedVarBeforeMultibyte(in text: String) -> [Claim] {
        guard let re = try? NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#) else { return [] }
        var out: [Claim] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let s = String(line)
            for m in re.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) {
                // `${name}` 不受影响（`$` 后面是 `{`，根本进不了这个正则）
                guard let nameR = Range(m.range(at: 1), in: s) else { continue }
                // 取变量名后面**那一个字符**（Swift 的 Character ⇒ 能正确处理非 BMP）
                guard let next = s[nameR.upperBound...].first,
                    !next.unicodeScalars.allSatisfy({ $0.isASCII })
                else { continue }
                out.append(Claim(line: i + 1, hit: "$\(s[nameR]) 紧跟 \(next)"))
            }
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

    /// bash 3.2 那条：**活文件里的 `$变量` 后面不许紧跟多字节字符**（改 `${变量}` 即可）。
    ///
    /// ⚠️ 这条**必须静态扫**，不能靠「跑一遍」：脚本只在**特定 locale** 下才炸，
    /// 而本机 locale 是 C ⇒ 跑一遍永远是绿的。2026-09-20 的 CI 红就是这么漏出来的。
    @Test func 活文件里变量引用不得紧跟多字节字符() async throws {
        let listed = await Self.liveToolingFiles()
        let live = try #require(
            listed, "拿不到 `git ls-files` 的输出 —— 装置没跑起来（**不等于**「没有这个坑」）")
        #expect(live.count >= 12, "只枚举到 \(live.count) 个活文件 —— 范围口径失效了（假绿）")

        var claims: [String] = []
        for rel in live {
            claims += Self.unbracedVarBeforeMultibyte(in: try read(rel)).map { "\(rel) \($0)" }
        }

        #expect(
            claims.isEmpty,
            """
            这些**活文件**里 `$变量` 紧跟了多字节字符（\(claims.count) 处）：
            \(claims.joined(separator: "\n"))
            bash 3.2 在 **UTF-8 locale** 下会把那个字符算进**变量名**
            ⇒ `set -u` 时报 `unbound variable`，不开 `set -u` 则**静默展开成空**。
            本机 locale 是 C 所以**永远不红**，CI 设了 `LC_ALL=en_US.UTF-8` 就炸
            （2026-09-20 实测：门槛 4 在 CI 报 `name: unbound variable`，本地一次没红）。
            改法：写成 `${变量}`。
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

    /// 第二轴的双向对照。少了它，「正则没编译成功」与「真的干净」分不开。
    @Test func 变量引用判据的双向对照() {
        // 该报 ①：全角冒号（本轮 CI 红的那一行就长这样）
        #expect(
            !Self.unbracedVarBeforeMultibyte(in: #"echo "✘ $name：期望退出码""#).isEmpty,
            "全角冒号没被报出来 —— 判据在这一轴上是瞎的")
        // 该报 ②：全角括号
        #expect(
            !Self.unbracedVarBeforeMultibyte(in: #"echo "（$status）""#).isEmpty,
            "全角括号没被报出来")
        // 该报 ③：直接跟中文（同样会被算进变量名）
        #expect(
            !Self.unbracedVarBeforeMultibyte(in: #"echo "共 $count处""#).isEmpty,
            "变量名紧跟中文没被报出来")

        // 不该报 ①：加了花括号 —— 这正是修法
        #expect(
            Self.unbracedVarBeforeMultibyte(in: #"echo "✘ ${name}：期望退出码""#).isEmpty,
            "`${name}` 被误报 —— 会把正确的写法判成错")
        // 不该报 ②：半角标点没问题
        #expect(
            Self.unbracedVarBeforeMultibyte(in: #"echo "✘ $name: done""#).isEmpty,
            "半角标点被误报 —— 判据太松")
        // 不该报 ③：`$1` 这类位置参数（首字符不是字母/下划线）
        #expect(
            Self.unbracedVarBeforeMultibyte(in: #"echo "$1，不是变量""#).isEmpty,
            "位置参数 `$1` 被误报")
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
