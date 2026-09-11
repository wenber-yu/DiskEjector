import AppKit
import SwiftUI

/// 主窗口内容（与设计稿"主窗口 - 磁盘列表"/"主窗口 - 空状态"对齐）。
///
/// **设计稿规格**：800 × 520，外框圆角 12，居中标题栏 52px + 毛玻璃，
/// FDA 横幅，磁盘行（菜单栏 panel 同款，必要时再加圆角卡片样式）。
///
/// **统一背景**：跟菜单栏 panel 同款 `.ultraThinMaterial`（macOS 14 用 `.regularMaterial` 兜底），
/// 不再区分 transparent/tinted 模式，跟菜单栏视觉一致。
/// **保留的不变量**：
/// - 列表来自 ``DiskListStore``（与菜单栏同源）
/// - 占用检测走 ``EjectFlowController``，15s 定时 + disks 变化时触发
/// - FDA canary 每轮同步，决定是否显示横幅
/// - 推出走 ``EjectUI.handle``，与菜单栏共用弹窗
struct ContentView: View {

    @ObservedObject private var store = DiskListStore.shared
    @State private var isRefreshing = false
    @State private var ejectingDiskId: String? = nil
    @State private var showSettings = false

    /// 每个卷的占用检测结果。`.unknown` 会被渲染成说明文字，而不是当成「没有占用」。
    @State private var occupancy: [String: OccupancyResult] = [:]

    /// 占用检测单飞标记：防止上一轮 lsof 未跑完又起一轮。
    @State private var isDetecting = false

