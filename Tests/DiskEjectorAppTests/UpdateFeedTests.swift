import Foundation
import Testing

@testable import DiskEjectorApp

/// Sparkle 更新 feed 的**配置契约**测试。
///
/// ## 为什么测的是 shell 脚本，不是 Swift 代码
///
/// feed 地址只有一个真相：`build_app.sh` 写进 Info.plist 的 `SUFeedURL`
/// （Sparkle 从 Info.plist 读它；`SPUUpdater.setFeedURL` 已废弃）。Swift 侧**没有第二份**。
/// 于是能钉的只有脚本本身 —— 这正是要测的东西：
/// **改了脚本而测试还绿 = 假覆盖**，所以测试得读脚本，不能读某个自己维护的常量。
///
/// 判据同 `LocalizationCatalogTests`：手改的配置最容易填错，而填错不会编译失败。
@Suite("更新 feed")
struct UpdateFeedTests {

    private var repoRoot: URL {
        // #filePath = <仓库根>/Tests/DiskEjectorAppTests/UpdateFeedTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// `SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-<默认值>}"` 里的默认值。
    private func defaultFeedURL() throws -> String {
        let script = try contents("build_app.sh")
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            guard
                let range = line.range(
                    of: #"SPARKLE_FEED_URL="\$\{SPARKLE_FEED_URL:-([^}]*)\}""#,
                    options: .regularExpression)
            else { continue }
            let inner = line[range]
            // 取 `:-` 到结尾 `}"` 之间的内容
            guard let start = inner.range(of: ":-", options: .backwards) else { continue }
            var value = String(inner[start.upperBound...])
            if value.hasSuffix("}\"") { value.removeLast(2) }
            return value
        }
        Issue.record("build_app.sh 里找不到 SPARKLE_FEED_URL 的默认值")
        return ""
    }

