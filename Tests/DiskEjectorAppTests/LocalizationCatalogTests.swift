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
}
