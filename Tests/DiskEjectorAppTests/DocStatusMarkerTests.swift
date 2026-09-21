import Foundation
import Testing

/// 「仍开着」表的**状态标记不得自相矛盾**（2026-09-21，§8.113.13）
///
/// 【它解决什么】
/// 「表自己也会漂」在本项目已经发生**三次**（§8.104、§8.113.6 那次、2026-09-21 的
/// 第 32 / 35 行）：一件事做完了、没回来划账 ⇒ 那一行的**状态列**还写着
/// `⬜ 仍开着`，而**描述列**里明明已经写了 🟢（已关闭 / 拿到结论）。
/// ⇒ 只看「清单里有它」会以为还开着；只看描述列又会以为已经划过账。
/// 两种读法都成立，而**没有任何东西会红** —— 正是本守卫要堵的洞。
///
/// 【判据】一行里不得同时出现「仍开着」标记 `⬜ **仍开着**` 与「整项关闭」标记 `🟢`。
///
/// 【⚠️ 为什么只认 `🟢`、不认 `✅` —— 精度】
/// `✅` 在本文件里大量用于**子项**（「① ✅ 已进守卫；② ⬜ 深色值仍缺」是**合法的部分关闭**）。
/// 用 git 里划账前那一版实测过：带上 `✅` 的宽判据命中 **2 行**，其中第 35 行是**误报**
/// —— 它那个 `✅ 已关闭` 在 4.3 订正里被**撤销**了，那一行当时**确实还开着**。
/// ⇒ 只认 `🟢`（本文件里 `🟢` = 整项拿到结论）。**precision 100% / recall 偏低**，这个交换值：
/// 喊狼来了的守卫一定会被关掉（§8.88.3 那条教训）。
///
/// 【⚠️ 它抓不到什么 —— 别把「绿了」读成「表不会漂」】
/// 只抓「同一行里两种标记打架」这一种：
/// - 「描述列写了结论、状态列压根没写『仍开着』」的行 ⇒ **看不见**；
/// - 「状态列是 `⬜ 仍开着`、描述列里用 `✅` 写了结论」⇒ **故意不报**（见上）。
/// 这两类仍要靠**人回头核对**（判据里那条：核对时每行都要对一遍现状）。
@Suite struct DocStatusMarkerTests {

    struct Hit: CustomStringConvertible {
        var file: String
        var line: Int
        var description: String { "\(file) L\(line)" }
    }

    /// 纯函数：喂行数组，返回「自相矛盾」的行号（1 起）。
    ///
    /// 抽成纯函数是为了让**样本可以直接喂进来**（下面那条双向对照），
    /// 不必真的把仓库里的文档改坏再验（改坏了还要还原，还原本身又会出错）。
    static func drift(in lines: [String]) -> [Int] {
        var out: [Int] = []
        for (i, line) in lines.enumerated() {
            // ⚠️ **只管表格行**（`|` 开头）：2026-09-21 实测 —— 不限定的话，
            // §8.113.13 里**讨论这两个标记**的散文行会把自己报成漂移
            // （那一节正是拿它们当例子写的）。散文里同时提到两种标记是**正常的**。
            guard line.hasPrefix("|") else { continue }
            if line.contains("⬜ **仍开着**") && line.contains("🟢") {
                out.append(i + 1)
            }
        }
        return out
    }

    /// 仓库根：`#filePath` = <仓库根>/Tests/DiskEjectorAppTests/DocStatusMarkerTests.swift
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func 标着仍开着却写着整项关闭的行必须被抓出来() async throws {
        // 扫描范围 = **被 git 跟踪的 `.md`**（复用 `DocTableIntegrityTests` 那份）。
        // ⚠️ **范围本身是判据**（§8.105）：自己手写一份清单 = 又添一份会漂的东西；
        // 这里复用同一份 ⇒ 「范围」在两个守卫之间**只有一个真相**。
        let files = try #require(
            await DocTableIntegrityTests.trackedMarkdownFiles(),
            "拿不到 `git ls-files '*.md'` 的输出 —— 扫描范围也拿不到了（范围本身就是判据）")
        #expect(!files.isEmpty, "被跟踪的 `.md` 一份都没有 —— 范围坏了")

        var hits: [Hit] = []
        for f in files {
            let url = Self.repoRoot.appendingPathComponent(f)
            // CI 上 `.workbuddy*/memory/*.md` 不存在（被 .gitignore 排除）⇒ 读不到就跳过，
            // 与 `DocTableIntegrityTests` 同源的口径一致。
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for lineNo in Self.drift(in: raw.components(separatedBy: "\n")) {
                hits.append(Hit(file: f, line: lineNo))
            }
        }

        #expect(
            hits.isEmpty,
            """
            这些行**状态列写着「仍开着」、同一行却出现了整项关闭标记 🟢** —— 表自己漂了：
            \(hits.map(\.description).joined(separator: "\n"))
            正确的处置是**把状态列划成已关闭**（写清核对时刻与依据章节），
            不是把那行里的 🟢 删掉 —— 删了就等于把「已经做完」这件事也一起删了。
            """)
    }

    @Test func 判据的双向对照() throws {
        // ① 阳性：真的打架 ⇒ 必须命中（否则装置瞎了，与「没有漂移」逐字相同）
        let bad = [
            "| 32 | … | ⬜ **仍开着**（§8.82 新开）。… 🟢 **已关闭（2026-09-21，§8.113.10）** … |"
        ]
        #expect(
            Self.drift(in: bad) == [1],
            "阳性对照失败：真的自相矛盾没被抓出来 ⇒ 这条守卫等于没有")

        // ② 阴性：合法的部分关闭（✅ 子项 + ⬜ 子项，状态列写「🟡 部分关闭」）⇒ 不得命中
        let partial = [
            "| 25 | … | ① ✅ 已进守卫；② ⬜ 深色值仍缺 | 🟡 **部分关闭** |"
        ]
        #expect(
            Self.drift(in: partial).isEmpty,
            "阴性对照失败：合法的「部分关闭」被误报 ⇒ 守卫会喊狼来了")

        // ③ 阴性：`⬜ **仍开着**` + `✅` ⇒ **故意不报**（第 35 行那种，见文件头）
        let onlyCheck = [
            "| 35 | … | ⬜ **仍开着**（§8.86 新开）。… ✅ **已关闭（随后撤销）** … |"
        ]
        #expect(
            Self.drift(in: onlyCheck).isEmpty,
            "阴性对照失败：`✅` 只表示子项完成，不该被当成整项关闭（精度靠这一条守住）")

        // ④ 阴性：两种标记在**不同行** ⇒ 不得命中（别把相邻两行读成同一行）
        let twoLines = [
            "| 32 | … 🟢 已关闭 … |",
            "| 35 | … ⬜ **仍开着** … |",
        ]
        #expect(
            Self.drift(in: twoLines).isEmpty,
            "阴性对照失败：跨行不该被当成同一行里的矛盾")

        // ⑤ 阴性：**散文**里同时提到两种标记 ⇒ 不得命中。
        //    2026-09-21 实测：不加「只管表格行」这条限定，§8.113.13 里讨论本判据的
        //    那段文字会把自己报成漂移（那一节正是拿这两个标记当例子写的）。
        let prose = [
            "**判据**：一行里不得同时出现「仍开着」标记 `⬜ **仍开着**` 与「整项关闭」标记 `🟢`。"
        ]
        #expect(
            Self.drift(in: prose).isEmpty,
            "阴性对照失败：散文里讨论这两个标记不该被当成漂移")
    }
}