    /// feed 必须是** appcast**，不能是 GitHub 的 /releases/latest。
    ///
    /// 「更新链接用 GitHub 的 release 最新版本链接」这个说法很容易被直接实现成
    /// `SUFeedURL = https://github.com/.../releases/latest` —— 那个地址给的是
    /// HTML 页面 / atom 源，Sparkle 解析不了（它要带 `sparkle:` 命名空间的 RSS）。
    /// GitHub Releases 是**文件托管处**，不是 feed；下载地址在 appcast 的 enclosure 里。
    @Test func feed指向appcast而不是GitHub的latest页() throws {
        let raw = try defaultFeedURL()
        let url = try #require(URL(string: raw), "feed 地址不是合法 URL：\(raw)")

        #expect(url.scheme == "https", "feed 必须走 https：\(raw)")
        #expect(url.path.hasSuffix("appcast.xml"), "feed 必须指向 appcast.xml：\(raw)")
        #expect(
            !raw.contains("releases/latest"),
            "别把 feed 指向 /releases/latest —— 那是 HTML/atom 页面，Sparkle 解析不了；下载链接应写在 appcast 的 enclosure 里"
        )
    }

    /// 不给 Sparkle 抢先弹「要不要自动检查更新」的机会：本应用自己有开关。
    @Test func 脚本写明了自动检查的默认值() throws {
        let script = try contents("build_app.sh")
        #expect(
            script.contains("<key>SUEnableAutomaticChecks</key>"),
            "缺 SUEnableAutomaticChecks：不设的话 Sparkle 会在第二次启动弹权限窗，和设置里的「自动更新」开关打架"
        )
        #expect(
            script.contains("<key>SUScheduledCheckInterval</key>"),
            "缺 SUScheduledCheckInterval：自动检查的周期应当显式写出来"
        )
    }

    /// `--download-url-prefix` 必须以斜杠结尾。
    ///
    /// 实测（2026-09-18）：不带斜杠时 generate_appcast 会把前缀的最后一段当文件名替换掉，
    /// 产出 `.../download/DiskEjector-1.2.3.dmg` —— **tag 那一段没了，而且不报错**，
    /// 直到用户点「安装更新」才 404。
    @Test func appcast脚本的下载前缀必须以斜杠结尾() throws {
        let script = try contents("scripts/make_appcast.sh")
        // 只看**真正传参的那一行**：注释和错误提示里也会出现这个选项名，
        // 连它们一起断言会把「改了注释」误判成「改了参数」。
        var invocation: String?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("GEN_ARGS+=(") && line.contains("--download-url-prefix") {
                invocation = String(line)
            }
        }
        let line = try #require(invocation, "scripts/make_appcast.sh 里找不到 --download-url-prefix 的调用")
        #expect(
            line.hasSuffix("v$VERSION/\")"),
            "下载前缀必须以斜杠结尾，否则 generate_appcast 会吃掉最后一段（tag）而不报错：\(line)"
        )
    }

    // MARK: - 仓库里那份 appcast.xml（真实交付物）

    /// 把 appcast 的 XML 解出来。**用 XMLParser，不用正则** ——
    /// `<description>` 是 CDATA，正则取到的是原文（会连 `]]>` 一起带上），
    /// 而 Sparkle 交给 `UpdateUserDriver` 的是**解完 CDATA 的纯文本**。
    /// 用正则测等于测了个和线上不同的东西。
    private final class AppcastParser: NSObject, XMLParserDelegate {
        var shortVersion: String?
        var enclosureURL: String?
        var descriptionHTML: String?

        private var current = ""

        static func parse(_ xml: String) -> AppcastParser? {
            let parser = AppcastParser()
            let xmlParser = XMLParser(data: Data(xml.utf8))
            xmlParser.delegate = parser
            guard xmlParser.parse() else { return nil }
            return parser
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            current = ""
            if elementName == "enclosure" { enclosureURL = attributes["url"] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            current += string
        }

        /// ⚠️ CDATA 走的是**这个方法**，不是 `foundCharacters` —— 少了它
        /// `<description>` 会永远读成空串，测试于是「通过」（空输入返回空数组）。
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            current += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "description": descriptionHTML = text
            case "sparkle:shortVersionString", "shortVersionString": shortVersion = text
            default: break
            }
            current = ""
        }
    }

    /// 仓库里那份 appcast 必须能让弹窗**真的显示出更新条目**。
    ///
    /// 空 `<description>` 不会崩、不会报错 —— `UpdateReleaseNotes.lines` 空输入返回空数组，
    /// 调用方据此**不画**「本次更新」区块。于是「没写说明」与「写了但没生效」
    /// 在界面上长得一模一样（都是「没有这一块」）。这条守卫把它们区分开。
    @Test func 仓库里的appcast必须能解析出更新条目() throws {
        let appcast = try contents("appcast.xml")
        let parsed = try #require(AppcastParser.parse(appcast), "appcast.xml 不是合法 XML")

        let lines = UpdateReleaseNotes.lines(fromHTML: parsed.descriptionHTML)
        #expect(
            !lines.isEmpty,
            """
            appcast.xml 的 <description> 解析不出任何条目 → 新版本弹窗的「本次更新」是空的。
            要么补 release-notes/<版本>.html 后用 RELEASE_NOTES_FILE=… ./scripts/make_appcast.sh 重新生成，
            要么明确接受「这一块不显示」。
            """
        )

        // 残留的标记：说明文件里写了 HTML 注释时最容易中招 ——
        // `stripTags` 只剥 `<…>` 尖括号对，**不认注释**，注释正文会原样进到弹窗里。
        for line in lines {
            #expect(!line.contains("<!--") && !line.contains("-->"), "条目里残留了注释标记：\(line)")
            #expect(!line.contains("]]>"), "条目里残留了 CDATA 结束符（说明取的是正则原文而非 XML 解析结果）：\(line)")
        }
    }

    /// `enclosure` 的文件名必须与脚本让你上传的那个资产**同名**。
    ///
    /// 实测（2026-09-18）：`make_appcast.sh` 的「下一步」原本让用户上传
    /// `DiskEjector.dmg`，而 enclosure 里写的是 `DiskEjector-<版本>.dmg` ——
    /// 照指引做，用户点「安装更新」时**必 404**，而 appcast 本身不报任何错。
    /// 同一个事实被写在两个地方（指引一次、工具生成一次），所以得有一条守卫来比对。
    @Test func appcast的下载文件名必须与待上传资产同名() throws {
        let appcast = try contents("appcast.xml")
        let parsed = try #require(AppcastParser.parse(appcast), "appcast.xml 不是合法 XML")

        let version = try #require(parsed.shortVersion, "appcast 里没有 sparkle:shortVersionString")
        let enclosure = try #require(parsed.enclosureURL, "appcast 里没有 enclosure，更新无法下载")

        #expect(
            enclosure.contains("/releases/download/v\(version)/"),
            "enclosure 里没有 releases/download/v\(version)/ 这一段（前缀少了斜杠就会这样，而且不报错）：\(enclosure)"
        )
        #expect(
            URL(string: enclosure)?.lastPathComponent == "DiskEjector-\(version).dmg",
            "enclosure 的文件名必须与脚本让你上传的那个文件名逐字相同，改名即 404：\(enclosure)"
        )
    }

    /// 发布说明文件必须**能被真实解析器解析出条目**，且里面**不能有 HTML 注释**。
    ///
    /// `UpdateReleaseNotes.stripTags` 只剥 `<…>` 尖括号对 —— `<!-- 说明 -->`
    /// 剥掉 `<!--` 之后，**注释正文会原样出现在新版本弹窗里**（2026-09-18 实测踩到）。
    /// 脚本里已有一条守卫直接拦下，这里再对**仓库里真实存在的说明文件**兜一层。
    ///
    /// ⚠️ 第二条断言（解析出条目）是 2026-09-18 补的：说明文件被外部编辑器改写
    /// （例如注入 `data-page-node-id="…"` 这类**属性**）时，`stripTags` 的深度计数
    /// 会把整个标签连属性一起吞掉，于是**解析结果不变** —— 但那只是这一次运气好。
    /// 「改坏了」在弹窗上的表现是「这一块不显示」，与「本来就没写说明」长得一模一样，
    /// 所以这里必须用**真实解析器**跑一遍，而不是靠读文件推断。
    @Test func 发布说明文件里不能有HTML注释() throws {
        let dir = repoRoot.appendingPathComponent("release-notes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            // 只看**说明文件**：`README.md` 是格式文档，里面正当地举了 `<!-- 说明 -->` 这个反例。
            .filter { $0.hasSuffix(".html") }
        for file in files {
            let body = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            #expect(
                !body.contains("<!--"),
                "release-notes/\(file) 里有 HTML 注释 —— 解析器不认注释，注释正文会原样出现在弹窗里"
            )
            let lines = UpdateReleaseNotes.lines(fromHTML: body)
            #expect(
                !lines.isEmpty,
                """
                release-notes/\(file) 用真实解析器跑出来是空的 → 用它生成的 appcast
                会让弹窗的「本次更新」整块不显示，而那与「没写说明」长得一模一样。
                """
            )
        }
    }
}
