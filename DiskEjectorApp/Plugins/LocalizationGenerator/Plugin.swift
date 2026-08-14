// LocalizationGenerator — DiskEjector 本地化 BuildToolPlugin（单一可信源）。
//
// 在 `swift build` / `swift test`（以及发布流程的 swift build）编译 DiskEjectorApp target 前，
// 自动读取 Sources/Localization/Localizable.xcstrings，调用 gen_l10n_tool 生成
// L10n.generated.swift。生成的文件位于 plugin 工作目录，SwiftPM 会自动将其作为该 target
// 的额外源文件编译——因此无需把生成文件提交到 git，也无需在 run.sh/build.sh/发布插件里
// 手动调用 gen_l10n。
//
// 只要 Localizable.xcstrings 变化，下次构建即重新生成；新增 key 自动进入 L10n.Key 枚举，
// 未定义的 key 在编译期直接报错（绝不会静默漏翻）。
//
// 注意：PackagePlugin 自 SwiftPM 6 起弃用 `Path` 类型，统一改用 `URL`
// （`path`→`url`、`pluginWorkDirectory`→`pluginWorkDirectoryURL`、文件参数收 `URL`）。

import PackagePlugin
import Foundation

@main
struct LocalizationGenerator: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }

        // 定位 target 目录下的 Localizable.xcstrings（作为命令输入文件，沙箱允许读取）。
        guard let xcstringsFile = sourceTarget.sourceFiles.first(where: { $0.url.pathExtension == "xcstrings" }) else {
            // 该 target 没有本地化目录则不生成（不影响构建）。
            return []
        }
        let xcstringsURL = xcstringsFile.url

        // 生成文件放到 plugin 工作目录；SwiftPM 会自动把它当作 target 的源文件编译。
        let outputURL = context.pluginWorkDirectoryURL
            .appending(component: "L10n.generated.swift")

        // 编译好的生成器工具（executableTarget，不进入主 app）。
        let tool = try context.tool(named: "gen_l10n_tool")

        return [
            .buildCommand(
                displayName: "Generating L10n localized strings",
                executable: tool.url,
                arguments: [xcstringsURL.path, outputURL.path],
                inputFiles: [xcstringsURL],
                outputFiles: [outputURL]
            )
        ]
    }
}
