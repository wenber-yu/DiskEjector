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
    /// 「完全磁盘访问」引导面板（设计稿 `04-onboarding.html`）。
    ///
    /// **它必须能在主窗口没打开时弹出来**：直发版可能被设为「只驻留菜单栏」，
    /// 那种形态下 `mainWindow` 从未创建 —— 而授权引导恰恰是首次启动时最该说的话。
    /// 所以它自己持有一个窗口，不依赖任何其它界面。
    private var onboardingWindow: NSWindow?

    /// 引导面板的宿主控制器。
    ///
    /// **单独留引用是为了能重新量高**：真机自检要断言「窗口高 == 视图量出来的高」，
    /// 从 `window.contentViewController` 转类型去拿既啰嗦又脆（根视图一旦多包一层就转不成）。
    private var onboardingHosting: NSHostingController<OnboardingView>?

    private var ejectingDiskId: String?

    /// 上一次观测的偏好值，用于判断 UserDefaults 变更后是否需要真正响应。
    private var lastShowDockIcon: Bool?
    private var lastAccentColorRaw: String?
    private var lastVisualStyleRaw: String?

    /// popover 显示状态监听，关闭时按钮恢复未选中态。
    private var popoverEventMonitor: Any?

    static func main() {
        // stdout 默认是块缓冲：重定向到文件时，`print` 的内容要等进程正常退出才落盘。
        // 而 `--preview-alerts` 是要**被外部 kill 掉**的长驻预览模式，缓冲区会一起丢掉，
        // 表现为「跑起来了一条输出都没有」。改成行缓冲后，每行 print 立即可见。
        setvbuf(stdout, nil, _IOLBF, 0)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // 诊断模式：输出环境状态与识别到的磁盘后退出。
        if CommandLine.arguments.contains("--diagnostics") {
            delegate.runDiagnostics()
            return
        }

        // 弹窗预览：把两个推出弹窗依次显示出来，供人工核对与截图。
        //
        // **为什么需要这个开关**：弹窗是自绘的（``EjectAlertPresenter`` 自己开无边框窗口），
        // 「窗口能不能成为 key、回车/Esc 有没有接上、圆角与阴影对不对」这些问题
        // 离屏出图**测不到** —— 离屏渲染的是一张图，没有窗口。
        // 真机验证必须有一条不触发真实推出的路径，否则只能拿用户的磁盘去试。
        // 注意**不能 return**：弹窗要靠 run loop 才能真正上屏并接收键盘事件，
        // 直接返回会让进程在弹窗出现前就退出（实测踩到）。
        // `--preview-alerts-keys` 是它的自动化版本：不用人手按，进程自己投递合成
        // 回车/Esc 事件走完整分发链，并按结果设置退出码（可当门槛跑）。
        let autoKeys = CommandLine.arguments.contains("--preview-alerts-keys")
        if autoKeys || CommandLine.arguments.contains("--preview-alerts") {
            delegate.runAlertPreview(autoKeys: autoKeys)
        }

        // 引导面板预览：把「完全磁盘访问」引导面板**真的上屏**。
        //
        // **为什么离屏出图不够**：离屏渲染的是一张图，**没有窗口**。而引导面板是
        // `.fullSizeContentView` + 隐藏标题的「无标题栏浮层」—— 交通灯浮在左上角
        // 那 24pt 上内边距里，会不会压住居中的图标容器、窗口高是不是真等于视图量出来的高、
        // 面板能不能成为 key（决定回车/Esc/点击是否生效），这些只有真机才知道。
        //
        // 预览**不会真的打开系统设置**，出口被换成打印语句（见 ``runOnboardingPreview``）。
        let autoOnboardingKeys = CommandLine.arguments.contains("--preview-onboarding-keys")
        if autoOnboardingKeys || CommandLine.arguments.contains("--preview-onboarding") {
            delegate.runOnboardingPreview(autoKeys: autoOnboardingKeys)
        }

        // 菜单面板预览：把状态栏面板**真的挂到状态栏按钮上、真的上屏**。
        //
        // **为什么离屏出图不够**：面板的底衬是 `NSPopover` 窗口自己的
        // `NSPopoverFrame`（一档 `.titlebar` 的 `NSVisualEffectView`），
        // 而离屏渲染里**根本没有这个窗口** —— 「材质有没有被归一化到 `.underWindowBackground`」
        // 「contentSize 是不是真实内容高」（它直接决定锚点，错了面板会离图标几十 pt）
        // 这两件事只有真机才知道。
        let autoPopoverKeys = CommandLine.arguments.contains("--preview-popover-keys")
        if autoPopoverKeys || CommandLine.arguments.contains("--preview-popover") {
            delegate.runPopoverPreview(autoKeys: autoPopoverKeys)
        }

        // 主窗口预览：把主窗口**真的上屏**。
        //
        // **为什么离屏出图不够**：主窗口是 `.fullSizeContentView` + 透明标题栏，
        // SwiftUI 会从窗口拿到一个 52pt 的**顶部安全区**。「玻璃有没有连标题栏一起铺满」
        // 离屏**结构上测不到**（离屏没有窗口就没有安全区）。实测踩过：
        // 玻璃从 `ZStack` 挪到 `.background(...)` 时丢了 `.ignoresSafeArea()`，
        // 真机上标题栏整条露出桌面，而离屏快照仍是满窗玻璃、全绿。
        let autoMainWindowKeys = CommandLine.arguments.contains("--preview-main-window-keys")
        if autoMainWindowKeys || CommandLine.arguments.contains("--preview-main-window") {
            delegate.runMainWindowPreview(autoKeys: autoMainWindowKeys)
        }

        // 设置窗口预览：把设置窗口**真的上屏**。
        //
        // **为什么离屏出图不够**：与主窗口同源 —— 设置窗口也是 `.fullSizeContentView`
        // + 透明标题栏，`NSHostingView` 会把「内容 566 + 标题栏安全区 32」当固有尺寸
        // **回推给窗口**。离屏没有窗口就没有安全区，窗口也不会被回推（实测离屏恒为 566），
        // 所以「窗口高是不是设计稿的 566」「玻璃有没有连标题栏一起铺满」两件事离屏测不到。
        //
        // 实测（2026-09-16 补齐前）：上屏后是 **440×598**，玻璃只拿到内容的 566，
        // 底部 32pt 露成平色；系统标题栏的「设置」还与面板头部的「设置」重复。
        let autoSettingsKeys = CommandLine.arguments.contains("--preview-settings-keys")
        if autoSettingsKeys || CommandLine.arguments.contains("--preview-settings") {
            delegate.runSettingsPreview(autoKeys: autoSettingsKeys)
        }

        app.run()
    }

    /// 是否处于真机预览模式（`--preview-*`）。
    ///
    /// 预览模式下**跳过正常的启动引导**：否则 `maybeShowFDAOnboarding()` 会先弹一次，
    /// 预览里那次就成了「第二次展示」，`didShowFDAOnboarding` 也被写脏 —— 输出难以判读。
    private static var isPreviewRun: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--preview-") }
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
                    // 两个名字都打出来：`displayName` 是用户在 Dock 里看到的应用名，
                    // `processName` 是 lsof 给的可执行名（如 `Bunny` / `IMVIDEO`）。
                    // 诊断时两者不一致恰恰是排查「显示的应用不对」的关键线索。
                    desc =
                        "占用 → "
                        + ps.map { "\($0.displayName)[\($0.processName)](PID \($0.pid))" }
                        .joined(separator: ", ")
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

    /// 依次预览两个推出弹窗，并把用户的选择打到终端。
    ///
    /// **只读**：用固定的假数据构造模型，不碰任何真实磁盘，也不会触发终止进程。
    /// 用途是人工核对离屏出图覆盖不到的部分 —— 窗口能否成为 key、回车/Esc 是否接上、
    /// 圆角与阴影在真实桌面上对不对。
    ///
    /// - Parameter autoKeys: `true` 时由进程自己投递合成按键，跑完即退出（退出码 0 = 全通过）。
    ///
    /// **为什么「自己投递合成按键」是可行的验证手段**：`NSEvent.keyEvent(...)` +
    /// `NSApp.postEvent(...)` 把事件投进**应用自己的事件队列**，之后的路径
    /// （`NSApplication.sendEvent` → 主菜单 key equivalent → key window 的 key equivalent
    /// → 第一响应者 → 响应链）与真实敲键**完全一致**，而且**不需要「辅助功能」权限** ——
    /// 那正是 `osascript` 合成按键报 `-10004` 时卡住的地方。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-alerts`（每关掉一个弹窗就出下一个，最后一个结束即退出）
    /// - 自动验证：`DiskEjectorApp --preview-alerts-keys`
    @MainActor
    private func runAlertPreview(autoKeys: Bool) {
        let disk = DiskInfo(
            id: "/Volumes/Preview", bsdName: "disk99s1", volumeName: "Samsung T7",
            mountPath: "/Volumes/Preview", totalBytes: 0, usedBytes: 0, freeBytes: 0,
            deviceProtocol: "USB", deviceModel: nil)
        let processes = [
            OccupyingProcess(pid: 1234, processName: "Finder", displayName: "Finder", path: ""),
            OccupyingProcess(pid: 5678, processName: "Preview", displayName: "图像捕捉", path: ""),
        ]

        Task {
            var mismatches: [String] = []

            // A · 占用弹窗：回车应落到默认按钮「关闭并推出」
            let a = await previewAlert(
                .busy(disk: disk, occupying: processes), label: "A · 占用弹窗",
                key: autoKeys ? .return : nil)
            if autoKeys, a != .closeAndEject {
                mismatches.append("A 回车应得 closeAndEject，实得 \(a)")
            }

            // B · 失败弹窗：回车应落到默认按钮「好」
            let b = await previewAlert(
                .failure(disk: disk, failure: .inUse), label: "B · 失败弹窗",
                key: autoKeys ? .return : nil)
            if autoKeys, b != .dismiss {
                mismatches.append("B 回车应得 dismiss，实得 \(b)")
            }

            // C · 再开一次失败弹窗：Esc 应走逃生出口（取消），与焦点在哪无关
            let c = await previewAlert(
                .failure(disk: disk, failure: .inUse), label: "C · 失败弹窗（Esc）",
                key: autoKeys ? .escape : nil)
            if autoKeys, c != .cancel {
                mismatches.append("C Esc 应得 cancel，实得 \(c)")
            }

            print("预览结束（未对任何真实磁盘执行操作）")

            guard autoKeys else { exit(0) }
            if mismatches.isEmpty {
                print("✅ 按键路径自检通过：回车 → 默认按钮，Esc → 取消")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 自检要投递的按键（只覆盖弹窗用到的两个）。
    private enum PreviewKey {
        case `return`
        case escape

        /// `(keyCode, characters)` —— 键码取自 `HIToolbox/Events.h`（kVK_Return = 36 / kVK_Escape = 53）。
        var event: (code: UInt16, chars: String) {
            switch self {
            case .return: return (36, "\r")
            case .escape: return (53, "\u{1b}")
            }
        }
    }

    /// 显示一个弹窗；`key` 非空时在它上屏后投递该按键，最后返回用户（或按键）做出的选择。
    @MainActor
    private func previewAlert(
        _ model: EjectAlertModel, label: String, key: PreviewKey?
    ) async -> EjectAlertChoice {
        // 先起一个不 await 的任务把弹窗挂上去，再等它**真正成为 key window** 后才自检。
        //
        // **不能只 sleep 一个固定时长**：`makeKeyAndOrderFront` 是异步生效的，而「上屏」到
        // 「抢到焦点」之间还有一段窗口期 —— 实测固定 sleep 700ms 时，第二个弹窗偶尔正好
        // 落在窗口期里，打印出 `key=false`，可它的回车明明是生效的，输出自相矛盾。
        let pending = Task { await EjectAlertPresenter.shared.present(model) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await waitUntilAlertIsKey()
        EjectAlertPresenter.shared.dumpWindowState(label: label)
        if let key { postKey(key) }
        let choice = await pending.value
        print("\(label) → \(choice)")
        return choice
    }

    /// 等到弹窗真正成为 key window（最多等 1.5 秒）。
    @MainActor
    private func waitUntilAlertIsKey() async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !EjectAlertPresenter.shared.isKeyWindow {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 把一次完整的按键（down + up）投进应用自己的事件队列。
    ///
    /// **为什么 down 和 up 都要投**：AppKit 的按键处理挂在 `keyDown` 上，只投 `keyDown`
    /// 也能触发；补上 `keyUp` 是为了让队列状态与真实敲键一致，避免残留的 down 事件
    /// 让后续窗口收到「按键卡住」的假象。
    @MainActor
    private func postKey(_ key: PreviewKey) {
        let (code, chars) = key.event
        let stamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: stamp,
                    windowNumber: 0, context: nil, characters: chars,
                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    // MARK: - 启动

    /// 主菜单必须在 App 变成 active 之前装好：自建 `NSApplication` 没有 nib 主菜单，
    /// 而 ⌘W / ⌘H / ⌘Q 这些快捷键全靠主菜单里的 `keyEquivalent` 表分发（详见 `MainMenu`）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: L10n.tr(.appName)) {
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

        if !Self.isPreviewRun { maybeShowFDAOnboarding() }
    }

    /// 直发版首次启动引导用户授予「完全磁盘访问」。
    ///
    /// **只在首次启动弹一次**：`didShowFDAOnboarding` 记住「已经说过」。
    /// 之后若用户仍未授权，主窗口顶部会留一条琥珀横幅（`NoticeBanner.warning`），
    /// 不再打断 —— 拒绝授权不等于功能失效，磁盘照样能推出，只是看不到占用者。
    ///
    /// 沙箱版（App Store）跳过：沙箱里本来就没有 FDA 这回事。
    private func maybeShowFDAOnboarding() {
        guard !OccupancyDetector.isSandboxed, !AppSettings.didShowFDAOnboarding else { return }
        AppSettings.didShowFDAOnboarding = true
        showOnboarding()
    }

    /// 打开「完全磁盘访问」引导面板（设计稿 `04-onboarding.html`）。
    ///
    /// **为什么是独立窗口而不是 `NSAlert`**：设计稿这块面板有居中图标容器、
    /// 三步编号 + 连接线、行内等宽路径小标、信息提示块，`NSAlert` 一样都给不了。
    /// 另外 `runModal()` 会**阻塞主线程**：授权引导是「跨应用的任务」，
    /// 用户要离开本应用去系统设置操作、再回来 —— 期间应用必须是活的。
    ///
    /// 装配方式与 ``showSettings()`` 同款（`NSHostingController` + 独立窗口），
    /// 区别是内容高由视图自己量出来（设计稿面板高随文案变化，宽固定 380）。
    ///
    /// - Parameter onExit: 面板两个出口的处理方式。为 `nil` 时走**真实行为**
    ///   （打开系统设置 / 关窗）；真机自检传自己的实现，以便观测「合成按键到底走了哪个出口」，
    ///   而不会真的去打开系统设置。
    @discardableResult
    private func showOnboarding(onExit: ((OnboardingExit) -> Void)? = nil) -> NSWindow? {
        onboardingExitHandler = onExit
        if onboardingWindow == nil {
            let root = OnboardingView(
                accent: AppSettings.accentColor,
                // 「打开系统设置」**不关窗**：用户接下来要去系统设置里翻找并开启开关，
                // 三步说明得留在屏幕上给他对照（设计稿的「三步带编号与连接线」正是
                // 为了让他中断之后能接上）。关掉它，用户回来就只剩一个空列表。
                onOpenSettings: { [weak self] in self?.handleOnboardingExit(.openSettings) },
                onLater: { [weak self] in self?.handleOnboardingExit(.later) }
            )
            let panel = Self.makeOnboardingPanel(root: root)
            onboardingWindow = panel.window
            onboardingHosting = panel.hosting
        }
        guard let window = onboardingWindow else { return nil }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activateApp()
        return window
    }

    /// 组装承载引导面板的窗口。
    ///
    /// 设为 `internal`（而非 `private`）是为了让单测能直接断言窗口配置与尺寸 ——
    /// 与 ``EjectAlertPresenter/makePanel(hosting:height:title:)`` 同一个理由：
    /// 这几行里每一条去掉都会**静默**劣化，而任何一条都不会让别的断言变红：
    /// - 少了 `safeAreaRegions = []` → 内容被标题栏安全区**整体下推 32pt**
    ///   （设计稿 24pt 的上内边距变成 56pt，窗口也被撑到 532 高）；
    /// - 少了 `isReleasedWhenClosed = false` → 关掉面板后留下悬垂引用；
    /// - 少了 `titleVisibility = .hidden` → 面板顶上多一条标题栏。
    ///
    /// **单测只断言配置与尺寸，不真的 `makeKeyAndOrderFront`** —— 那会抢走用户焦点。
    /// 「真的上屏、能不能成为 key、回车/Esc 通不通」交给 `--preview-onboarding` 真机自检。
    static func makeOnboardingPanel(
        root: OnboardingView
    ) -> (window: NSWindow, hosting: NSHostingController<OnboardingView>) {
        let width = DesignTokens.Size.onboardingPanelWidth
        let hosting = NSHostingController(rootView: root)

        // **必须关掉容器的安全区**。
        //
        // `.fullSizeContentView` 的窗口会告诉 SwiftUI「顶部这 32pt 被标题栏占着」，
        // 于是 SwiftUI 把内容**整体下推 32pt**。`--preview-onboarding-keys` 实测到的是
        // 「窗口 380×532、安全区 top=32、内容布局区 380×500」—— 而设计稿是 380×503。
        //
        // **这件事离屏出图结构上测不到**：离屏渲染的视图没有窗口，也就没有安全区，
        // 量出来正好 500（看着完全正确）。只有把窗口真的开出来才会露出来。
        //
        // **主窗口后来也改成了这条路子**（`makeMainWindow` 里同样关掉安全区 —— 一句就够）。
        //
        // 这里曾经写着「主窗口走的是另一条**等价**路子（`ContentView` 自己 `.ignoresSafeArea()`
        // 再画 52pt 标题栏）」—— **那个「等价」判断是错的，并且是主窗口那个 bug 的认知源头**：
        // `.ignoresSafeArea()` 只改内容排版，**不改窗口尺寸**，`sizeThatFits` / 固有尺寸仍会把
        // 32pt 加进去，窗口照样被撑高。代价是主窗口长期停在 800×552（设计稿 520），
        // 玻璃只拿到内容的 520，顶部 32pt 露出桌面（2026-09-15 用户截图报告）。
        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }

        // 高度用 `sizeThatFits(in:)` 量 —— 它会带上「宽 380」这个约束；
        // `fittingSize` 不认宽度约束，会把内容按理想宽度排版（实测会矮一截）。
        let height = hosting.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height

        let win = KeySilentWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            // `.fullSizeContentView` + 隐藏标题：设计稿的面板是**无标题栏**的浮层，
            // 内容高就是面板高。交通灯按钮浮在左上角那块 24pt 的上内边距里
            // （图标容器是居中的，横向不会撞上）。
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = L10n.tr(.fdaOnboardingTitle)
        win.contentViewController = hosting
        // **这一句不是冗余，删不得**：赋 `contentViewController` 会把窗口 frame
        // **清成 0×0**（实测，且 `layoutIfNeeded()` 之后仍是 0），上面 `contentRect`
        // 传的高度会被丢掉。少了它，面板就是一个 0 高的空窗口 ——
        // 不报错、不崩溃，只是什么都没有。
        // `OnboardingWindowTests.挂上控制器后必须重新定尺寸` 把这个对照实验钉住了。
        win.setContentSize(NSSize(width: width, height: height))
        win.center()
        // 面板被关掉后还要能被再次打开（`showOnboarding` 是可重复调用的），
        // 默认的 `true` 会在 close 时把窗口释放掉，留下悬垂引用。
        win.isReleasedWhenClosed = false
        return (win, hosting)
    }

    /// 引导面板的两个出口。
    ///
    /// **为什么要把它变成类型而不是两个裸闭包**：真机自检要断言「合成按键到底触发了哪个出口」，
    /// 得能比较、能打印。裸闭包只能记一个布尔。
    enum OnboardingExit: Equatable {
        /// 主按钮「打开系统设置」。
        case openSettings
        /// 次按钮「稍后」（Esc 也走这里）。
        case later

        var name: String {
            switch self {
            case .openSettings: return "打开系统设置"
            case .later: return "稍后"
            }
        }
    }

    /// 引导面板出口的处理方式。
    ///
    /// **做成属性而不是在建窗时把闭包捕获进去**：窗口是复用的（`onboardingWindow` 只建一次），
    /// 而真机自检要「同一个窗口、先后走两个出口」—— 捕获进视图的闭包换不了。
    /// 为 `nil` 时走真实行为。
    private var onboardingExitHandler: ((OnboardingExit) -> Void)?

    private func handleOnboardingExit(_ exit: OnboardingExit) {
        if let handler = onboardingExitHandler {
            handler(exit)
            return
        }
        switch exit {
        case .openSettings: AppSettings.openFullDiskAccessSettings()
        case .later: onboardingWindow?.close()
        }
    }

    // MARK: - 引导面板真机自检

    /// 把引导面板真的上屏，核对离屏出图覆盖不到的部分，并把面板走了哪个出口打到终端。
    ///
    /// **只读**：不碰任何磁盘；出口被换成记录，**不会真的打开系统设置**。
    ///
    /// - Parameter autoKeys: `true` 时自己投递合成按键（回车 → 「打开系统设置」、Esc → 「稍后」），
    ///   跑完即退出（退出码 0 = 全通过）。`false` 时把面板留在屏幕上供人工核对，**不自动退出**。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-onboarding`
    /// - 自动验证：`DiskEjectorApp --preview-onboarding-keys`
    ///
    /// **注意不能 `return` 掉整个 `main()`**（与 `--preview-alerts` 同理）：面板要靠 run loop
    /// 才能真正上屏并接收键盘事件，直接返回会让进程在面板出现前就退出。
    @MainActor
    private func runOnboardingPreview(autoKeys: Bool) {
        var exits: [OnboardingExit] = []
        let record: (OnboardingExit) -> Void = { exits.append($0) }

        guard let window = showOnboarding(onExit: record) else {
            print("❌ 引导面板窗口没有建起来")
            exit(1)
        }

        Task {
            var mismatches: [String] = []

            await waitUntilOnboardingIsKey()
            dumpOnboardingWindowState(label: "A · 引导面板", window: window, mismatches: &mismatches)

            guard autoKeys else {
                // 人工核对模式：面板**留在屏幕上**，用户按回车 / Esc / 点按钮都会打出来。
                // 这里才换上「真实行为」的出口（关窗），让手感与线上一致；
                // 但「打开系统设置」仍只打印 —— 预览不该真的去动系统设置。
                self.onboardingExitHandler = { [weak self] exit in
                    print("  → 出口：\(exit.name)")
                    if exit == .later { self?.onboardingWindow?.close() }
                }
                print("人工核对模式：面板已上屏（本模式不会真的打开系统设置）。")
                print("  回车 → 应打印「打开系统设置」；Esc / 点「稍后」 → 应打印「稍后」并关窗。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            // B · 回车应落到默认按钮「打开系统设置」
            postKey(.return)
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("B · 回车 → \(exits.map(\.name).joined(separator: "、"))")
            if exits != [.openSettings] {
                mismatches.append("B 回车应得 [打开系统设置]，实得 [\(exits.map(\.name).joined(separator: "、"))]")
            }

            // C · Esc 应落到次按钮「稍后」—— 逃生口不能有前提条件，与焦点在哪无关。
            // 面板**不关**（预览的出口只是记录），所以这里能直接复用同一个窗口再来一次。
            exits.removeAll()
            _ = showOnboarding(onExit: record)
            await waitUntilOnboardingIsKey()
            postKey(.escape)
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("C · Esc → \(exits.map(\.name).joined(separator: "、"))")
            if exits != [.later] {
                mismatches.append("C Esc 应得 [稍后]，实得 [\(exits.map(\.name).joined(separator: "、"))]")
            }

            print("预览结束（未对任何真实磁盘执行操作，也未真的打开系统设置）")
            if mismatches.isEmpty {
                print("✅ 引导面板真机自检通过：窗口尺寸与视图一致、交通灯不压内容、回车 → 主按钮、Esc → 「稍后」")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 把引导面板窗口的状态打到终端，并就地核对几件**只有真机才知道**的事。
    ///
    /// 四个断言都不是「看着对」，而是各有明确后果：
    /// 1. 宽必须是设计稿的 380 —— 说明文字是居中的两段，宽度飘了断行就飘，
    ///    第 1 步那个实测 226pt 的路径小标也会折行；
    /// 2. 窗口高必须 ≈ 视图量出来的高 —— 否则底部按钮被裁掉或下面多一块空白。
    ///    容差 1.5pt：AppKit 会把内容尺寸向上取整到整点（实测 499.95 → 500、500.45 → 501）；
    /// 3. 窗口高必须 ≈ 设计稿的 503.3 —— **这条是标题栏安全区那个 bug 的捕手**。
    ///    当时窗口被撑到 532（内容被下推 32pt），而第 2 条因为两边都含安全区反而是绿的：
    ///    「窗口高 == 视图量高」是必要条件，不是充分条件；
    /// 4. 交通灯（浮在内容之上的 `.fullSizeContentView` 标题栏）不能压住顶部图标容器 ——
    ///    横向分开是**算出来的**（图标容器居中 x 164…216、交通灯在最左），不是设计稿写死的，
    ///    所以每次真机自检都验一遍。
    @MainActor
    private func dumpOnboardingWindowState(
        label: String, window: NSWindow, mismatches: inout [String]
    ) {
        let width = DesignTokens.Size.onboardingPanelWidth
        // 与 `makeOnboardingPanel` 里建窗时**同一份量法**（同一个控制器、同一个宽约束）：
        // 两边不一致的话这条断言就没有意义。先布局一次再量，避免约 0.5pt 的抖动。
        onboardingHosting?.view.layoutSubtreeIfNeeded()
        let measured =
            onboardingHosting?.sizeThatFits(
                in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            ).height ?? 0

        print(
            "  \(label)：key=\(window.isKeyWindow) 上屏=\(window.isVisible) "
                + "可成为key=\(window.canBecomeKey) 无标题栏=\(window.titleVisibility == .hidden) "
                + "尺寸=\(window.frame.width)×\(window.frame.height) "
                + "视图量高=\(measured) 窗口号=\(window.windowNumber) 应用前台=\(NSApp.isActive)"
        )
        if let hosting = onboardingHosting {
            print(
                "    内容视图高=\(hosting.view.frame.height) "
                    + "安全区=\(hosting.view.safeAreaInsets) "
                    + "内容布局区=\(window.contentLayoutRect)"
            )
        }

        if abs(window.frame.width - width) > 0.5 {
            mismatches.append("A 面板宽应为 \(width)，实得 \(window.frame.width)")
        }
        if abs(window.frame.height - measured) > 1.5 {
            mismatches.append("A 窗口高 \(window.frame.height) 与视图量出的 \(measured) 不一致")
        }
        // 与版式契约测试同一个口径（设计稿 503.3、容差 ±4，差异来自 Blink 把行内元素
        // 的垂直内边距算进行盒高度 —— 详见 `OnboardingLayoutTests.面板总高与设计稿相差不超过4`）。
        // **这条断言正是安全区那个 bug 的捕手**：当时窗口被撑到 532，比设计稿高 28.7，
        // 而「窗口高 == 视图量高」那条因为两边都含安全区，反而是绿的。
        if abs(window.frame.height - 503.3) > 4 {
            mismatches.append("A 窗口高 \(window.frame.height) 偏离设计稿 503.3 超过 4")
        }

        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(NSRect.null) { $0.union($1) }
        guard !lights.isNull else { return }

        // 图标容器在窗口坐标里的位置（窗口原点在左下，所以 y 要从顶部往下折算）。
        let icon = DesignTokens.Size.onboardingIconContainer
        let iconRect = NSRect(
            x: (width - icon) / 2,
            y: window.frame.height - DesignTokens.Spacing.xxl - icon,
            width: icon, height: icon)
        if lights.intersects(iconRect) {
            mismatches.append("A 交通灯 \(lights) 压住了顶部图标容器 \(iconRect)")
        }
    }

    /// 等到引导面板真正成为 key window（最多等 1.5 秒）。
    ///
    /// **不能只 sleep 一个固定时长**：`makeKeyAndOrderFront` 是异步生效的，
    /// 「上屏」到「抢到焦点」之间还有一段窗口期（详见 ``previewAlert`` 的注释）。
    @MainActor
    private func waitUntilOnboardingIsKey() async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !(onboardingWindow?.isKeyWindow ?? false) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - 菜单面板真机自检

    /// 把状态栏面板真的挂到状态栏按钮上、真的上屏，核对**离屏出图覆盖不到**的部分。
    ///
    /// **为什么需要它**：面板的底衬是 `NSPopover` 窗口自己的 `NSPopoverFrame`
    /// （一档 `.titlebar` 的 `NSVisualEffectView`）。离屏渲染里**根本没有这个窗口**，
    /// 所以「材质有没有被归一化到 `.underWindowBackground`」在离屏测试里永远是绿的 ——
    /// 哪怕 `normalizeBackdropMaterial()` 一个视图都没找到。
    /// 同理，`contentSize` 是不是真实内容高只有上屏后才知道，而它直接决定锚点
    /// （错了面板会离图标几十 pt，见 ``showStatusPopover(anchoredTo:)`` 里的三组对照实验）。
    ///
    /// **只读**：面板动作出口被换成记录，不会真的打开主窗口/设置、不会退出、不会推出任何盘。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-popover`（面板留在屏幕上，核对完 ⌘Q）
    /// - 自动验证：`DiskEjectorApp --preview-popover-keys`（跑完即退出，退出码 0 = 全通过）
    ///
    /// **注意不能 `return` 掉整个 `main()`**（与其它 `--preview-*` 同理）：
    /// 面板要靠 run loop 才能真正上屏、才会建好视图树。
    @MainActor
    private func runPopoverPreview(autoKeys: Bool) {
        var fired: [MenuPopoverAction.Kind] = []
        popoverActionHandler = { fired.append($0) }

        setupStatusItem()
        guard let button = statusItem?.button else {
            print("❌ 状态栏按钮没有建起来")
            exit(1)
        }

        Task {
            var mismatches: [String] = []

            // 等状态栏按钮真的被系统放进一个可见窗口里。
            //
            // **为什么必须等**：`NSPopover.show(relativeTo:of:)` 要求锚点视图在一个
            // **可见窗口**内，而 `NSStatusBarWindow` 是系统在应用启动完成后**异步**放置的。
            // 预览是在 `main()` 里抢先建的（早于 `app.run()`），抢跑的结果是 `show` **静默**
            // 什么都不做 —— 实测第一版 `isShown` 恒为 false，且没有任何报错。
            await waitUntilStatusButtonIsOnScreen()
            // `.accessory`（只驻留菜单栏）形态下应用不在前台，popover 不会上屏。
            // **`activate` 是异步生效的**：调用后立刻 `show` 仍然会失败（实测），
            // 必须等 `isActive` 真的变 true。
            NSApp.activate(ignoringOtherApps: true)
            await waitUntilAppIsActive()

            showStatusPopover(anchoredTo: button)
            // 材质归一化依赖「窗口已上屏、视图树已建好」，而那是异步的 ——
            // `showStatusPopover` 里那次 `DispatchQueue.main.async` 也要等下一个 runloop。
            // 用固定等待而不是轮询：这里等的不是某个布尔量，而是**窗口建树完成**，
            // 没有可直接观测的谓词。600ms 在实测里足够（上屏通常 <100ms）。
            try? await Task.sleep(nanoseconds: 600_000_000)

            dumpPopoverState(label: "A · 菜单面板", mismatches: &mismatches)

            guard autoKeys else {
                print("人工核对模式：面板已上屏（本模式不会真的打开主窗口/设置，也不会退出）。")
                print("  核对要点：面板底衬与主窗口是否为同一块玻璃；面板是否紧贴菜单栏图标下方。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            // B · 面板上的动作真的接上了（出口被换成记录，不会产生副作用）
            fired.removeAll()
            handlePopoverAction(.refreshDisks)
            print("B · 触发「刷新磁盘列表」→ \(fired.map(\.rawValue).joined(separator: "、"))")
            if fired != [.refreshDisks] {
                mismatches.append("B 应得 [refreshDisks]，实得 [\(fired.map(\.rawValue).joined(separator: "、"))]")
            }

            print("预览结束（未对任何真实磁盘执行操作，也未真的打开任何窗口）")
            if mismatches.isEmpty {
                print("✅ 菜单面板真机自检通过：面板上屏、底衬材质与主窗口同档、contentSize 等于真实内容高")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 等到状态栏按钮所在窗口真的可见（最多 3 秒）。
    ///
    /// 判据是「窗口存在 + `isVisible` + `windowNumber > 0`」三个一起看：
    /// 只看 `window != nil` 会过早通过（窗口对象先于上屏存在，此时 `show` 仍会静默失败），
    /// 而 `windowNumber` 是系统真正把窗口登记进窗口服务器之后才有的。
    @MainActor
    private func waitUntilStatusButtonIsOnScreen() async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let window = statusItem?.button?.window, window.isVisible, window.windowNumber > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("⚠️ 状态栏按钮 3 秒内没有上屏 —— 面板大概会挂不上（本机没有可用状态栏？）")
    }

    /// 等应用真的变成前台（最多 2 秒）。
    ///
    /// `NSApp.activate(ignoringOtherApps:)` 只是**请求**激活，真正生效要等下一次
    /// 激活通知；而 `NSPopover.show` 在应用不在前台时会**静默失败**（`isShown` 保持 false）。
    @MainActor
    private func waitUntilAppIsActive() async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !NSApp.isActive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 把面板窗口的状态打到终端，并就地核对几件**只有真机才知道**的事。
    ///
    /// 四条断言各有明确后果：
    /// 1. 面板必须真的上屏 —— 否则后面每一条都是在测一个不存在的窗口；
    /// 2. `contentSize.width` 必须 = 设计稿的 360（`02-menu-bar.html` 的 `.win--popover`）。
    ///    ⚠️ **不能拿窗口 frame 宽去比 360**：popover 的窗口框 = 内容尺寸 + 箭头 + 一圈阴影，
    ///    实测 386×306（360×280 + 四边各 13），拿 386 去比 360 会误报；
    /// 3. `contentSize.height` 必须 ≈ 视图自己量出来的高 —— 这条是**锚点的捕手**：
    ///    `NSPopover` 用 `contentSize` 算锚点，取到 0 会回退到默认 320×320，
    ///    面板因此离图标下偏几十 pt（实测过 72pt）；
    /// 4. 底衬材质必须是 `.underWindowBackground`（rawValue 21）——
    ///    系统默认给的是 `.titlebar`（rawValue 0），两者不是同一块玻璃。
    ///    这条**只有真机才有牙**：离屏渲染里没有 popover 窗口，永远查不出。
    @MainActor
    private func dumpPopoverState(label: String, mismatches: inout [String]) {
        guard let popover = statusPopover else {
            mismatches.append("A 面板对象不存在")
            return
        }
        let window = popover.contentViewController?.view.window
        // ⚠️ **只读**取材质：这里绝不能调 `normalizeBackdropMaterial()` —— 它会顺手把材质
        // 改好，断言就永远为真了（自证陷阱）。见 ``NSPopover/backdropMaterial``。
        let material = popover.backdropMaterial
        let contentHeight = popover.contentViewController?.view.fittingSize.height ?? 0

        print(
            "  \(label)：上屏=\(popover.isShown) 窗口=\(window?.frame.width ?? -1)×\(window?.frame.height ?? -1) "
                + "contentSize=\(popover.contentSize.width)×\(popover.contentSize.height) "
                + "视图量高=\(contentHeight) 底衬材质=\(material.map { "\($0.rawValue)" } ?? "未找到") "
                + "窗口号=\(window?.windowNumber ?? -1) 应用前台=\(NSApp.isActive) "
                + "锚点窗口号=\(statusItem?.button?.window?.windowNumber ?? -1)"
        )

        if !popover.isShown {
            // 最常见的成因是「应用不在前台」—— `NSPopover.show` 在这种情况下**静默失败**。
            // 把这条线索直接写进失败信息，省得下次又去查材质。
            let hint = NSApp.isActive ? "" : "（应用不在前台，`show` 会静默失败）"
            mismatches.append("A 面板没有上屏（isShown=false）\(hint)")
        }
        if abs(popover.contentSize.width - DesignTokens.Size.menuPopoverWidth) > 0.5 {
            mismatches.append(
                "A 面板内容宽应为 \(DesignTokens.Size.menuPopoverWidth)，实得 \(popover.contentSize.width)")
        }
        if abs(popover.contentSize.height - contentHeight) > 1 {
            mismatches.append(
                "A contentSize 高 \(popover.contentSize.height) 与视图量高 \(contentHeight) 不一致 —— "
                    + "面板会被锚错位置")
        }
        if let material, material != .underWindowBackground {
            mismatches.append(
                "A 底衬材质是 \(material.rawValue)，应被归一化为 .underWindowBackground(21)")
        } else if material == nil {
            mismatches.append("A 没有找到 popover 的底衬 NSVisualEffectView —— 材质没被归一化")
        }
    }

    // MARK: - 主窗口真机自检

    /// 把主窗口真的上屏，核对**离屏出图覆盖不到**的部分。
    ///
    /// **为什么需要它**：主窗口是 `.fullSizeContentView` + 透明标题栏，
    /// SwiftUI 因此会从窗口拿到一个 **32pt 的顶部安全区**（`DesignTokens.Size.titleBarHeight`
    /// 的 52pt 是 `ContentView` 自己画的内容带，两回事）。
    /// 「玻璃有没有连标题栏一起铺满」「窗口高是不是设计稿的 520」这两件事离屏**结构上测不到** ——
    /// 离屏没有窗口就没有安全区，`NSHostingView` 也不会把固有尺寸回推给窗口
    /// （实测离屏窗口恒为 520）。
    /// 实测踩过：`GlassSurface` 从 `ZStack` 挪到 `.background(...)` 时丢了 `.ignoresSafeArea()`，
    /// **真机上标题栏整条露出桌面**，而离屏快照 `main-window-light.png` 仍是满窗玻璃、全绿。
    /// 后来查明根因是两层：窗口被 `sizingOptions` 撑到 552（旧版就有，一直没量过），
    /// 玻璃又只拿到内容的 520。两处修法见 ``makeMainWindow()``。
    ///
    /// **只读**：不动任何磁盘、不写偏好。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-main-window`（窗口留在屏幕上，核对完 ⌘Q）
    /// - 自动验证：`DiskEjectorApp --preview-main-window-keys`（跑完即退出，退出码 0 = 全通过）
    @MainActor
    private func runMainWindowPreview(autoKeys: Bool) {
        Task {
            var mismatches: [String] = []

            showMainWindow()
            NSApp.activate(ignoringOtherApps: true)
            await waitUntilAppIsActive()
            // 等窗口上屏并把 SwiftUI 的视图树建好（玻璃是 `NSViewRepresentable`，
            // 要等 AppKit 那一层真的建出来才找得到）。
            try? await Task.sleep(nanoseconds: 600_000_000)

            dumpMainWindowState(label: "A · 主窗口", mismatches: &mismatches)

            guard autoKeys else {
                print("人工核对模式：主窗口已上屏（本模式不会推出任何磁盘）。")
                print("  核对要点：")
                print("    ① 标题栏（红绿灯那一条）是否与下方内容共用同一张玻璃 ——")
                print("       若标题栏露出桌面/其它窗口，说明玻璃没有铺满整窗；")
                print("    ② 标题「外置磁盘」的视觉中线，是否与左边三个红绿灯的圆心在同一水平线上。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            print("预览结束（未对任何真实磁盘执行操作）")
            if mismatches.isEmpty {
                print("✅ 主窗口真机自检通过：窗口 800×520、玻璃覆盖整窗（含标题栏）、标题与交通灯同一基线")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    // MARK: - 交通灯基线

    /// 系统交通灯在**窗口坐标**里的并集（原点在左下）。
    ///
    /// 三个按钮各自 `convert(_:to: nil)` 到窗口坐标后再求并集 —— 它们的父视图是
    /// `NSThemeFrame`，直接读 `frame` 拿到的是标题栏容器坐标系，与窗口坐标**不是一回事**
    /// （实测差一个标题栏高度，会把「距顶 16pt」算成「距顶 550pt」）。
    private func trafficLightUnion(in window: NSWindow) -> NSRect {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(NSRect.null) { $0.union($1) }
    }

    /// 核对「系统交通灯的垂直中心」与「标题栏内容带的中心」是否重合，并打印数字。
    ///
    /// **为什么这条断言必须存在**：交通灯的位置由 AppKit 决定，而内容带高度
    /// ``DesignTokens/Size/titleBarBandHeight`` 是**设计稿给的** 52。两边靠
    /// ``alignTrafficLights(in:)`` 主动对齐 —— 那是一次「改系统按钮 frame」的操作，
    /// AppKit 哪天改了行为（或某个 macOS 把灯挪了），代码不会自己知道 ——
    /// 只有真机量一遍才会红。
    /// 而**离屏出图结构上测不到**这件事：离屏没有窗口，也就没有交通灯。
    ///
    /// 断言的是**两个数**：交通灯中心距窗口顶的距离，与内容带高度的一半。
    /// 前者不对时，把 ``DesignTokens/Size/systemTrafficLightCenterFromTop``
    /// 改成失败信息里的实测值即可。
    ///
    /// - Returns: 交通灯并集（取不到时为 `.null`），供调用方接着做横向判断。
    @discardableResult
    private func checkTrafficLightBaseline(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> NSRect {
        let lights = trafficLightUnion(in: window)
        guard !lights.isNull else {
            mismatches.append("\(label) 取不到交通灯位置（standardWindowButton 全为 nil）")
            return .null
        }
        // 窗口坐标原点在左下 → 「距顶」= 窗口高 − y。
        let centerFromTop = window.frame.height - lights.midY
        let band = DesignTokens.Size.titleBarBandHeight
        let expected = band / 2
        print("    交通灯并集=\(lights) 垂直中心距顶=\(centerFromTop)pt（内容带 \(band)pt 的中心应为 \(expected)pt）")
        if abs(centerFromTop - expected) > 1 {
            mismatches.append(
                "\(label) 交通灯垂直中心距顶 \(centerFromTop)pt，内容带中心 \(expected)pt，"
                    + "相差 \(centerFromTop - expected)pt —— 标题与红绿灯不在同一条基线上。"
                    + "对齐是**幂等**的（``alignTrafficLights(in:)`` 量出当前位置再补差额），"
                    + "所以这里红通常意味着它没被调用，或被后续布局拨回 —— "
                    + "检查调用时机，而不是去改某个补偿常量")
        }
        return lights
    }

    /// 核对「红灯中心距窗口左边」与「设置按钮中心距窗口右边」是否**对称**。
    ///
    /// **为什么这条断言必须存在**：红灯的位置由 AppKit 决定（我们只在竖直方向挪过它，
    /// 见 ``alignTrafficLights(in:)``），设置按钮的位置由 SwiftUI 的 `padding` 决定 ——
    /// **两边来源不同**，凭印象对齐一定会对错。设计稿 DOM 探针实测（2026-09-17）：
    /// 红灯中心距左 **26.5pt**、设置按钮中心距右 **26.5pt**，即设计意图是**镜像对称**。
    ///
    /// ⚠️ **不要拿「按钮盒边缘」去比「圆点边缘」** —— 红灯是 12pt 圆点，
    /// 设置按钮是 28pt 的盒（里面 14pt 图标）。盒边缘距边 12.5、圆点边缘距边 20.5，
    /// 看着差 8pt，但**光学上是齐的**。判据只能用**中心**。
    ///
    /// - Returns: `红灯中心距左 − 设置按钮中心距右`，供调用方接着判断。
    @discardableResult
    private func checkTitleBarHorizontalSymmetry(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> CGFloat {
        guard let close = window.standardWindowButton(.closeButton) else {
            mismatches.append("\(label) 取不到关闭按钮（红灯），无法核对水平对称")
            return .nan
        }
        // `NSTitlebarView` 的坐标与窗口一致（原点左下），x 方向不用翻转。
        let light = close.convert(close.bounds, to: nil)
        let lightCenter = light.midX
        // 设置按钮是 SwiftUI 画的，布局是确定的，不必量渲染：
        // 右边距（trailing padding）+ 28pt 按钮盒的一半。
        let gearCenter =
            DesignTokens.Spacing.titleBarTrailing + DesignTokens.Size.titleBarIconButton / 2
        let delta = lightCenter - gearCenter
        print(
            "    红灯中心距左=\(lightCenter)pt（按钮 frame=\(light)） "
                + "设置按钮中心距右=\(gearCenter)pt 差=\(delta)pt")
        if abs(delta) > 1 {
            mismatches.append(
                "\(label) 标题栏左右不对称：红灯中心距左 \(lightCenter)pt，"
                    + "设置按钮中心距右 \(gearCenter)pt，相差 \(delta)pt。"
                    + "设计稿两侧都是 \(DesignTokens.Size.titleBarInsetCenter)pt —— "
                    + "调 DesignTokens.Spacing.titleBarTrailing 或 "
                    + "DesignTokens.Size.systemTrafficLightCenterFromLeft 使其相等")
        }

        // **绝对断言兜底**：上面比的两个数里，红灯那个是我们自己改出来的 frame ——
        // 同源比较守不住「改歪了」。这里数一遍真机像素，独立确认红灯**画**在哪。
        if let ink = measureRedLightInkCenter(window: window, label: label, mismatches: &mismatches) {
            let anchor = DesignTokens.Size.titleBarInsetCenter
            if abs(ink - anchor) > 1.5 {
                mismatches.append(
                    "\(label) 红灯**渲染**出来的中心距左 \(ink)pt，设计稿锚点 \(anchor)pt —— "
                        + "frame 层面是对齐的，但画出来的位置不是 —— "
                        + "检查 alignTrafficLights 是否真的作用到了被绘制的那个视图")
            }
        }
        return delta
    }

    /// 从**真机渲染的像素**里量红灯的墨迹中心，兜住「frame 对了但画的位置不对」。
    ///
    /// **为什么必须有这条**：``checkTitleBarHorizontalSymmetry`` 比较的是
    /// 「红灯 frame 中心」与「设置按钮中心」，而红灯的 frame **正是我们自己改的**
    /// （``alignTrafficLights(in:)``）—— 这是典型的自证陷阱：
    /// 断言与被断言的对象同源，改歪了它可能照样是绿的。
    /// 这里绕开 frame，直接**数屏幕上的红色像素**，是独立的一条证据。
    ///
    /// **扫描范围为什么只取左半侧的一小条**：主窗口里有 `.btn--danger` 红色按钮
    /// （「关闭并推出」），全窗口扫红色会把那些按钮也算进来 —— 与「量不到」
    /// 一样会让数字失去意义。红灯只在标题栏那一条（距顶 20…32pt）里。
    ///
    /// - Returns: 量到的红灯墨迹中心距窗口左边的距离（pt）；量不到时为 `nil`。
    private func measureRedLightInkCenter(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> CGFloat? {
        let windowID = CGWindowID(window.windowNumber)
        guard
            let cg = CGWindowListCreateImage(
                CGRect.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming)
        else {
            mismatches.append("\(label) 抓不到主窗口的真机图像，无法核对红灯的**渲染**位置")
            return nil
        }
        // `NSBitmapImageRep(cgImage:)` 在 macOS 上**不是** Optional，不能放在 `guard let` 里。
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = window.backingScaleFactor
        let band = DesignTokens.Size.titleBarBandHeight
        let y0 = Int((band / 2 - 7) * scale)
        let y1 = min(rep.pixelsHigh, Int((band / 2 + 7) * scale))
        let xLimit = min(rep.pixelsWide, Int(200 * scale))
        var minX = Int.max
        var maxX = Int.min
        var count = 0
        for y in y0..<y1 {
            for x in 0..<xLimit {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // 红灯 ≈ #FF5F57：红分量高、且明显压过绿蓝。
                let isRed =
                    c.redComponent > 0.7
                    && c.redComponent - c.greenComponent > 0.25
                    && c.redComponent - c.blueComponent > 0.2
                if isRed {
                    count += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
        }
        // **自证**：12pt 直径的圆在 2x 下约 450 个像素。太少说明只扫到抗锯齿边缘，
        // 太多说明把别的东西（红色按钮、窗口外内容）扫了进来 —— 两种都不能算通过。
        guard count > 50, count < 4000 else {
            mismatches.append(
                "\(label) 标题栏那一条里扫到 \(count) 个红色像素（12pt 圆的合理量级是 200…900）——"
                    + "要么玻璃没渲染完，要么扫描范围把红色按钮包了进来。这个数不可信")
            return nil
        }
        let center = CGFloat(minX + maxX) / 2 / scale
        print(
            "    红灯墨迹（真机像素）=\(CGFloat(minX) / scale)…\(CGFloat(maxX) / scale)pt "
                + "中心距左=\(center)pt 像素数=\(count)")
        return center
    }

    /// 无外置磁盘时，列表区必须画**空状态**，而不是卡在首屏骨架层。
    ///
    /// **为什么只有真机测得到**：`cacheDisplay` 不跑 SwiftUI 的 `.task`
    /// （没有事件循环），离屏渲染时两个状态位都停在初始值 `false` ——
    /// 无论实现对不对，离屏结果都一样。**结构上测不到**，与交通灯同类。
    ///
    /// **判据**：数列表区（标题栏以下）的**深色像素**。
    /// 空状态有图标 + 标题 + 两行说明 + 按钮，墨迹成千；
    /// 骨架层只有 `Palette.subtle` 的浅灰圆角块，**几乎没有深色墨迹** ——
    /// 两者量级差得远，不需要精细阈值。
    ///
    /// **本机插着盘时跳过**：那时列表区画的是磁盘行（也有大量深色文字），
    /// 判据不成立。跳过而不是硬跑 —— 假红比不测更糟。
    private func checkEmptyStateInsteadOfSkeleton(
        window: NSWindow, label: String, mismatches: inout [String]
    ) {
        let diskCount = DiskListStore.shared.disks.count
        guard diskCount == 0 else {
            print("    空状态核对：跳过（本机有 \(diskCount) 块外置磁盘，列表区画的是磁盘行）")
            return
        }
        // ⚠️ **判据只在浅色外观下成立**：深色底本身就是「深色像素」，
        // 整屏都会被算成墨迹，这条断言会假绿。深色模式跳过，不硬跑。
        guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua else {
            print("    空状态核对：跳过（当前是深色外观，「深色像素」判据不成立）")
            return
        }
        let windowID = CGWindowID(window.windowNumber)
        guard
            let cg = CGWindowListCreateImage(
                CGRect.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming)
        else {
            mismatches.append("\(label) 抓不到主窗口图像，无法核对空状态")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = window.backingScaleFactor
        let band = DesignTokens.Size.titleBarBandHeight

        /// 数指定 y 带里的深色像素。
        func darkCount(fromTop y0: CGFloat, to y1: CGFloat) -> Int {
            let a = max(0, Int(y0 * scale))
            let b = min(rep.pixelsHigh, Int(y1 * scale))
            guard a < b else { return 0 }
            var n = 0
            for y in a..<b {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75 {
                        n += 1
                    }
                }
            }
            return n
        }

        // **自证**：标题栏必须先有墨迹（标题「外置磁盘」），否则是玻璃没渲染完 ——
        // 那种情况下列表区也一定是空的，会把「没渲染」误读成「骨架层」。
        let titleInk = darkCount(fromTop: 0, to: band)
        guard titleInk > 50 else {
            mismatches.append(
                "\(label) 标题栏只数到 \(titleInk) 个深色像素 —— 窗口玻璃还没渲染完，"
                    + "这次的列表区结果不可信（不能当作「画了骨架」）")
            return
        }

        let listInk = darkCount(fromTop: band, to: window.frame.height)
        // **阈值是变异验证定出来的，不是拍的**：
        // 实测空状态 **11175**、把 bug 造回去（强制显示骨架）后 **394** —— 差 28 倍。
        // 取 2000：离两边都有 5 倍余量，既不因抗锯齿抖动误报，也不漏掉骨架。
        // ⚠️ 第一版阈值写的 200，变异后 394 **照样绿** —— 断言看着在守，其实守不住。
        // **动这个数之前先重跑一次变异验证。**
        let emptyStateInkFloor = 2000
        print(
            "    空状态核对：标题栏墨迹=\(titleInk) 列表区墨迹=\(listInk)"
                + "（空状态实测 ≈11175，骨架层 ≈394，阈值 \(emptyStateInkFloor)）")
        if listInk < emptyStateInkFloor {
            mismatches.append(
                "\(label) 没有外置磁盘，列表区却只数到 \(listInk) 个深色像素 —— "
                    + "画的多半是**首屏骨架层**（浅灰圆角块，没有文字），而不是空状态。"
                    + "空状态有图标 + 标题 + 说明 + 按钮，墨迹应是数千量级。"
                    + "判据见 ContentView.showsSkeleton —— 骨架只能由「首屏加载结束」关闭，"
                    + "不能依赖 onChange(of: disks)（无盘时列表永远不变，那个回调不会触发）")
        }
    }

    /// 把主窗口状态打到终端，并就地核对。
    ///
    /// 三条断言各有明确后果：
    /// 1. 窗口必须是设计稿的 **800 × 520**（`01-main-window.html` 的 `.win--main`）——
    ///    这条抓的是「`NSHostingView` 把 520+32 的固有尺寸回推给窗口」；
    /// 2. **玻璃必须覆盖整个窗口**（含 52pt 标题栏那一带）—— 这条是「标题栏露底」的捕手。
    ///    判据不是看颜色（离屏取不到桌面），而是**问 AppKit 那块 `NSVisualEffectView` 在窗口里占多大**：
    ///    ``GlassSurface`` 用的材质是 `.underWindowBackground`，系统标题栏自带的不是这一档，
    ///    所以能精确挑出「我们自己画的那块玻璃」；
    /// 3. **交通灯与标题栏内容带必须在同一条水平基线上**（见 ``checkTrafficLightBaseline``）——
    ///    内容带高度 32 是从交通灯实测位置反推的常数，AppKit 挪了灯只有真机量得出来。
    @MainActor
    private func dumpMainWindowState(label: String, mismatches: inout [String]) {
        guard let window = mainWindow else {
            mismatches.append("A 主窗口不存在")
            return
        }
        let hosting = window.contentView
        // ⚠️ **两边都必须转成窗口坐标再比**。`NSHostingView` 是 flipped 的
        // （`isFlipped == true`，原点在左上），它的 `bounds` 与 `glassEffectFrames`
        // 返回的窗口坐标（原点在左下）**y 轴方向相反** —— 直接比会得到荒谬的结论。
        let contentRect = hosting?.convert(hosting?.bounds ?? .zero, to: nil) ?? .zero
        let glasses = window.glassEffectFrames
        let ours = glasses.filter { $0.material == .underWindowBackground }
        let covered = ours.map(\.frame).reduce(CGRect.null) { $0.union($1) }

        // **不用 `.zero` 这种隐式成员**：在字符串插值里它没有上下文类型可推，
        // Swift 会去猜（实测猜成 `Int.zero`），然后在一个莫名其妙的地方报
        // 「binary operator '+' cannot be applied to 'String' and 'String.Stride'」。
        // 显式写类型，或者先算成局部变量。
        let insets: NSEdgeInsets = hosting?.safeAreaInsets ?? NSEdgeInsetsZero
        let size = "\(window.frame.width)×\(window.frame.height)"
        print(
            "  \(label)：上屏=\(window.isVisible) 尺寸=\(size) "
                + "内容区(窗口坐标)=\(contentRect) 安全区=\(insets)"
        )
        for (index, glass) in glasses.enumerated() {
            print("    玻璃[\(index)] material=\(glass.material.rawValue) frame=\(glass.frame)")
        }
        print("    自定义玻璃并集=\(covered)")

        let expected = DesignTokens.Size.mainWindow
        if abs(window.frame.width - expected.width) > 0.5
            || abs(window.frame.height - expected.height) > 0.5
        {
            mismatches.append(
                "A 窗口应为 \(expected.width)×\(expected.height)，实得 "
                    + "\(window.frame.width)×\(window.frame.height)")
        }

        // 玻璃要覆盖整个窗口内容区。留 0.5pt 容差给坐标取整。
        guard !ours.isEmpty, contentRect.height > 0 else {
            mismatches.append("A 没找到主窗口的自定义玻璃（material=.underWindowBackground）—— 背景没铺上")
            return
        }
        let tolerance: CGFloat = 0.5
        let covers =
            covered.minX <= contentRect.minX + tolerance
            && covered.minY <= contentRect.minY + tolerance
            && covered.maxX >= contentRect.maxX - tolerance
            && covered.maxY >= contentRect.maxY - tolerance
        if !covers {
            mismatches.append(
                "A 玻璃只覆盖 \(covered)，未铺满内容区 \(contentRect) —— "
                    + "上/下缺口 \(contentRect.minY - covered.minY) / "
                    + "\(contentRect.maxY - covered.maxY)pt（顶部安全区 32pt 就是标题栏那一带）")
        }

        // 3 · 交通灯与标题栏内容带在同一条水平基线上。
        //
        // ⚠️ **这条离屏出图测不到**：离屏没有窗口就没有交通灯。而内容带高度是从交通灯
        // 位置反推的常数（见 ``DesignTokens/Size/titleBarBandHeight``）——
        // AppKit 哪天把灯挪了，只有这里会红。
        checkTrafficLightBaseline(window: window, label: "A", mismatches: &mismatches)

        // 4 · 标题栏左右两个边缘部件**光学中心对称**（红灯 vs 设置按钮）。
        //
        // 这两个部件来源不同：红灯由 AppKit 画、设置按钮由 SwiftUI 的 padding 定，
        // 凭印象对齐一定会对错。设计稿两侧都是 26pt，判据用中心（不能用盒边缘）。
        checkTitleBarHorizontalSymmetry(window: window, label: "A", mismatches: &mismatches)

        // 5 · 没有外置磁盘时必须显示**空状态**，不能卡在首屏骨架层。
        //
        // 离屏出图测不到这条（`cacheDisplay` 不跑 `.task`），只能真机量。
        checkEmptyStateInsteadOfSkeleton(window: window, label: "A", mismatches: &mismatches)
    }

    // MARK: - 设置窗口真机自检

    /// 把设置窗口真的上屏，核对**离屏出图覆盖不到**的部分。
    ///
    /// **为什么需要它**：设置窗口与主窗口同源 —— `.fullSizeContentView` + 透明标题栏，
    /// `NSHostingView` 会把「内容 566 + 标题栏安全区 32」当固有尺寸**回推给窗口**。
    /// 离屏没有窗口就没有安全区，窗口也不会被回推（实测离屏恒为 566）——
    /// 「窗口高是不是设计稿的 566」「玻璃有没有连标题栏一起铺满」两件事离屏测不到。
    ///
    /// 实测（2026-09-16 补齐前）：上屏后是 **440×598**（多 32pt），玻璃只拿到内容的 566，
    /// 底部露成平色；系统标题栏的「设置」还与面板头部的「设置」重复。
    /// 这几条当时**一个断言都没有** —— 改掉任何一条，测试与自检都不会红。
    ///
    /// **只读**：不动任何磁盘、不写偏好；点「完成」只会关窗。
    ///
    /// 跑法：
    /// - 人工核对：`DiskEjectorApp --preview-settings`（窗口留在屏幕上，核对完 ⌘Q）
    /// - 自动验证：`DiskEjectorApp --preview-settings-keys`（跑完即退出，退出码 0 = 全通过）
    ///
    /// **注意不能 `return` 掉整个 `main()`**（与其它 `--preview-*` 同理）：
    /// 窗口要靠 run loop 才能真正上屏、才会把 SwiftUI 的视图树建出来。
    @MainActor
    private func runSettingsPreview(autoKeys: Bool) {
        Task {
            var mismatches: [String] = []

            // 走**真实路径**：`showSettings()` 里就是 `makeSettingsWindow()`。
            // 另写一份「预览专用的建窗代码」等于什么都没验。
            showSettings()
            await waitUntilAppIsActive()
            // 等窗口上屏并把 SwiftUI 的视图树建好（玻璃是 `NSViewRepresentable`，
            // 要等 AppKit 那一层真的建出来才找得到）。
            try? await Task.sleep(nanoseconds: 600_000_000)

            guard let window = settingsWindow else {
                print("❌ 设置窗口没有建起来")
                exit(1)
            }
            dumpSettingsWindowState(label: "A · 设置窗口", window: window, mismatches: &mismatches)

            guard autoKeys else {
                print("人工核对模式：设置窗口已上屏（本模式不会改动任何设置）。")
                print("  核对要点：")
                print("    ① 窗口高应是 566（设计稿），不是 598；")
                print("    ② 标题栏那一条应与下方内容共用同一张玻璃，不是一块平色；")
                print("    ③ 顶部只应有一个「设置」—— 系统标题栏那个应被隐藏；")
                print("    ④ **不该看到任何红绿灯** —— 设计稿的 `.shead` 里只有「设置」+「完成」，")
                print("       左「设置」右「完成」，两侧各留 16（红绿灯会和「完成」功能重复）；")
                print("    ⑤ 「设置」的视觉中线应与主窗口标题在同一条水平线上（纵向，距顶 16）。")
                print("  核对完 ⌘Q 退出。")
                return
            }

            print("预览结束（未改动任何设置）")
            if mismatches.isEmpty {
                print(
                    "✅ 设置窗口真机自检通过：窗口 440×566、玻璃覆盖整窗（含标题栏）、"
                        + "三个系统按钮都已隐藏（无红绿灯）")
                exit(0)
            }
            for line in mismatches { print("❌ \(line)") }
            exit(1)
        }
    }

    /// 把设置窗口的状态打到终端，并就地核对。
    ///
    /// 四条断言各有明确后果：
    /// 1. 窗口必须是设计稿的 **440 × 566**（`05-settings.html` 的 `.win--settings`）——
    ///    这条抓的是「`NSHostingView` 把 566+32 的固有尺寸回推给窗口」（实测会撑到 598）；
    /// 2. **玻璃必须覆盖整个窗口内容区**（含 52pt 头部那一带）—— 与主窗口同款的露底捕手。
    ///    判据不是看颜色（离屏取不到桌面），而是问 AppKit 那块 `NSVisualEffectView`
    ///    在窗口里占多大：``GlassSurface`` 用的材质是 `.underWindowBackground`，
    ///    系统标题栏自带的不是这一档，所以能精确挑出「我们自己画的那块玻璃」；
    /// 3. 系统标题栏的标题必须隐藏 —— 否则「设置」在同一个窗口上出现两遍；
    /// 4. **三个系统按钮必须都藏着**（``SettingsWindow``）—— 设计稿的 `.shead` 里没有
    ///    `traffic`，红绿灯的关窗与头部的「完成」是**同一个动作的两个出口**
    ///    （用户 2026-09-16 报告）。
    ///
    /// 第 4 条**只能真机验**：`standardWindowButton(_:)` 是「窗口」才有的东西，
    /// 离屏没有窗口，也就没有按钮可问（返回 `nil`）。
    ///
    /// ⚠️ 这里**曾经**有第 4、5 两条量交通灯的断言（垂直基线、横向不压标题）。
    /// 设置面板不再画红绿灯之后它们失去意义 —— 但**不是删掉了**：
    /// 主窗口仍然在画，那两条原样留在 ``dumpMainWindowState`` / ``checkTrafficLightBaseline``
    /// 里，继续守着「内容带高度 32」这个从灯的实测位置反推出来的常数。
    @MainActor
    private func dumpSettingsWindowState(
        label: String, window: NSWindow, mismatches: inout [String]
    ) {
        let hosting = window.contentView
        // ⚠️ **两边都必须转成窗口坐标再比**。`NSHostingView` 是 flipped 的
        // （`isFlipped == true`，原点在左上），它的 `bounds` 与 `glassEffectFrames`
        // 返回的窗口坐标（原点在左下）**y 轴方向相反** —— 直接比会得到荒谬的结论。
        let contentRect = hosting?.convert(hosting?.bounds ?? .zero, to: nil) ?? .zero
        let glasses = window.glassEffectFrames
        let ours = glasses.filter { $0.material == .underWindowBackground }
        let covered = ours.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        // 显式写类型：在字符串插值里 `.zero` 没有上下文类型可推，Swift 会去猜
        // （实测猜成 `Int.zero`），然后在一个莫名其妙的地方报运算符不匹配。
        let insets: NSEdgeInsets = hosting?.safeAreaInsets ?? NSEdgeInsetsZero
        let size = "\(window.frame.width)×\(window.frame.height)"

        print(
            "  \(label)：上屏=\(window.isVisible) 尺寸=\(size) "
                + "内容区(窗口坐标)=\(contentRect) 安全区=\(insets)"
        )
        print(
            "    标题栏透明=\(window.titlebarAppearsTransparent) "
                + "标题隐藏=\(window.titleVisibility == .hidden) "
                + "背景 alpha=\(window.backgroundColor.alphaComponent) "
                + "不透明=\(window.isOpaque)"
        )
        for (index, glass) in glasses.enumerated() {
            print("    玻璃[\(index)] material=\(glass.material.rawValue) frame=\(glass.frame)")
        }
        print("    自定义玻璃并集=\(covered)")

        // 设置窗口底部那行「版本 x · 构建 y」——用户报 bug 时唯一能给出的定位信息。
        //
        // ⚠️ **这个值取决于跑法**：`.app` 里读到的是 Info.plist 的真值；
        // 直接跑 `.build/debug/DiskEjectorApp`（本自检的常规跑法）时 `Bundle.main`
        // 没有那两个键，界面会落到兜底值 `1.0.0` / `1` —— **这是预期，不是 bug**。
        // 所以这里只**打印**并说明来源，不当断言（否则每次跑自检都会假红）。
        // 真值的守卫在 `AppVersionInfoTests`（含一条读打包产物的断言）。
        // ⚠️ 「（兜底）」只能标在**真的用了兜底值**的那一项上。
        // 第一版把后缀无条件拼在 `?? "1.0.0"` 之后，读到真值时也显示「兜底」——
        // 一条会骗人的诊断输出比没有诊断更糟。
        let short = AppVersionInfo.shortVersion()
        let build = AppVersionInfo.build()
        let source =
            Bundle.main.bundleIdentifier == nil
            ? "裸可执行，读不到 Info.plist，界面显示兜底值（预期）"
            : "从 .app 的 Info.plist 读取"
        print(
            "    版本行：\(short ?? "1.0.0")\(short == nil ? "（兜底）" : "")"
                + " · \(build ?? "1")\(build == nil ? "（兜底）" : "")"
                + " · bundle=\(Bundle.main.bundlePath)（\(source)）")

        // 版本行下方那条「本次构建含 N 处未提交改动」——只在 `DEBuildDirtyCount > 0` 时出现。
        //
        // 与版本行同理：裸可执行读不到这两个键 → 不显示，**这是预期**，所以只打印不当断言。
        // 这条输出真正的价值在于**从 `/Applications/DiskEjector.app` 跑**时能看到它确实会显示 ——
        // 也就是证明「版本号看着像 tag 那次正式构建、实际跑的却是工作区」这件事
        // 在界面上被说清楚了。不打印的话，这个功能从命令行完全看不出有没有生效。
        if let dirty = AppVersionInfo.dirtyCount() {
            if dirty > 0 {
                print(
                    "    脏构建提示行："
                        + String(
                            format: L10n.tr(.versionDirtyNoticeFormat), dirty,
                            AppVersionInfo.commit() ?? "—"))
            } else {
                print("    脏构建提示行：不显示（工作区干净，dirty=0）")
            }
        } else {
            print("    脏构建提示行：不显示（读不到 DEBuildDirtyCount —— 裸可执行下预期）")
        }

        // 1 · 窗口尺寸
        let expected = DesignTokens.Size.settingsPanel
        if abs(window.frame.width - expected.width) > 0.5
            || abs(window.frame.height - expected.height) > 0.5
        {
            mismatches.append(
                "A 窗口应为 \(expected.width)×\(expected.height)，实得 "
                    + "\(window.frame.width)×\(window.frame.height)"
                    + "（多出来的高度就是标题栏安全区 32pt）")
        }

        // 2 · 玻璃铺满整个内容区。留 0.5pt 容差给坐标取整。
        let tolerance: CGFloat = 0.5
        if ours.isEmpty || contentRect.height <= 0 {
            mismatches.append("A 没找到设置窗口的自定义玻璃（material=.underWindowBackground）—— 背景没铺上")
        } else {
            let covers =
                covered.minX <= contentRect.minX + tolerance
                && covered.minY <= contentRect.minY + tolerance
                && covered.maxX >= contentRect.maxX - tolerance
                && covered.maxY >= contentRect.maxY - tolerance
            if !covers {
                mismatches.append(
                    "A 玻璃只覆盖 \(covered)，未铺满内容区 \(contentRect) —— "
                        + "上/下缺口 \(contentRect.minY - covered.minY) / "
                        + "\(contentRect.maxY - covered.maxY)pt（顶部 32pt 安全区就是红绿灯那一带）")
            }
        }

        // 3 · 系统标题栏的标题必须隐藏
        if window.titleVisibility != .hidden {
            mismatches.append(
                "A 系统标题栏标题未隐藏（titleVisibility=\(window.titleVisibility.rawValue)）—— "
                    + "会与面板自己头部的「设置」重复")
        }

        // 4 · 三个系统按钮必须都藏着（照设计稿：设置面板不画红绿灯）。
        //
        // **只能真机验**：`standardWindowButton(_:)` 属于「窗口」，离屏没有窗口就没有按钮可问。
        // 而它恰恰是本轮要守的东西 —— 一旦被改回可见，用户看到的就又是「红灯 + 完成」
        // 两个功能相同的出口。
        let traffic = zip(["红", "黄", "绿"], SettingsWindow.hiddenButtonTypes).map {
            name, type -> String in
            guard let button = window.standardWindowButton(type) else { return "\(name)=无此按钮" }
            return "\(name)=\(button.isHidden ? "已隐藏" : "仍在画")"
        }
        print("    系统按钮=\(traffic.joined(separator: " "))")
        if !SettingsWindow.standardButtonsAreHidden(in: window) {
            mismatches.append(
                "A 设置窗口还在画系统交通灯（\(traffic.joined(separator: " "))）—— "
                    + "设计稿的 `.shead` 里没有 traffic，红绿灯的关窗与头部的「完成」是"
                    + "同一个动作的两个出口（用户 2026-09-16 报告）")
        }
    }

    // MARK: - 状态栏

    /// 状态栏按钮：点击切换 NSPopover（与设计稿"菜单栏弹出面板"对齐：360px 宽，毛玻璃）。
    ///
    /// **幂等**：`main()` 里的 `--preview-popover` 会在 `applicationDidFinishLaunching`
    /// 之前先建一次状态栏（预览要立刻把面板挂上去），随后正常的启动流程又会调一次。
    /// 没有这道 guard 就会**建出两个状态栏图标**（而且第二次会把 `statusItem` 覆盖掉，
    /// 第一个从此没人引用、无法移除）。注意 `rebuildStatusItemIfOffscreen()` 是**故意**
    /// 绕过本方法的 —— 它要的就是「销毁重建」，不能有这道 guard。
    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        button.toolTip = L10n.tr(.appName)
        button.setAccessibilityLabel(L10n.tr(.appName))
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
        statusItem?.button?.toolTip = L10n.tr(.appName)
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
        showStatusPopover(anchoredTo: button)
    }

    /// 把菜单面板建起来并上屏。**抽出来是为了让 `--preview-popover` 走同一条路径** ——
    /// 真机自检要验的正是这条路径（材质归一化、contentSize、上屏），
    /// 另写一份「预览专用的显示代码」等于什么都没验。
    @MainActor
    private func showStatusPopover(anchoredTo button: NSStatusBarButton) {
        guard let popover = statusPopover else { return }
        // 重新构造 contentViewController，保证引用最新 AccentColor 等设置
        let accent = AppSettings.accentColor
        let view = MenuPopoverView(
            accent: accent,
            onOpenMainWindow: { [weak self] in self?.handlePopoverAction(.openMainWindow) },
            onRefresh: { [weak self] in self?.handlePopoverAction(.refreshDisks) },
            onOpenSettings: { [weak self] in self?.handlePopoverAction(.openSettings) },
            onQuit: { [weak self] in self?.handlePopoverAction(.quit) },
            onEject: { [weak self] disk in self?.handlePopoverEject(disk) }
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

        // **让 popover 的底衬与主窗口同档材质**。
        //
        // `NSPopover` 的窗口顶层是私有的 `NSPopoverFrame`，它本身就是一档
        // `.titlebar` 的 `NSVisualEffectView`；主窗口用的是 `.underWindowBackground`。
        // 两者不是同一块玻璃 —— 这正是「菜单栏面板和主窗口背景色不一致」的根因。
        // 探针实测（2026-09-15）见 `NSPopover.normalizeBackdropMaterial()`。
        //
        // 视图树要等窗口真正上屏才建好，所以这里同步试一次、下一个 runloop 再试一次。
        // 两次都失败也不影响功能，只是面板会退回系统默认材质。
        popover.normalizeBackdropMaterial()

        // 防焦点环 + 让 NSPopover(.transient) hit-test 命中内部
        DispatchQueue.main.async {
            self.statusPopover.normalizeBackdropMaterial()
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

    /// 面板动作的出口。为 `nil` 时走真实行为；`--preview-popover` 会把它换成「只记录」。
    ///
    /// **做成属性而不是在建视图时捕获闭包**：视图每次点开都重建，闭包换不了；
    /// 而真机自检要「同一个面板、先后走多个出口」。与 ``onboardingExitHandler`` 同一套做法。
    private var popoverActionHandler: ((MenuPopoverAction.Kind) -> Void)?

    /// 面板上的动作分发。**穷举 `switch` 是刻意的** —— `Kind` 加了新 case 而这里没跟上时
    /// **编译不过**。若用 `default: return` 兜底，新增一行会安静地渲染成一个点不动的按钮。
    private func handlePopoverAction(_ kind: MenuPopoverAction.Kind) {
        if let handler = popoverActionHandler {
            handler(kind)
            return
        }
        switch kind {
        case .openMainWindow:
            statusPopover?.performClose(nil)
            showMainWindow()
        case .refreshDisks:
            Task { await DiskListStore.shared.refresh() }
        case .openSettings:
            statusPopover?.performClose(nil)
            showSettings()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func handlePopoverEject(_ disk: DiskInfo) {
        statusPopover?.performClose(nil)
        eject(disk)
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
        // **应用本来就活跃、且已经有一个可见的 key window —— 什么都不做。**
        //
        // 这一段是 2026-09-17 用户报「打开『在 Dock 中显示图标』时，主窗口和设置窗口
        // 都会闪一下」的根因：旧的写法无条件 `activateApp()` + 全体 `orderFrontRegardless()`
        // + `visible.first?.makeKey()`。用户在**设置窗口**里拨开关，而 `NSApp.windows` 里
        // 排在前面的往往是主窗口 —— 于是 key 被从设置窗抢走，两个窗口一起经历
        // 「失焦 → 重新排序 → 重新激活」，看起来就是闪一下。
        //
        // 上面那段注释里真正要防的是另一种情况：**窗口被策略切换挤走了**（没有 key window）。
        // 有 key window 就说明什么都没丢，此时再抢一次焦点纯属制造闪烁。
        //
        // 判据只看「有没有可见的 key window」，**不看 `NSApp.isActive`**：
        // 切激活策略的那一瞬间 `isActive` 可能短暂为 false，但窗口并没有丢 ——
        // 以它为准会把「其实没丢」也当成「丢了」，于是又去抢一次焦点、又闪一下。
        if let key = NSApp.keyWindow, key.isVisible { return }

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
            await EjectUI.handle(outcome, disk: disk)
        }
    }

    // MARK: - 主窗口

    /// **幂等**：`main()` 里的 `--preview-main-window` 会在 `applicationDidFinishLaunching`
    /// 之前先建一次窗口（预览要立刻把它上屏），随后正常的启动流程又会调一次。
    /// 没有这道 guard 就会**建出两个窗口**，而且第二次把 `mainWindow` 覆盖掉 ——
    /// 第一个从此没人引用、关不掉也释放不了。
    private func setupMainWindow() {
        guard mainWindow == nil else { return }
        mainWindow = Self.makeMainWindow()
    }

    /// 建主窗口。**真机与单测走同一条装配路径**（`MainWindowTests` 直接调它）。
    ///
    /// 与 ``makeOnboardingPanel(root:)`` 同一个理由：下面这几行配置**每一条去掉都会静默劣化**，
    /// 而任何一条都不会让别的断言变红 —— 光读代码看不出它们是不是冗余。
    static func makeMainWindow() -> NSWindow {
        let win = KeySilentWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DesignTokens.Size.mainWindow.width,
                height: DesignTokens.Size.mainWindow.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr(.appName)
        // 标题栏不绘制标题文字：红绿灯右侧只留空白，应用身份由状态栏图标与窗口内容表达。
        // `titleVisibility = .hidden` 只影响绘制，`title` 字符串仍保留——窗口菜单（Window）、
        // Mission Control、辅助功能读取到的仍是正确的应用名。
        win.titleVisibility = .hidden

        // **窗口层面的外观，全部在这里定死 —— 不要挪回 `ContentView` 的 `WindowAccessor`。**
        //
        // 它们原先就散在那里（一个 `NSViewRepresentable`，要等视图进窗口、再走一次
        // `DispatchQueue.main.async` 才生效）。实测那是个**不可靠的时机**：
        // `MainWindowTests` 里推完布局又跑了 run loop，`titlebarAppearsTransparent` /
        // `backgroundColor` / `isOpaque` **依然没生效**。而这几条决定了
        // 「窗口看起来是玻璃，还是一块不透明白板」—— 不该靠时序碰运气。
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.defaultButtonCell = nil
        // **毛玻璃关键**：清掉 NSWindow 自带的 windowBackgroundColor 半透明白底，
        // 否则 NSVisualEffectView(.underWindowBackground, .behindWindow) 会被它盖住，
        // 桌面无法透到 SwiftUI 里的毛玻璃上面，整张主窗口看起来只是一片浅色色块。
        win.backgroundColor = .clear
        win.isOpaque = false

        // **内容宿主必须关掉安全区。**
        //
        // `.fullSizeContentView` 的窗口会告诉 SwiftUI「顶部这 32pt 被标题栏占着」，
        // SwiftUI 于是把内容**整体下推 32pt**，并把「内容 520 + 安全区 32」当成固有尺寸
        // 回推给窗口 —— 窗口**在上屏那一刻被撑到 800×552**（设计稿 520）。
        // 与引导面板同一处理（见 ``makeOnboardingPanel(root:)``，那里踩过 380×503 → 532）。
        //
        // ⚠️ **只要这一句，别顺手加 `sizingOptions = []`**。它不是「什么都不做」，而是把窗口的
        // `minSize`/`maxSize` **清成默认**（实测 `minSize` → 0×0、`maxSize` → 1.79e308），
        // 会静默清掉下面刚设好的 `minSize`。而关掉安全区之后固有尺寸本来就是 520，
        // `sizingOptions` 的默认行为恰好把 `minSize` 同步成 800×520 —— 正是想要的。
        //
        // **这件事离屏出图结构上测不到**：离屏没有窗口就没有安全区，窗口也不会被回推撑高
        // （实测离屏窗口恒为 520）。守卫在 `MainWindowTests` 与真机自检
        // `--preview-main-window-keys`（量真实窗口尺寸）。
        let hosting = NSHostingView(rootView: ContentView())
        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
        win.contentView = hosting

        // **避免 SwiftUI 启动时第一个 Button 自动获得焦点环**：
        // SwiftUI 主窗口首屏显示时，焦点环默认套在第一个 Button 上（这里是刷新按钮），
        // 看着像「按钮被高亮选中」。`initialFirstResponder = nil` 让首焦点为空。
        // 必须在 `contentView` 赋值之后设 —— 否则会被随后的赋值重置掉。
        win.initialFirstResponder = nil

        // **把系统交通灯挪到设计稿要的位置（竖直 + 水平）。** 它默认落在中心距顶 16pt、
        // 中心距左 16pt（标准 28pt 标题栏的位置），而设计稿是 52pt 里居中（中心 26pt）、
        // 且红灯要与右侧设置按钮对称（中心距左也 26pt）。两个方向都差 10pt。
        // 详见 ``DesignTokens/Size/trafficLightNudgeY`` 与 ``trafficLightNudgeX``。
        alignTrafficLights(in: win)

        win.center()
        // 窗口**没有** `.resizable`，用户拉不动，所以尺寸实际上由 `contentRect` 与这条
        // `minSize` 一起保证。
        //
        // 不设 `maxSize`：`NSHostingView` 的默认 `sizingOptions` 会把内容的 `maxSize`
        // （`.frame(maxWidth:.infinity)` → 无限大）推给窗口，设了也会被覆盖 —— 写一句
        // 注定失效的代码只会误导后来者。
        win.minSize = NSSize(
            width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height
        )
        win.isReleasedWhenClosed = false
        return win
    }

    /// 把系统画的三个交通灯**在竖直与水平两个方向**都挪到设计稿的位置。
    ///
    /// **为什么需要它**：macOS 把交通灯固定在「标准 28pt 标题栏」的位置 ——
    /// 中心距顶 16pt、**中心距左 16pt**（真机实测 `frame=(9, 487, 14, 14)`）。
    /// 而设计稿 `.titlebar` 要的是 52pt 里居中（中心距顶 26pt），
    /// 且红灯与右侧设置按钮**光学对称**（中心距边都 26pt）。两个方向都差 10pt。
    ///
    /// **两个方向是同一个 bug**（2026-09-17 分两次暴露）：先修的竖直方向
    /// （用户反馈「与窗口顶部的距离不一致」），水平方向到用户反馈
    /// 「红灯距左边框与设置按钮距右边框不一致」才补上。
    /// **教训**：这类「迁就系统默认值」的根因，要把同一来源的所有方向一次查完。
    ///
    /// **为什么可以这么改**：`standardWindowButton(_:)` 返回的是普通的 `NSButton`（父视图
    /// 是 `NSTitlebarView`），改它的 `frame` 用的是公开 API，不涉及任何私有视图层级。
    /// **实测（2026-09-17）改完不会被拨回去**：连续跑 run loop、反复 resign/makeKey、
    /// 移动窗口之后，中心都稳定停在新位置。
    ///
    /// ⚠️ **两个已知会把灯拨回原位的时刻**（都是 AppKit 自己重排）：
    /// ① `NSHostingView` 上屏时的重排（x 被拨回 4pt，y 不受影响）；
    /// ② **窗口 resize**（实测 `setContentSize` 后 x 直接回到原始的 9pt）。
    /// 主窗口是固定尺寸（没有 `.resizable`），② 目前触发不到 ——
    /// **哪天给它加上 `.resizable`，必须在这里补一次 resize 后的重对齐**，
    /// 否则拖动窗口时灯会跳回系统默认位置。
    ///
    /// ⚠️ **方向**：`NSTitlebarView` 不是 flipped（原点在左下），所以「往下挪」是 `dy` 取负；
    /// 水平方向没有翻转问题，「往右挪」就是 `dx` 取正。
    /// 挪反了会差 20pt，`--preview-main-window-keys` 会立刻红。
    ///
    /// **补偿量是「量出来」的，不是写死的** —— 这条是踩出来的：
    /// 早期用 `trafficLightNudge = 10` 这种编译期常量去偏移，结果 `NSHostingView`
    /// 上屏时的重排把灯的 x **拨回 4pt**（请求 +10、实得 +6），而 y 不受影响 ——
    /// 写死的常量无法察觉「只生效了一部分」。改成先量当前位置、再补差额之后，
    /// 无论系统把灯放在哪、中途被拨回多少，多次调用都会收敛到目标（**幂等**）。
    ///
    /// - Parameter currentCenter: 红灯（close button）中心，**窗口坐标**（原点左下）。
    /// - Parameter windowHeight: 窗口高度，用来把「距顶 26pt」换算成窗口坐标。
    /// - Returns: 直接可传给 `NSRect.offsetBy` 的偏移。
    ///   `dy` 已含符号：窗口坐标与 `NSTitlebarView`（非 flipped）**y 同向**，
    ///   所以「往下挪」自然得到负值，不要再取负。
    static func trafficLightNudge(
        currentCenter: CGPoint, windowHeight: CGFloat
    ) -> CGSize {
        let target = CGPoint(
            x: DesignTokens.Size.titleBarInsetCenter,
            y: windowHeight - DesignTokens.Size.titleBarBandHeight / 2
        )
        return CGSize(width: target.x - currentCenter.x, height: target.y - currentCenter.y)
    }

    /// - Returns: 实际被挪动的按钮数（0 表示没取到灯 —— 真机自检会因此报错，不要静默）。
    @discardableResult
    static func alignTrafficLights(in window: NSWindow) -> Int {
        guard let close = window.standardWindowButton(.closeButton) else { return 0 }
        // ⚠️ 必须 `convert` 到窗口坐标再量：按钮的 `frame` 是 `NSTitlebarView` 的坐标。
        let current = close.convert(close.bounds, to: nil)
        let nudge = trafficLightNudge(
            currentCenter: CGPoint(x: current.midX, y: current.midY),
            windowHeight: window.frame.height
        )
        guard abs(nudge.width) > 0.01 || abs(nudge.height) > 0.01 else { return 0 }
        var moved = 0
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.frame = button.frame.offsetBy(dx: nudge.width, dy: nudge.height)
            moved += 1
        }
        return moved
    }

    /// 显示主窗口。菜单栏弹窗的「打开主窗口」、菜单里的「显示主窗口」（⌘O）与
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
        // 上屏之后再对齐一次：``alignTrafficLights(in:)`` 是**幂等**的（量当前位置补差额），
        // 而 `NSHostingView` 上屏时的重排会把灯的 **x 拨回 4pt**（实测请求 +10、实得 +6）。
        // 装配时那一次只保证「初始大致对」，这一次才把它收敛到 26pt。
        // ⚠️ 别把这行删掉当成「重复调用」—— 删了红灯会停在 22pt，真机自检会红。
        Self.alignTrafficLights(in: mainWindow)
    }

    // MARK: - 刷新磁盘列表

    /// 重新枚举外接磁盘（主菜单 ⌘R）。
    ///
    /// **为什么需要它**：菜单栏面板的动作行按设计稿要标出 `⌘R`，而 macOS 的 ⌘ 快捷键
    /// 只能经**主菜单**的 `keyEquivalent` 分发 —— 不在这里开一个 action，
    /// 面板上那个 `⌘R` 就只是画上去的装饰，按下去毫无反应。
    ///
    /// 主窗口与面板都 `@ObservedObject` 同一份 ``DiskListStore``，刷新完自动收敛，
    /// 不需要在这里回调任何视图。
    @objc func refreshDisks() {
        Task { @MainActor in
            await DiskListStore.shared.refresh()
        }
    }

    // MARK: - 设置窗口

    /// 显示设置窗口（与主窗口独立，可与主窗口共存）。
    ///
    /// `@objc` 是为了能被主菜单的「设置…」（⌘,）直接指定为 action。
    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow()
        }
        guard let window = settingsWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activateApp()
    }

    /// 建设置窗口。**与 ``makeMainWindow()`` 同一套处理** —— 设计稿把主窗口与设置面板
    /// 写成**同一条 `.win` 规则**（`--bg-glass` + `blur(30) saturate(180%)` + 圆角 12 + 0.5px 描边），
    /// 所以两块玻璃在窗口层面也必须一致。
    ///
    /// ## 这里原先缺了一整排配置（2026-09-16 补齐）
    ///
    /// 之前 `showSettings()` 只有五行装配（`contentRect` / `styleMask` / `contentView` /
    /// `center` / `isReleasedWhenClosed`），主窗口那套一个都没做。后果（逐条实测/推断）：
    ///
    /// | 缺的东西 | 后果 |
    /// |---|---|
    /// | `safeAreaRegions = []` | **上屏前 440×566 → 上屏后 440×598**（多 32pt） |
    /// | `backgroundColor = .clear` + `isOpaque = false` | 窗口不透明 → `.underWindowBackground` 的毛玻璃**糊不到桌面**，看起来是平色块 |
    /// | `titleVisibility = .hidden` | 系统标题栏的「设置」与面板自己头部的「设置」**重复** |
    /// | `contentView.layer.cornerRadius` | 玻璃卡片是 12pt 圆角、窗口底角却是直角，两者不重合 |
    ///
    /// **一个断言都没有** —— 上面任何一条被改掉，测试与自检都不会红。
    /// 现在有 `SettingsWindowTests`（配置 + 玻璃铺满 + 交通灯已隐藏）与
    /// `--preview-settings-keys`（真机尺寸 + 玻璃 + 无交通灯）。
    ///
    /// ## 窗口类用 ``SettingsWindow``，不是 ``KeySilentWindow``（2026-09-16 追加）
    ///
    /// 它继承 ``KeySilentWindow``（于是「没人接管的按键不敲钟」继续成立），
    /// 并且**在 `init` 里就把三个系统按钮藏掉** —— 设计稿的 `.shead` 里没有 `traffic`，
    /// 红绿灯会和「完成」变成两个功能相同的出口（用户报告，见 `DESIGN-SPEC.md` §8.17）。
    static func makeSettingsWindow() -> NSWindow {
        let win = SettingsWindow(
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
        // 标题栏不绘制标题文字：面板自己有一条 52pt 头部（「设置」+「完成」），
        // 系统再画一次就是同一个词出现两遍。`title` 字符串仍保留 —— 窗口菜单、
        // Mission Control、辅助功能读到的仍是它。
        win.titleVisibility = .hidden
        // 透明标题栏 + 内容铺满整窗，玻璃才能像主窗口那样一直盖到顶（含标题栏那一条）。
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.defaultButtonCell = nil
        // **毛玻璃关键**：清掉 NSWindow 自带的 windowBackgroundColor 半透明白底，
        // 否则 NSVisualEffectView(.underWindowBackground, .behindWindow) 会被它盖住，
        // 桌面透不上来 —— 设置面板会看起来只是一块平的浅色，而不是玻璃。
        win.backgroundColor = .clear
        win.isOpaque = false

        // 独立窗口没有 SwiftUI 的 presentation 上下文，`@Environment(\.dismiss)`
        // 在这里是空操作 —— 必须由宿主把「完成」接到关窗上，否则按钮点了没反应。
        // `fillsHost: true` —— 独立窗口要「玻璃铺满整窗」。`false` 是给 `.sheet`
        // 与离屏出图用的（它们要的是理想尺寸 440×566），详见 ``SettingsView/fillsHost``。
        let hosting = NSHostingView(
            rootView: SettingsView(onDone: { [weak win] in win?.close() }, fillsHost: true))
        // 与主窗口、引导面板同一句：`.fullSizeContentView` 会让 SwiftUI 把内容整体下推 32pt，
        // 并把「内容 + 32」当固有尺寸回推给窗口（窗口上屏时被撑高）。
        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
        win.contentView = hosting

        // 避免首屏给第一个控件套上焦点环（与主窗口同理）。必须在 `contentView` 之后设。
        win.initialFirstResponder = nil
        // 玻璃卡片的外圆角（设计稿 12px）。窗口现在是非不透明的，
        // 给 contentView 的 layer 设圆角 + 遮罩，窗口四角才会真的跟着圆。
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.cornerRadius = DesignTokens.Radius.window
        win.contentView?.layer?.masksToBounds = true

        win.center()
        win.isReleasedWhenClosed = false
        return win
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
