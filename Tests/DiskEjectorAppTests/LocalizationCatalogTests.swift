import Foundation
import Testing

@testable import DiskEjectorApp

/// 本地化表 `Localizable.xcstrings` 的**结构契约**测试。
///
/// **为什么需要**：这张表是手改的（脚本插入文案、批量替换应用名），JSON 允许重复键
/// 而不报错。一旦同一个键出现两份，**两个消费者的取值口径就分叉了**：
/// - `gen_l10n_tool`（构建插件）取**第一份** → 程序里实际生效的是它
/// - 任何 `JSONDecoder` / `json.load` 取**最后一份**
///
/// 实测撞上过：`updateDownloadPageHint` 有两份互相矛盾的中文文案
/// （「打开下载页查看是否有新版本。」 vs 「Developer ID 直发版：前往 Releases 页面…」），
/// 手改下面那份完全不生效，而肉眼看文件也发现不了 —— 只有把「不许重复键」钉成测试才行。
/// （该键后来随「更新」分组被并进「关于」行而删除，这条记录保留作为踩坑依据。）
@Suite("本地化表")
struct LocalizationCatalogTests {

    private var catalogURL: URL {
        // #filePath = <仓库根>/Tests/DiskEjectorAppTests/LocalizationCatalogTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Localization/Localizable.xcstrings")
    }

