import AppKit
import Combine
import SwiftUI

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusPopover: NSPopover!
    private var mainWindow: NSWindow!
    private var settingsWindow: NSWindow?

    private var ejectingDiskId: String?

    /// 上一次观测的偏好值，用于判断 UserDefaults 变更后是否需要真正响应。
    private var lastShowDockIcon: Bool?
    private var lastAccentColorRaw: String?
    private var lastVisualStyleRaw: String?

    /// popover 显示状态监听，关闭时按钮恢复未选中态。
    private var popoverEventMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // 诊断模式：输出环境状态与识别到的磁盘后退出。
        if CommandLine.arguments.contains("--diagnostics") {
            delegate.runDiagnostics()
            return
        }

        app.run()
    }

    /// 输出一次环境自检结果并退出。
    private func runDiagnostics() {
        let sandboxed = OccupancyDetector.isSandboxed
        let disks = DiskService.shared.fetchExternalDisks()

        print("DiskEjector 诊断报告")
        print("  沙盒状态: \(sandboxed ? "已启用（App Store 版本）" : "未启用（开发/直发版本）")")
        print("  占用检测: \(sandboxed ? "不可用，降级为「无法检测」" : "可用（lsof）")")
        print("  识别到的外置可推出卷: \(disks.count)")
        for disk in disks {
            let proto = disk.deviceProtocol ?? "未知"
            let model = disk.deviceModel.map { " (\($0))" } ?? ""
            print("    • \(disk.displayName) [\(disk.bsdName)] \(disk.mountPath)")
            print(
                "      协议: \(proto)\(model)，总容量: \(ByteFormat.string(disk.totalBytes))，已用: \(ByteFormat.string(disk.usedBytes))"
            )
        }

        if !sandboxed, !disks.isEmpty {
            print("")
            print("  占用进程检测（lsof，仅非沙盒可用）：")
            for disk in disks {
                let result = OccupancyDetector.shared.detectSync(mountPath: disk.mountPath)
                let desc: String
                switch result {
                case .occupied(let ps):
                    desc = "占用 → " + ps.map { "\($0.name)(PID \($0.pid))" }.joined(separator: ", ")
                case .needsFullDiskAccess:
                    desc = "未检测到（可能未授予完全磁盘访问，见设置引导）"
                case .unknown:
                    desc = "未知"
                case .none:
                    desc = "无占用"
                }
                print("    • \(disk.displayName): \(desc)")
            }
        }

        exit(0)
    }

    // MARK: - 启动

    /// 主菜单必须在 App 变成 active 之前装好：自建 `NSApplication` 没有 nib 主菜单，
    /// 而 ⌘W / ⌘H / ⌘Q 这些快捷键全靠主菜单里的 `keyEquivalent` 表分发（详见 `MainMenu`）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "DiskEjector") {
            NSApp.applicationIconImage = appIcon
        }

        lastShowDockIcon = UserDefaults.standard.bool(forKey: AppSettings.Key.showDockIcon)
        lastAccentColorRaw = UserDefaults.standard.string(forKey: AppSettings.Key.accentColor)
        lastVisualStyleRaw = UserDefaults.standard.string(forKey: AppSettings.Key.visualStyle)
        updateDockIconVisibility()

        LaunchAtLoginManager.syncAtLaunch()

        setupDefaultsObservation()
        setupStatusItem()
        setupMainWindow()

        maybeShowFDAOnboarding()
    }

    /// 直发版首次启动引导用户授予「完全磁盘访问」。
    private func maybeShowFDAOnboarding() {
        guard !OccupancyDetector.isSandboxed, !AppSettings.didShowFDAOnboarding else { return }
        AppSettings.didShowFDAOnboarding = true

        let alert = NSAlert()
        alert.messageText = L10n.tr(.fdaOnboardingTitle)
        alert.informativeText = L10n.tr(.fdaOnboardingBody)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr(.openSystemSettings))
        alert.addButton(withTitle: L10n.tr(.notNow))

        activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            AppSettings.openFullDiskAccessSettings()
        }
    }

    // MARK: - 状态栏

    /// 状态栏按钮：点击切换 NSPopover（与设计稿"菜单栏弹出面板"对齐：360px 宽，毛玻璃）。
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        button.toolTip = "DiskEjector"
        button.setAccessibilityLabel("DiskEjector")
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp(L10n.tr(.openMainWindow))
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))

        statusPopover = NSPopover()
        statusPopover.behavior = .transient
        statusPopover.animates = false

        // **NSStatusBarWindow 位置异常自检与重建**：
        // 当外接屏拔除 / macOS 屏幕配置变化后，NSStatusBarWindow 的 `frame` 会**残留**
        // 旧的屏幕坐标（本机实测：曾插过外接屏，拔了后 window.frame.origin.x = -3859，
        // button.window.screen = nil，window.frame 不在 NSScreen.screens 内），
        // 导致 `button.convert(_, to:).convertToScreen()` 拿到完全错误的屏幕坐标 →
        // popover 飞到屏幕外、用户看不见。
        // 销毁并重建 NSStatusItem，强制系统重新放置状态栏按钮。
        rebuildStatusItemIfOffscreen()

        // 监听屏幕配置变化：插入/拔除外接屏时主动重置状态栏位置。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` 已保证回调在主线程执行，用 assumeIsolated 把这一事实告知编译器，
            // 否则 Swift 6 严格并发会拒绝在 `@Sendable` 闭包里触碰 @MainActor 隔离的状态。
            MainActor.assumeIsolated {
                self?.rebuildStatusItemIfOffscreen()
            }
        }
    }

    /// 状态栏按钮若已不在任何屏幕内，销毁并重建 NSStatusItem。
    ///
    /// 外接屏拔除后 NSStatusBarWindow 会残留断屏前的 frame（见 `setupStatusItem` 注释），
    /// 重建可强制系统重新放置按钮，让后续所有基于屏幕坐标的计算重新可信。
    private func rebuildStatusItemIfOffscreen() {
        guard !statusItemButtonOnScreen(), let staleItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(staleItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        statusItem?.button?.toolTip = "DiskEjector"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleStatusItemClick(_:))
    }

    /// 检查当前状态栏按钮所在窗口 frame 是否与 NSScreen.screens 中任一屏相交。
    /// 不相交 → NSStatusBarWindow 仍持有断屏前的 frame，需要重建。
    private func statusItemButtonOnScreen() -> Bool {
        guard let window = statusItem?.button?.window else { return true }
        return NSScreen.screens.contains { screen in
            screen.frame.intersects(window.frame)
        }
    }

    /// 切换 popover 显示/隐藏。第二次点同一按钮会关闭。
    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        guard let popover = statusPopover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // 重新构造 contentViewController，保证引用最新 AccentColor 等设置
        let accent = AppSettings.accentColor
        let view = MenuPopoverView(
            accent: accent,
            onOpenMainWindow: { [weak self] in
                self?.statusPopover.performClose(nil)
                self?.showMainWindow()
            },
            onRefresh: {
                Task { await DiskListStore.shared.refresh() }
            },
            onOpenSettings: { [weak self] in
                self?.statusPopover.performClose(nil)
                self?.showSettings()
            },
            onQuit: { NSApplication.shared.terminate(nil) },
            onEject: { [weak self] disk in
                self?.statusPopover.performClose(nil)
                self?.eject(disk)
            }
        )
        // **定位完全交给系统，唯一要做的是先告诉它真实内容尺寸**。
        //
        // `preferredEdge` 的官方定义（Apple Docs, show(relativeTo:of:preferredEdge:)）：
        //   "The edge of positioningView the popover should prefer to be anchored to."
        // screen 坐标 y 向上，按钮在菜单栏里时 `button.minY` 是**视觉底部**，
        // 想让 popover 出现在按钮**下方** → 锚定 `.minY`。
        //
        // ⚠️ **"popover 离图标很远 / 先出现在下方再跳"的真正根因（2026-09-11 三组对照实验确认）**：
        // 若 `popover.contentSize` 在 show 时仍是 `(0,0)`——NSHostingController 的 SwiftUI
        // 内容此刻尚未布局，其 preferredContentSize 为 0——NSPopover 会**回退到默认 320×320**
        // 来计算锚点，于是 popover 顶部比按钮底部低了 `320 − 实际内容高度` pt。
        // 本机实测：内容高约 246 → 下偏 72pt，正是"离图标老远"的来源。
        //
        // 对照实验（/tmp/de_min_popover*.swift，均为教科书式 `show(preferredEdge: .minY)`）：
        //   A 显式 contentSize=360×272            → gap 0.5pt  ✓
        //   B SwiftUI 内容 + 不设 contentSize     → contentSize 变 (320,320) → gap 48.5pt  ✗
        //   C SwiftUI 内容 + show 前先布局取高度  → gap 0.5pt  ✓
        //
        // 结论：**系统定位本身是精确的**（gap 0.5pt 就是 popover 自带阴影区）。
        // 因此只需在 show 之前强制 SwiftUI 完成一次布局、把真实高度写进 contentSize，
        // 不再需要任何 snap 平移 / alpha 隐藏补偿（那套补偿才是"复杂"的来源）。
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(NSSize(width: DesignTokens.Size.menuPopoverWidth, height: 0))
        hosting.view.layoutSubtreeIfNeeded()
        let fittingSize = hosting.view.fittingSize
        // contentSize 必须在 contentViewController 之后设置，否则会被 hosting 覆盖。
        popover.contentViewController = hosting
        popover.contentSize = NSSize(
            width: DesignTokens.Size.menuPopoverWidth,
            height: max(fittingSize.height, 1)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // 防焦点环 + 让 NSPopover(.transient) hit-test 命中内部
        DispatchQueue.main.async {
            self.statusPopover.contentViewController?.view.window?.makeFirstResponder(
                self.statusPopover.contentViewController?.view
            )
        }

        // 兜底：监听全局鼠标事件。NSPopover(.transient) 理论上会自动在点击外部时关闭，
        // 但 macOS 26 + SwiftUI 组合下偶有不触发（尤其合成事件或某些外部窗口）。
        // 这里手动检查：若 popover 显示且当前鼠标位置不在 popover 窗口内，则主动关闭。
        if popoverEventMonitor == nil {
            popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in
                guard let self, let popover = self.statusPopover, popover.isShown else { return }
                let clickLocation = NSEvent.mouseLocation
                if let popoverWindow = popover.contentViewController?.view.window,
                    !popoverWindow.frame.contains(clickLocation)
                {
                    popover.performClose(nil)
                }
            }
        }
    }

    // MARK: - 偏好变更

    private func setupDefaultsObservation() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDefaultsChange() }
        }
    }

    private func handleDefaultsChange() {
        let showDockIcon = UserDefaults.standard.bool(forKey: AppSettings.Key.showDockIcon)
        if showDockIcon != lastShowDockIcon {
            lastShowDockIcon = showDockIcon
            updateDockIconVisibility()
        }

        let accentRaw = UserDefaults.standard.string(forKey: AppSettings.Key.accentColor)
        if accentRaw != lastAccentColorRaw {
            lastAccentColorRaw = accentRaw
            // 强调色变化时，让状态栏按钮 tint 与菜单栏文本色立即跟随
            applyAccentToStatusItem()
        }

        let visualRaw = UserDefaults.standard.string(forKey: AppSettings.Key.visualStyle)
        if visualRaw != lastVisualStyleRaw {
            lastVisualStyleRaw = visualRaw
            // 视觉风格变化需刷新主窗口背景（ContentView 通过 @AppStorage 自动响应）
        }
    }

    /// 依据「显示 Dock 图标」偏好切换激活策略，并在切换后把界面重新拉回前台。
    ///
    /// **关于「开关打开再关闭 → 主窗口界面闪退」的实测结论（2026-09-12，不要凭猜测改写）**：
    /// 用户报告切到菜单栏模式后主窗口界面消失。为此做了多轮真机对照实验（带设置 sheet、
    /// 切换前强制前台、CGWindowList 判在屏、A/B 两组各一），**均未能复现窗口消失**：
    /// - `setActivationPolicy(.accessory)` 前后 `NSWindow.isVisible` 恒为 true，窗口始终在
    ///   CGWindowList 的层 0 列表中，`NSApp.isActive` 也维持 true；负向对照（跳过下面这段收尾）
    ///   结果完全相同 —— 说明「策略切换把 App 踢到后台 / 把窗口挤走」在本系统上**不成立**。
    /// - 也没有任何 DiskEjector 的崩溃报告，进程始终存活。
    ///
    /// 保留这段收尾的理由是**它修复的是一个真实存在、且后果不可逆的状态**：
    /// 菜单栏模式下 App 既无 Dock 图标、也不在 ⌘Tab 列表里，一旦窗口因为任何原因
    /// （切策略、⌘M 最小化、被其它全屏 App 遮盖）离开视野，用户就**没有任何入口把它找回来**——
    /// 这正是「界面闪退」这一体验的不可恢复之处。切换后统一重新激活并前置窗口，让这种状态无法停留。
    private func updateDockIconVisibility() {
        let showDockIcon = UserDefaults.standard.bool(forKey: AppSettings.Key.showDockIcon)
        let target: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        restoreVisibleWindows()
    }

    /// 把仍然打开的窗口重新置于前台，避免激活策略切换把界面「丢」到别的应用后面。
    private func restoreVisibleWindows() {
        // `canBecomeMain` 过滤掉 NSPopover 面板、状态栏窗口等附属窗口，只处理真正的应用窗口。
        let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        guard !visible.isEmpty else { return }
        activateApp()
        for window in visible {
            window.orderFrontRegardless()
        }
        visible.first?.makeKey()
    }

    /// 激活本应用。
    ///
    /// macOS 14 起 `NSApplication.activate(ignoringOtherApps:)` 的参数已被标记为不再生效，
    /// 仅靠它无法保证抢到前台；`NSRunningApplication.activate(options:)` 才是当前有效的路径。
    /// 两条都调：前者兼容旧系统，后者覆盖 macOS 14+。
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
    }

    private func applyAccentToStatusItem() {
        guard let button = statusItem?.button else { return }
        let accent = AppSettings.accentColor.appKitColor
        button.contentTintColor = accent
    }

    // MARK: - 菜单动作

    /// ⌘H / 应用菜单里的「隐藏 DiskEjector」。
    ///
    /// 标准语义是 `NSApp.hide(_:)`，但 macOS 规定**代理类（accessory）App 无法被隐藏**：
    /// 真机实测菜单栏模式下调用后 `NSApp.isHidden` 仍为 false —— ⌘H 等于一个死键。
    /// 因此按当前激活策略分流：
    /// - 常规模式（有 Dock 图标）→ 走系统 `hide:`，行为与所有 macOS App 一致；
    /// - 菜单栏模式 → 退化为「把窗口收起来」。窗口可用菜单栏图标 →「打开主窗口」找回，
    ///   让 ⌘H 在两种模式下都有确切、可预期的行为，而不是按下去没反应。
    @objc func hideApp(_ sender: Any?) {
        if NSApp.activationPolicy() == .accessory {
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                window.orderOut(sender)
            }
        } else {
            NSApp.hide(sender)
        }
    }

    // MARK: - 推出

    /// 推出指定卷。失败/占用的弹窗统一交给 ``EjectUI`` 处理，菜单栏与主窗口共用同一套。
    private func eject(_ disk: DiskInfo) {
        ejectingDiskId = disk.id

        Task {
            let outcome = await EjectFlowController.shared.eject(disk: disk)
            ejectingDiskId = nil
            await DiskListStore.shared.refresh()
            EjectUI.handle(outcome, disk: disk)
        }
    }

    // MARK: - 主窗口

    private func setupMainWindow() {
        let win = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DesignTokens.Size.mainWindow.width,
                height: DesignTokens.Size.mainWindow.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "DiskEjector"
        win.contentView = NSHostingView(rootView: ContentView())
        win.center()
        win.minSize = NSSize(
            width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height
        )
        win.isReleasedWhenClosed = false
        mainWindow = win
    }

    /// 显示主窗口。菜单栏弹窗的「打开主窗口」、菜单里的「显示主窗口」（⌘1）与
    /// Dock 图标点击（reopen）都走这里。
    ///
    /// 必须处理**最小化态**：菜单栏模式下 App 没有 Dock 图标，⌘M 把窗口缩进 Dock 后
    /// 用户**没有任何办法点回来**（Dock 上根本没有这个 App），是一个真正的死路。
    /// 这里先 `deminiaturize` 再前置，保证这条恢复路径对「关掉」和「缩掉」两种状态都有效。
    @objc func showMainWindow() {
        if mainWindow == nil {
            setupMainWindow()
        }
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
        activateApp()
    }

    // MARK: - 设置窗口

    /// 显示设置窗口（与主窗口独立，可与主窗口共存）。
    private func showSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0,
                    width: DesignTokens.Size.settingsPanel.width,
                    height: DesignTokens.Size.settingsPanel.height
                ),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = L10n.tr(.settings)
            win.contentView = NSHostingView(rootView: SettingsView())
            win.center()
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        guard let window = settingsWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activateApp()
    }

    // MARK: - 关闭/退出

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
