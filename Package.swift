// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DiskEjectorApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 本地化生成器（独立本地 package，仅作为插件工具依赖，不进入主程序）。
        .package(path: "tools/gen_l10n_tool"),
        // Sparkle 2：自更新框架。**二进制 target**（官方发布的 Sparkle.xcframework zip），
        // 不从源码编译 —— 源码构建需要 Xcode 工程与一堆 XPC 子目标，SPM 里拿不到。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "DiskEjectorApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            // ⚠️ 已知冗余（**不是 bug，别去「修」**）：`Sources/Localization/Localizable.xcstrings`
            // 会被 SwiftPM 当成 **resource** 编译，产出
            // `.build/out/Products/<配置>/DiskEjectorApp_DiskEjectorApp.bundle`
            // （内含 en / zh-Hans / zh-Hant 三份 Localizable.strings）。
            // 但**没有任何代码读它** —— Sources/ 里 `Bundle.module` 出现 0 次，生成的
            // `L10n.generated.swift` 抬头逐字写着「无需 Bundle.module」；`build_app.sh`
            // 也不把这个 .bundle 拷进 .app。
            // ⛔ 不能用 `exclude:` 去掉：那会让 build plugin 的
            //    `sourceFiles.first(where: { $0.url.pathExtension == "xcstrings" })`
            //    找不到文件 ⇒ 本地化生成器**静默失效**。
            // 同理**不加** `defaultLocalization:` —— 会改变资源处理路径，零功能收益。
            // DiskArbitration：读取设备的 DADeviceInternal / DADeviceProtocol 等属性，
            // 作为「外置可推出」判定的事实来源（替代此前按挂载路径前缀猜测的做法）。
            linkerSettings: [.linkedFramework("DiskArbitration")],
            plugins: ["LocalizationGenerator"]
        ),
        .testTarget(
            name: "DiskEjectorAppTests",
            dependencies: ["DiskEjectorApp"],
            // 显式写 path：把「目录名 = target 名」这条**隐含约定**变成写在纸上的契约。
            // 不写也能跑（SPM 会按约定去 Tests/<TargetName> 找），但改了目录名时报错措辞很绕
            // （"Source files for target X should be located under …"），不如显式。
            path: "Tests/DiskEjectorAppTests"
        ),
        .plugin(
            name: "LocalizationGenerator",
            capability: .buildTool(),
            dependencies: [
                .product(name: "gen_l10n_tool", package: "gen_l10n_tool")
            ],
            // 同上：显式化，别靠 Plugins/<Name> 这条隐含约定。
            path: "Plugins/LocalizationGenerator"
        ),
    ],
    swiftLanguageModes: [.v6]
)