    /// 顶层键（缩进恰好 4 空格），语言键缩进 8 空格不会误判。
    private func topLevelKeyCounts() throws -> [String: Int] {
        let raw = try String(contentsOf: catalogURL, encoding: .utf8)
        var counts: [String: Int] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("    \""), !line.hasPrefix("     "), line.hasSuffix(" : {") else {
                continue
            }
            let inner = line.dropFirst(5)
            guard let end = inner.range(of: "\" : {") else { continue }
            counts[String(inner[inner.startIndex..<end.lowerBound]), default: 0] += 1
        }
        return counts
    }

    @Test func 顶层键不许重复() throws {
        let counts = try topLevelKeyCounts()
        #expect(counts.count > 100, "只解析到 \(counts.count) 个键，解析逻辑可能坏了")
        let duplicates = counts.filter { $0.value > 1 }.map(\.key).sorted()
        #expect(
            duplicates.isEmpty,
            "本地化表里有重复键：\(duplicates)。它们在文件里各占一份、取值口径不同（构建插件取第一份，JSON 解析取最后一份），手改很可能改到不生效的那份"
        )
    }

    @Test func 每个键三语齐全() throws {
        let raw = try String(contentsOf: catalogURL, encoding: .utf8)
        var current: String?
        var languages: [String: Set<String>] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("    \""), !line.hasPrefix("     "), line.hasSuffix(" : {") {
                let inner = line.dropFirst(5)
                if let end = inner.range(of: "\" : {") {
                    current = String(inner[inner.startIndex..<end.lowerBound])
                    languages[current!] = []
                }
                continue
            }
            guard let key = current else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for lang in ["zh-Hans", "zh-Hant", "en"] where trimmed.hasPrefix("\"\(lang)\" : {") {
                languages[key]?.insert(lang)
            }
        }
        let incomplete = languages.filter { $0.value.count != 3 }.keys.sorted()
        #expect(
            incomplete.isEmpty,
            "这些键没有配齐三语：\(incomplete)。缺哪一档就会回退到 zh-Hans 或键名，用户会看到语言混杂的界面"
        )
    }

    /// 菜单栏面板头部的「外置磁盘」分组标题已删除，对应文案键也一并移除。
    @Test func 已删除的分组标题文案不再存在() {
        #expect(
            L10n.Key(rawValue: "menuExternalDisks") == nil,
            "「外置磁盘」分组标题已从菜单栏面板移除（它与应用名重复、白占一行高度），文案键不该再留着"
        )
    }

    /// **每个键都必须有消费者**（`Sources/` 里出现过 `.key`）。
    ///
    /// ## 为什么这条必须存在（2026-09-18 实扫）
    ///
    /// 「有声明、没有消费者」是这半年里最贵的一类 bug，已经撞了三次：
    /// `startIfNeeded()`（updater 从未启动）、`driverDidFailDownload`（`.failed` 那一态
    /// 没有生产者）、三组 `*BusyBar*` 令牌接错行（菜单行与紧凑行各错一处）。
    /// **文案键尤其隐蔽**：删掉一个没人用的键，代码照样编译、测试照样绿、
    /// 界面看不出任何变化 —— 它只是躺在三份语言表里，而下一个读到的人
    /// 会以为还有一个地方在用它。实测当时就躺着两个（见下一条）。
    ///
    /// ## 口径：`.key` 成员表达式就算消费者，且**偏松**
    ///
    /// 消费者有三种形式：`L10n.tr(.x)`、`L10n.tr(cond ? .on : .off)`、
    /// `titleKey: .x`（键被当值传进结构体字段）。只认第一种会误报
    /// （实测 158 个键里有 9 个是后两种形式）。
    /// 代价是**别的枚举的同名 case 也能满足它** —— `openSettings` 既是文案键、
    /// 又是 `MenuAction` 的 case。也就是说这条守卫**会漏报，但不会误报**，宁可漏报。
    ///
    /// 完整的（能抓漏报的）扫描在 `.build/probe/keyref_scan.py`，见 §8.48。
    @Test func 每个键都必须有消费者() throws {
        let keys = try topLevelKeyCounts().keys.sorted()
        #expect(keys.count > 100, "只解析到 \(keys.count) 个键，解析逻辑可能坏了")

        let sourcesRoot =
            catalogURL
            .deletingLastPathComponent()  // Localization/
            .deletingLastPathComponent()  // Sources/
        guard let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        else {
            Issue.record("枚举不到 \(sourcesRoot.path)")
            return
        }
        var code = ""
        var fileCount = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            fileCount += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            // 去掉**整行**注释：本仓库的注释习惯是**引用**被讨论的标识符
            // （例如本条注释自己就提到了 `terminateAndEject`），不去掉的话
            // 「把调用删掉、注释留着」依然会绿。
            code +=
                text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        #expect(
            fileCount > 30,
            "只读到 \(fileCount) 个 .swift —— 路径多半不对，下面的结论一律作废"
        )

        let unused = keys.filter { key in
            code.range(of: "\\.\(key)(?![A-Za-z0-9_])", options: .regularExpression) == nil
        }
        #expect(
            unused.isEmpty,
            """
            这些文案键在 Sources/ 里没有任何消费者：\(unused)。\
            删掉它们不会编译失败、不会让任何测试变红，只是躺在三份语言表里 —— \
            而下一个读到的人会以为还有一个地方在用它们。
            """
        )
    }

    /// 两个**零消费者**的文案键已删除（2026-09-18 实扫）。
    ///
    /// **为什么要把「不存在」钉成测试**：与上面 App Store 那两条同一个理由 ——
    /// 死文案会误导人。这两条尤其：
    /// - `terminateAndEject`（「终止程序并推出」）与**实际在用**的
    ///   `closeAndEject`（「关闭并推出」）**语义相近、用词不同** ——
    ///   下一个读到的人很容易以为还有一个动作叫「终止程序并推出」；
    /// - `updateChecking`（「正在检查…」）是**故意不画**的那一态的残留
    ///   （`showUserInitiatedUpdateCheck` 只写日志、不画「正在检查…」，见 §8.35.5）。
    @Test func 两个零消费者的文案键不再存在() {
        #expect(
            L10n.Key(rawValue: "terminateAndEject") == nil,
            "「终止程序并推出」没有任何消费者（按钮用的是 closeAndEject「关闭并推出」），文案键不该再留着"
        )
        #expect(
            L10n.Key(rawValue: "updateChecking") == nil,
            "「正在检查…」是故意不画的那一态的残留，文案键不该再留着"
        )
    }

    /// App Store 渠道的文案已删除（2026-09-18 决定：本应用不上架 MAS）。
    ///
    /// **为什么要把「不存在」钉成测试**：死文案和死代码一样会误导人 —— 下一轮有人看到
    /// 「在 App Store 中查看」会以为还有个上架渠道要照顾，照着它把 MAS 分支加回来。
    /// 而「文案还在但没人用」不会编译失败、也不会有任何告警。
    ///
    /// 两条键一并钉：`openInAppStore`（按钮标题）与 `updateChannelAppStore`（渠道显示名）。
    @Test func 已删除的AppStore渠道文案不再存在() {
        #expect(
            L10n.Key(rawValue: "openInAppStore") == nil,
            "本应用不上架 App Store，「在 App Store 中查看」按钮已删除，文案键不该再留着"
        )
        #expect(
            L10n.Key(rawValue: "updateChannelAppStore") == nil,
            "本应用不上架 App Store，「App Store 版」渠道名已删除，文案键不该再留着"
        )
    }
}
