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
}
