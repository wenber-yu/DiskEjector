import AppKit
import SwiftUI

@testable import DiskEjectorApp

/// 测试用的视图夹具：**造一个完全不碰真机的 `ContentView`**。
///
/// ## 为什么必须有这一层
///
/// `ContentView` 的两个 store 默认都是**生产单例**（`DiskListStore/shared` /
/// `OccupancyStore/shared`），而这条链的尽头是硬件：
///
/// ```
/// DiskListStore.shared 的 private init()  → DiskService.shared.fetchExternalDisks()
/// OccupancyStore.shared 的默认 detect     → 真的跑 lsof
/// ```
///
/// 于是「构造一个 `ContentView()`」这件事**本身就会去摸本机的磁盘**。后果有两层：
///
/// 1. **渲染结果随机器变** —— 换一台没插外置盘的机器，走的是另一个分支。
/// 2. **覆盖率随机器变** —— 2026-09-17 实测坐实：`DiskService.swift` **65–116 行**
///    （`isExternalVolume` 通过之后的枚举与 `makeDiskInfo` 组装）只在「本机真的有外置卷」
///    时才被执行，单测覆盖率因此浮动 **3.06pp**（41 行 / 分母 1342）。
///    完整取证（逐文件 diff + 触发链）见 `DESIGN-SPEC.md` §8.28.6。
///
/// 所以：**任何渲染 `ContentView` 的测试都必须经过本文件的工厂，不要写 `ContentView()`。**
/// 例外只有 ``SnapshotRenderTests`` —— 它出的就是「本机真实磁盘」的走查图，是刻意要真实数据，
/// 且只在 `DE_SNAPSHOTS=1` 下运行，不参与日常测试与覆盖率。
@MainActor
enum ViewFixtures {

    /// 一块固定的替身磁盘。
    ///
    /// 刻意造**一块**而不是零块：`ContentView` 在「有盘」与「没盘」下走的是两个不同的
    /// 渲染分支，而既有的排版契约（标题墨迹中心、刷新按钮墨迹、玻璃铺满）都是在
    /// 「有盘」那一支上标定的。用一块盘能复现原来的观感 ——
    /// **于是测出来的数字要是变了，就是真信号**，而不是「换了数据所以数字该变」。
    static let disk = DiskInfo(
        id: "/Volumes/TestDisk",
        bsdName: "disk9s2",
        volumeName: "TestDisk",
        mountPath: "/Volumes/TestDisk",
        totalBytes: 1_000_000_000_000,
        usedBytes: 300_000_000_000,
        freeBytes: 700_000_000_000,
        deviceProtocol: "USB",
        deviceModel: "SanDisk Extreme 55AE"
    )

    /// 一对**配对**的替身 store（磁盘列表 + 占用结论）。
    ///
    /// **必须成对造**：``OccupancyStore`` 用哪个 `diskStore` 决定了它测哪几块盘。
    /// 分开造就会得到「列表是 A、占用结论是 B」的画面 —— 而这种错在界面上几乎看不出来，
    /// 所以这里只提供一个入口，不提供「各自造一个」的用法。
    static func stores(disks: [DiskInfo]? = nil) -> (disk: DiskListStore, occupancy: OccupancyStore) {
        let store = DiskListStore(monitoring: false)
        store.replaceDisksForTesting(disks ?? [disk])
        return (store, OccupancyStore(diskStore: store, autoStart: false))
    }

    /// 造一个主窗口内容：磁盘列表与占用结论都是替身，**不挂监听、不起轮询、不跑 `lsof`**。
    ///
    /// - Parameters:
    ///   - disks: 要渲染的磁盘列表，默认一块 ``disk``。传 `[]` 即渲染空状态。
    ///   - skipsInitialRefresh: 默认 `true`。**注入列表时必须为 `true`** ——
    ///     否则 `.task` 会真的去枚举本机磁盘，把注入的列表覆盖掉。
    ///     需要测「刷新中」的观感请直接渲染 ``RefreshTitleBarButton``，别把这个开关关掉。
    static func mainWindow(
        disks: [DiskInfo]? = nil,
        skipsInitialRefresh: Bool = true
    ) -> ContentView {
        let s = stores(disks: disks)
        return ContentView(
            skipsInitialRefresh: skipsInitialRefresh,
            store: s.disk,
            occupancyStore: s.occupancy
        )
    }

    /// 走**生产装配路径**（`AppDelegate.makeMainWindow`）建主窗口，但两个 store 都是替身。
    ///
    /// `MainWindowTests` / `KeySilentWindowTests` 要断言的是**窗口层面**的配置
    /// （安全区、玻璃铺满、窗口类、尺寸），那条装配路径本身必须与真机一致 ——
    /// 替身只换**数据来源**，不换装配代码。
    static func mainWindowHandle(skipsInitialRefresh: Bool = true) -> NSWindow {
        let s = stores()
        return AppDelegate.makeMainWindow(
            store: s.disk, skipsInitialRefresh: skipsInitialRefresh, occupancyStore: s.occupancy)
    }
}
