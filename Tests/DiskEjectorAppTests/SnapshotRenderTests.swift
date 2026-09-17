import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 把 v2 设计落地的各个屏幕**离屏渲染成 PNG**，供人工与设计稿逐屏比对。
///
/// **默认不跑**：这是唯一一个会写文件的测试，不该在 `swift test` 里产生副作用。
/// 需要出图时显式开启：
///
/// ```bash
/// DE_SNAPSHOTS=1 swift test --filter 导出设计快照
/// # 图落在 /tmp/de-snapshots/
/// ```
///
/// **为什么需要它**：SPM 工程没有 Xcode 预览，而布局契约测试只能断言数字
/// （高度、宽度、分隔线条数），断不了「看起来对不对」。设计走查时缺一个能直接看的画面。
///
/// **它已经抓到过一个真缺陷**：2026-09-15 出图时发现设置面板「视觉效果」那行的标签
/// 被压成**竖排单字** —— 数字断言全绿，只有看图才看得出来。根因见
/// ``VisualStyle/shortName``，测量手法的问题见 `SettingsLayoutTests.renderedSize`。
///
/// **覆盖面与已知缺口**：
/// - ✅ 磁盘行三种判定 × 明暗、紧凑行、设置面板、FDA 两种横幅、空状态、占用/失败弹窗
/// - ✅ 主窗口与菜单栏面板：渲染**真实** `DiskListStore` 的内容（本机 1 块外接盘，
///   首帧占用态为 `.unknown`，正好对应设计稿的未授权变体）
/// - ⚠️ **未覆盖**：多盘并列 / 忙态的主窗口与面板 —— `DiskListStore.disks` 是
///   `private(set)` 且 `init` 私有，视图也直读 `.shared`，没有注入口。
///   要覆盖这些状态得给 `DiskListStore` / `ContentView` 加依赖注入，属独立改动。
@MainActor
struct SnapshotRenderTests {

    private let outDir = "/tmp/de-snapshots"

    private let disk = DiskInfo(
        id: "/Volumes/My Passport",
        bsdName: "disk4s2",
        volumeName: "My Passport",
        mountPath: "/Volumes/My Passport",
        totalBytes: 1_000_000_000_000,
        usedBytes: 300_000_000_000,
        freeBytes: 700_000_000_000,
        deviceProtocol: "USB",
        deviceModel: "SanDisk Extreme 55AE"
    )

    private let procs = [
        OccupyingProcess(pid: 5340, processName: "IINA", path: "/Volumes/My Passport/clip.mp4"),
        OccupyingProcess(pid: 39298, processName: "tail", path: "/Volumes/My Passport/clip.mp4"),
    ]

    /// `02-menu-bar.html` 里面板展示的那两块盘 —— 名称、容量、占用都与设计稿逐字一致。
    ///
    /// 出图用它而不是本机真实磁盘，理由见 ``导出设计快照()`` 里面板那一段的注释。
    private let designDisks = [
        DiskInfo(
            id: "/Volumes/Samsung T7",
            bsdName: "disk5s2",
            volumeName: "Samsung T7",
            mountPath: "/Volumes/Samsung T7",
            totalBytes: 1_000_000_000_000,
            usedBytes: 300_000_000_000,
            freeBytes: 700_000_000_000,
            deviceProtocol: "USB",
            deviceModel: "Samsung PSSD T7"
        ),
        DiskInfo(
            id: "/Volumes/WD Blue",
            bsdName: "disk6s2",
            volumeName: "WD Blue",
            mountPath: "/Volumes/WD Blue",
            totalBytes: 500_000_000_000,
            usedBytes: 120_000_000_000,
            freeBytes: 380_000_000_000,
            deviceProtocol: "USB",
            deviceModel: "WD Blue SN570"
        ),
    ]

    // MARK: - 位图写出

