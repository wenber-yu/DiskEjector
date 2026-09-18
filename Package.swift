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
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            // DiskArbitration：读取设备的 DADeviceInternal / DADeviceProtocol 等属性，
            // 作为「外置可推出」判定的事实来源（替代此前按挂载路径前缀猜测的做法）。
            linkerSettings: [.linkedFramework("DiskArbitration")],
            plugins: ["LocalizationGenerator"]
        ),
        .testTarget(
            name: "DiskEjectorAppTests",
            dependencies: ["DiskEjectorApp"]
        ),
        .plugin(
            name: "LocalizationGenerator",
            capability: .buildTool(),
            dependencies: [
                .product(name: "gen_l10n_tool", package: "gen_l10n_tool")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