    /// 是否已授予「完全磁盘访问」（FDA）。决定是否在主窗口顶部展示 ``FdaBanner`` 横幅。
    ///
    /// **必须**与 `OccupancyDetector.isFullDiskAccessAuthorized()` 的**实时探测值**同步——
    /// 该函数是 FDA 状态机的**单一事实来源**（探针选型与理由见 OccupancyDetector 注释）。
    /// 之前的实现只在 `detectOccupancy(for:)` 末尾刷新一次、且被 `guard !disks.isEmpty`
    /// 保护，导致"刚启动 / 没插硬盘 / 刚授权完回 app"三种场景下横幅状态都是过期的。
    ///
    /// 默认值 `false` 是有意的：app 启动后第一帧**不假设已授权**，`.task` 里立即同步探测一次，
    /// 在用户能看到 UI 之前 `fdaAuthorized` 已经是真实值。
    @State private var fdaAuthorized = false

    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    var body: some View {
        ZStack {
            // 主窗口背景：透明模式用系统液态玻璃（VisualEffectBackground），
            // 色调模式用半透明窗口背景色。两者均覆盖整窗，圆角由外层 NSWindow 设置。
            backgroundLayer

            VStack(spacing: 0) {
                titleBar
                    .frame(maxWidth: .infinity)
                if !fdaAuthorized {
                    FdaBanner(
                        messageLead: L10n.tr(.fdaGuidanceBannerLead),
                        messageTail: L10n.tr(.fdaGuidanceBannerTail),
                        actionLabel: L10n.tr(.openSystemSettings),
                        action: AppSettings.openFullDiskAccessSettings,
                        accent: accentColor
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                scrollRegion
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .frame(width: DesignTokens.Size.mainWindow.width,
               height: DesignTokens.Size.mainWindow.height)
        .background(
            WindowAccessor { window in
                // 透明标题栏 + 让 SwiftUI 内容延伸到标题栏下方
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
                window.defaultButtonCell = nil
                window.minSize = NSSize(width: DesignTokens.Size.mainWindow.width,
                                        height: DesignTokens.Size.mainWindow.height)
                window.maxSize = NSSize(width: DesignTokens.Size.mainWindow.width,
                                        height: DesignTokens.Size.mainWindow.height)
                // **毛玻璃关键**：清掉 NSWindow 自带的 windowBackgroundColor 半透明白底，
                // 否则 NSVisualEffectView(.underWindowBackground, .behindWindow) 会被它盖住，
                // 桌面无法透到 SwiftUI 里的毛玻璃上面，整张主窗口看起来只是一片浅色色块。
                window.backgroundColor = .clear
                window.isOpaque = false
                // 主窗口外框圆角（设计稿 12px）
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.cornerRadius = DesignTokens.Radius.window
                window.contentView?.layer?.masksToBounds = true
                // **避免 SwiftUI 启动时第一个 Button 自动获得焦点环**：
                // SwiftUI 主窗口首屏显示时，焦点环默认套在第一个 Button 上（这里是 RefreshButton），
                // 看着像"按钮被高亮选中"。用 `initialFirstResponder = nil` 让首焦点为空。
                window.initialFirstResponder = nil
            })
        .task {
            // 启动后立即同步探测一次 FDA 授权状态——`.task` 会在视图首次出现前异步执行，
            // 但本探测调用本身是同步的（探针只读 TCC 受保护目录的元数据，毫秒级返回），
            // 用户看不到"默认 false → 探测后变 true"的闪烁。
            refreshFDAStatus()
            await refreshDisks()
        }
        .onChange(of: store.disks) { _ in
            // 磁盘列表变化时**先**刷新 FDA（用户可能刚插了带占用进程的磁盘、也可能在系统设置里授权完了），
            // 再走 occupancy 检测。这样 FDA 横幅与磁盘列表显示同步收敛。
            refreshFDAStatus()
            Task { await detectOccupancy(for: store.disks) }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            // 每 15s 探测一次 FDA：覆盖"用户去系统设置授权后回到 app"的场景。
            // 即使没磁盘也探测（`detectOccupancy` 自身已 `guard !disks.isEmpty` 跳过）。
            refreshFDAStatus()
            if !store.disks.isEmpty {
                Task { await detectOccupancy(for: store.disks) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // **关键**：app 重新激活时（用户在系统设置授权完切回 DiskEjector）立即刷新 FDA，
            // 否则要等下一次 15s tick 才更新——用户看到横幅没消失会去系统设置重试，体验差。
            refreshFDAStatus()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// 把 FDA 授权状态同步到本地 `@State`，是 ``FdaBanner`` 显示与否的**单一闸门**。
    ///
    /// 沙盒版（MAS 分发）不需要 FDA 概念：沙盒里没有 TCC 拦截，`OccupancyResult` 直接走 `.unknown`；
    /// 此时让 `fdaAuthorized = true` 即可让 `if !fdaAuthorized` 永远不成立、横幅不出现。
    private func refreshFDAStatus() {
        if OccupancyDetector.isSandboxed {
            fdaAuthorized = true
        } else {
            fdaAuthorized = OccupancyDetector.isFullDiskAccessAuthorized()
        }
    }

    // MARK: - 子层

    /// 窗口背景层：菜单栏 panel 同款毛玻璃——``VisualEffectBackground``（NSVisualEffectView,
    /// .underWindowBackground + .behindWindow）。
    ///
    /// 通过 ``WindowAccessor`` 让 NSWindow 的 backgroundColor=.clear、isOpaque=false，
    /// 这样底层的桌面可以直接透到 NSVisualEffectView 上面，整张主窗口 = 菜单栏 panel 的同款毛玻璃。
    ///
    /// 之前用的 SwiftUI `.ultraThinMaterial` 在 macOS 14 上偏厚且被 NSWindow 半透明白底盖住，
    /// 看着像普通面板；现在改回 NSVisualEffectView，与 NSPopover 系统默认背景一致。
    private var backgroundLayer: some View {
        VisualEffectBackground()
            .ignoresSafeArea()
    }

    // MARK: - 标题栏

    /// 工具栏（macOS 红绿灯右侧：刷新 + 设置）。
    ///
    /// 设计：标准 macOS 工具栏视觉。窗口左侧让出红绿灯区，SwiftUI 内容延伸到标题栏下方；
    /// 应用名 "DiskEjector" 已移除（用户偏好：不显示冗余的应用名称——macOS 状态栏图标 + 主窗口
    /// 本身就已表达"这是哪个 app"）。
    ///
    /// **布局**：与红绿灯**同一栏**，**右侧靠右**（macOS 标准 unified titlebar 风格）。
    /// - 左：70pt 让位给 macOS 红绿灯（系统自动）
    /// - 中：Spacer 把按钮推到右侧
    /// - 右：刷新 + 设置按钮组
    ///
    /// **背景**：不单独加 `.background(...)`——让底层 ``backgroundLayer`` 的 NSVisualEffectView
    /// 毛玻璃直接透过，标题栏与下方列表共享同一张毛玻璃"纸"，跟菜单栏 panel（NSPopover 同款）
    /// 视觉一致。**底部不画 hairline**：毛玻璃统一后无需分隔，且会跟紧贴的 FdaBanner 上沿重叠成"多余横线"。
    private var titleBar: some View {
        HStack(spacing: 0) {
            // 左：让位给 macOS 红绿灯（标准 unified 标题栏自动让位）
            Color.clear.frame(width: 70)
            Spacer(minLength: 0)
            // 右：刷新 + 设置按钮组（macOS 标准工具栏位置）
            HStack(spacing: 0) {
                titleBarButton(
                    systemName: "arrow.clockwise",
                    label: L10n.tr(.refresh),
                    action: { Task { await refreshDisks() } }
                )
                .overlay {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .opacity(isRefreshing ? 0 : 1)
                .animation(DesignTokens.Motion.standard, value: isRefreshing)
                .disabled(isRefreshing)

                titleBarButton(
                    systemName: "gear",
                    label: L10n.tr(.settings),
                    action: { showSettings = true }
                )
            }
            .padding(.trailing, 12)
            // 与 macOS 红绿灯中心对齐：按钮默认在 38pt 标题栏内垂直居中，
            // 中心 y≈19；红绿灯中心 y≈14。整体上移 5pt 让两者处于同一水平基线。
            .offset(y: -5)
        }
        .frame(height: 38)
        // 不加 .background：让 backgroundLayer 的 NSVisualEffectView 透过来。
        // 不加 .overlay(.bottom hairline)：见上。
    }

    /// 标题栏 28×28 圆形按钮（设计稿 muted-foreground 文字色 + 透明背景，hover 加 muted 底）。
    private func titleBarButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        TitleBarIconButton(systemName: systemName, label: label, action: action)
    }

    // MARK: - 滚动区

    private var scrollRegion: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.disks.isEmpty {
                    EmptyStateView(
                        systemName: "externaldrive",
                        title: L10n.tr(.noRemovableDisks),
                        description: L10n.tr(.insertDiskHint),
                        actionTitle: L10n.tr(.refresh),
                        actionSystemImage: "arrow.clockwise",
                        action: { Task { await refreshDisks() } },
                        accent: accentColor
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(Array(store.disks.enumerated()), id: \.element.id) { index, disk in
                        MenuDiskRow(
                            disk: disk,
                            occupancy: occupancy[disk.id] ?? .unknown,
                            accent: accentColor,
                            onEject: { eject(disk) },
                            expandProcessTags: true,
                            showSafeToEjectCaption: true,
                            isEjecting: ejectingDiskId == disk.id,
                            hasCard: true
                        )
                        // 不用 hairline 分隔——每个 row 已经有自己的卡片边框。
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - 数据

    private func refreshDisks() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await DiskListStore.shared.refresh()
        await detectOccupancy(for: store.disks)
    }

    private func detectOccupancy(for disks: [DiskInfo]) async {
        guard !disks.isEmpty, !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }

        var results: [String: OccupancyResult] = [:]
        await withTaskGroup(of: (String, OccupancyResult).self) { group in
            for disk in disks {
                group.addTask {
                    let result = await EjectFlowController.shared.checkOccupancy(mountPath: disk.mountPath)
                    return (disk.id, result)
                }
            }
            for await (id, result) in group {
                results[id] = result
            }
        }
        occupancy = results
        // 注意：FDA 状态不在这里更新——`refreshFDAStatus()` 是单独的同步探测入口，
        // 由 `.task` / `.onChange` / 定时器 / `didBecomeActiveNotification` 驱动。
        // 这里只更新磁盘占用。
    }

    // MARK: - 推出

    private func eject(_ disk: DiskInfo) {
        ejectingDiskId = disk.id
        Task {
            let outcome = await EjectFlowController.shared.eject(disk: disk)
            ejectingDiskId = nil
            await refreshDisks()
            EjectUI.handle(outcome, disk: disk)
        }
    }
}

// MARK: - 标题栏按钮（独立子视图以便管理 @State hover 状态）

private struct TitleBarIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .frame(
                    width: DesignTokens.Size.titleBarIconButton,
                    height: DesignTokens.Size.titleBarIconButton
                )
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(hovering ? DesignTokens.Palette.mutedBackground : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **去 SwiftUI 默认 focus 环**：启动时第一个 Button 会被自动 focus，
        // 蓝色环套在 RefreshButton 上看着像"按钮被高亮选中"——但用户没点任何按钮。
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - DiskCardView（磁盘卡片，对齐"主窗口-磁盘列表"设计稿）
//
// **已迁移至 MenuDiskRow（MenuPopoverView.swift）**：
// 主窗口与菜单栏 panel 现在共用同一套行布局。`expandProcessTags: true` 让主窗口在
// 行下方展开占用进程标签，`showSafeToEjectCaption: true` 在无进程分支显示 ✓ 行。
// 旧的 `DiskCardView` + `FlowLayout` 已删除，避免双实现导致视觉不一致。
