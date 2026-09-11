// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DiskEjectorApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 本地化生成器（独立本地 package，仅作为插件工具依赖，不进入主程序）。
        .package(path: "tools/gen_l10n_tool"),
    ],
    targets: [
        .executableTarget(
            name: "DiskEjectorApp",
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