    /// 把一个已经布局好的 `NSView` 按 2x 写成 PNG。
    ///
    /// 手动构造 2x 的 `NSBitmapImageRep` 而不是用 `bitmapImageRepForCachingDisplay`：
    /// 后者按视图的 backingScaleFactor 出图，而离屏视图没有 window → 只有 1x，图会发虚。
    private func writePNG(_ view: NSView, size: CGSize, name: String) throws {
        let scale: CGFloat = 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            Issue.record("无法创建位图：\(name)")
            return
        }
        rep.size = size
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("PNG 编码失败：\(name)")
            return
        }
        try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        print("  导出 \(name).png  \(Int(size.width))×\(Int(size.height))pt")
    }

    /// 离屏渲染一个 SwiftUI 视图并写成 PNG。
    ///
    /// 高度用 `sizeThatFits(in:)` 而不是 `fittingSize` —— 后者不认宽度约束，
    /// 会把内容按理想宽度排版，出图与真机不符（对照实验见
    /// `SettingsLayoutTests.renderedSize` 的注释）。窗口类屏幕（主窗口 / 面板）
    /// 传显式 `height`，因为它们由窗口定尺寸、不随内容收缩。
    ///
    /// 明暗通过 `hosting.view.appearance` 切换（比 `environment(\.colorScheme,)` 可靠，
    /// 因为 AppKit 宿主的外观会覆盖 SwiftUI 环境值）。
    private func dump(
        _ view: some View, width: CGFloat, height: CGFloat? = nil, name: String, dark: Bool = false
    ) throws {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let resolved =
            height
            ?? hosting.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let size = CGSize(width: width, height: max(resolved, 1))
        hosting.view.setFrameSize(size)
        hosting.view.layoutSubtreeIfNeeded()
        try writePNG(hosting.view, size: size, name: name)
    }

    /// 弹窗出图的留白：四周各 40，便于看清圆角、描边与阴影。
    private static let alertStagePadding: CGFloat = 40

    /// 把推出弹窗垫在深色舞台上出图。
    ///
    /// **为什么不能直接截弹窗**：它是毛玻璃 + 半透明罩层，在透明背景上会渲成一片浅色，
    /// 圆角、描边与阴影全都看不出来 —— 而这三样恰恰是「看起来像不像设计稿」的关键。
    ///
    /// **必须先量出弹窗高度、再用确定尺寸搭舞台**：舞台底色 `Color` 是弹性的，
    /// 若让它参与 `sizeThatFits(in: …greatestFiniteMagnitude)` 的测量，
    /// 它会接受那个无穷大的高度提案，舞台高度随之变成无穷 → 写位图时
    /// `Int(∞ * 2)` 直接 **SIGTRAP**（实测踩到）。所以先只量弹窗本身，再定尺寸。
    private func dumpAlert(_ model: EjectAlertModel, name: String, dark: Bool = false) throws {
        _ = NSApplication.shared
        let alert = EjectAlertView(model: model, onAction: { _ in })
        let probe = NSHostingController(rootView: alert)
        let alertHeight = probe.sizeThatFits(
            in: CGSize(width: DesignTokens.Size.alertWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height
        let stage = CGSize(
            width: DesignTokens.Size.alertWidth + Self.alertStagePadding * 2,
            height: alertHeight + Self.alertStagePadding * 2)

        let hosting = NSHostingController(
            rootView: ZStack {
                Color(nsColor: NSColor(srgbRed: 0.44, green: 0.46, blue: 0.50, alpha: 1))
                alert
            }
            .frame(width: stage.width, height: stage.height))
        hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.view.setFrameSize(stage)
        hosting.view.layoutSubtreeIfNeeded()
        try writePNG(hosting.view, size: stage, name: name)
    }

    // MARK: - 出图

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DE_SNAPSHOTS"] == "1"))
    func 导出设计快照() async throws {
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // 主窗口列表：800 − 左右各 16pt 内边距。
        let mainW = DesignTokens.Size.mainWindow.width - 32
        // 菜单栏面板里的磁盘行：360 − 列表左右各 8pt。
        //
        // ⚠️ **不能再减行自己的 8pt**：`MenuBarDiskRow` 自带 `.padding(8)`，
        // 它的**外框**宽就是 360 − 16 = 344。曾经按「面板 8 + 行内 8」写成 328，
        // 于是出图比真机窄了 16pt —— 文本列被压窄，长文案（如「占用程序：…」）
        // 的截断位置与真机不一致，走查时看到的换行/省略号都是假的。
        let menuW = DesignTokens.Size.menuPopoverWidth - 16

        // ---- 磁盘行：三种判定状态（设计稿 06-states.html 的状态矩阵）----
        let states: [(String, OccupancyResult)] = [
            ("busy", .occupied(procs)),
            ("safe", OccupancyResult.none),
            ("unknown", .needsFullDiskAccess),
        ]

        for (label, occ) in states {
            try dump(
                DiskRow(disk: disk, occupancy: occ, accent: .default, onEject: {}, density: .regular),
                width: mainW, name: "row-\(label)-light")
            try dump(
                MenuBarDiskRow(disk: disk, occupancy: occ, accent: .default, onEject: {}),
                width: menuW, name: "menurow-\(label)-light")
        }

        // 紧凑行（≥ 4 块盘时自动切换）
        try dump(
            DiskRow(disk: disk, occupancy: .occupied(procs), accent: .default, onEject: {}, density: .compact),
            width: mainW, name: "row-compact-busy-light")

        // ---- 主窗口（设计稿 01-main-window.html）----
        // 直读 DiskListStore.shared，渲染的是本机真实磁盘与首帧占用态。
        //
        // ⚠️ **必须传 `skipsInitialRefresh: true`**：`cacheDisplay` 是**同步**截的，而
        // `ContentView` 的 `.task` 会自动 `await refreshDisks()` —— 它先把 `isRefreshing`
        // 置真，再等占用检测（`lsof`）跑完。截图正好落在「盘已经列出来、刷新还没收尾」
        // 那个窗口里，于是走查图右上角画的是 **spinner**，而设计稿里是箭头。
        // 连跑三次指纹完全一致（`4fde925d31bc`、峰值 158），是**确定性**的，不是随机。
        //
        // 磁盘列表**不需要**在这里补：`DiskListStore.shared` 的 `private init()` 会
        // 同步填一次 `fetchExternalDisks()`，访问 `.shared` 时列表就是满的。
        // ⚠️ 也**不要**在这里 `await OccupancyStore.shared.refresh(disks:)` ——
        // 那会真的跑 `lsof`，实测把出图从十几秒拖到 6 分钟以上（本轮踩到）。
        // 面板那一段用的是注入检测器的 `designOccupancy`，刻意避开了真实 `lsof`。
        try dump(
            ContentView(skipsInitialRefresh: true), width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-light")
        try dump(
            ContentView(skipsInitialRefresh: true), width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height, name: "main-window-dark", dark: true)

        // ---- 菜单栏面板（设计稿 02-menu-bar.html）----
        //
        // **用设计稿里那两块盘，不用本机真实磁盘。**
        //
        // 本机只插了 1 块盘，而 `02-menu-bar.html` 的面板里有 2 块（Samsung T7 忙 /
        // WD Blue 安全）。拿「1 块盘的实现」去比「2 块盘的设计稿」，并排图上会读成
        // 「设计稿 350 / 实现 279，差了 71pt 的排版」—— 而真相是那 71pt 里
        // 69 是第二块盘的行高、2 是外框边框的实现差异（见 `MenuPopoverLayoutTests`）。
        //
        // 出图与对照都必须在**同内容量**下比。磁盘列表与占用结论现在都可注入，
        // 这条就做得到了。
        let designStore = DiskListStore(monitoring: false)
        designStore.replaceDisksForTesting(designDisks)
        let designOccupancy = OccupancyStore(
            diskStore: designStore,
            detect: { path in
                // 不捕获任何外部值，闭包天然 `@Sendable`。
                guard path.hasSuffix("Samsung T7") else { return .none }
                return .occupied([
                    OccupyingProcess(pid: 501, processName: "Finder", path: path + "/a.mov"),
                    OccupyingProcess(pid: 502, processName: "图像捕捉", path: path + "/b.heic"),
                ])
            },
            autoStart: false)
        await designOccupancy.refresh(disks: designDisks)

        let popover = MenuPopoverView(
            store: designStore,
            occupancyStore: designOccupancy,
            accent: .default,
            onOpenMainWindow: {}, onRefresh: {}, onOpenSettings: {}, onQuit: {}, onEject: { _ in })
        try dump(popover, width: DesignTokens.Size.menuPopoverWidth, name: "menu-popover-light")
        try dump(popover, width: DesignTokens.Size.menuPopoverWidth, name: "menu-popover-dark", dark: true)

        // ---- FDA 横幅两种语义（设计稿 04-onboarding.html）----
        try dump(
            NoticeBanner(
                kind: .warning,
                icon: "lock",
                message: L10n.tr(.fdaBannerLead),
                actionTitle: L10n.tr(.openSystemSettings),
                accent: .default,
                action: {}),
            width: DesignTokens.Size.mainWindow.width, name: "banner-warning-light")
        try dump(
            NoticeBanner(
                kind: .success,
                icon: "checkmark.circle",
                message: L10n.tr(.fdaGrantedBanner),
                accent: .default),
            width: DesignTokens.Size.mainWindow.width, name: "banner-success-light")

        // ---- 引导面板（设计稿 04-onboarding.html 第一块）----
        try dump(
            OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}),
            width: DesignTokens.Size.onboardingPanelWidth, name: "onboarding-light")
        try dump(
            OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}),
            width: DesignTokens.Size.onboardingPanelWidth, name: "onboarding-dark", dark: true)

        // ---- 空状态（设计稿 02-menu-bar.html 空状态 / 06-states.html）----
        // 高度 380 与 ContentView 里 `emptyState` 的用法一致。
        try dump(
            EmptyStateView(
                systemName: "externaldrive",
                title: L10n.tr(.noRemovableDisks),
                description: L10n.tr(.insertDiskHint) + "\n" + L10n.tr(.emptyStateFilterHint),
                actionTitle: L10n.tr(.refresh),
                actionSystemImage: "arrow.clockwise",
                action: {},
                accent: .default),
            width: mainW, height: 380, name: "empty-state-light")

        // ---- 两个弹窗（设计稿 03-eject-flow.html，自绘）----
        //
        // 弹窗垫在深色底上出图：设计稿的弹窗是毛玻璃，直接截透明背景会看不出
        // 圆角、描边与阴影（这正是「层级问题只在深色暴露」的原因）。
        let busyModel = EjectAlertModel.busy(disk: disk, occupying: procs)
        let failureModel = EjectAlertModel.failure(disk: disk, failure: .inUse)
        let noProcessModel = EjectAlertModel.busy(disk: disk, occupying: [])

        try dumpAlert(busyModel, name: "alert-busy-light")
        try dumpAlert(busyModel, name: "alert-busy-dark", dark: true)
        try dumpAlert(failureModel, name: "alert-failure-light")
        try dumpAlert(failureModel, name: "alert-failure-dark", dark: true)
        // 无进程可列（未授予完全磁盘访问）—— 没有区块，只剩说明 + 警示。
        try dumpAlert(noProcessModel, name: "alert-busy-noprocess-light")

        // ---- 深色对照（设计稿 07-dark.html）----
        try dump(
            DiskRow(disk: disk, occupancy: .occupied(procs), accent: .default, onEject: {}, density: .regular),
            width: mainW, name: "row-busy-dark", dark: true)
        try dump(
            MenuBarDiskRow(disk: disk, occupancy: .occupied(procs), accent: .default, onEject: {}),
            width: menuW, name: "menurow-busy-dark", dark: true)
        try dump(SettingsView(), width: DesignTokens.Size.settingsPanel.width, name: "settings-light")
        try dump(
            SettingsView(), width: DesignTokens.Size.settingsPanel.width, name: "settings-dark", dark: true)
    }
}
