import AppKit
import SwiftUI

/// 主窗口内容（设计稿 `01-main-window.html`）。
///
/// **设计稿规格**：800 × 520，外框圆角 12，标题栏 52（上下文标题「外置磁盘 · N 块」+ 刷新/设置），
/// 条件出现的 FDA 横幅，磁盘行列表（内边距 12 / 16 / 16）。
///
/// **职责**：主窗口承担「说明白发生了什么」——三块盘、两种状态并列，用户无需读完整个窗口。
/// 与菜单栏的分工：菜单栏 = 动作（紧凑、一行一行），主窗口 = 诊断（容量条 + 证据区 + 横幅）。
///
/// **统一背景**：跟菜单面板、设置面板同款 ``GlassSurface``（系统材质 + `--bg-glass` 叠加色
/// + 0.5px `--border-strong` 外描边）—— 三块玻璃必须看起来是同一块。
///
/// **保留的不变量**：
/// - 列表来自 ``DiskListStore``（与菜单栏同源）
/// - 占用检测走 ``OccupancyStore``（与菜单栏**同一份状态**，不再是两处各测各的）
/// - FDA canary 由本视图自己轮询（应用级状态，与有没有盘无关）
/// - 推出走 ``EjectUI.handle``，与菜单栏共用弹窗
struct ContentView: View {

    /// 磁盘列表来源。
    ///
    /// **生产路径是 ``DiskListStore/shared``**；离屏出图与真机自检可以注入一个自己造的实例
    /// （见 ``init(skipsInitialRefresh:store:)``）。
    ///
    /// 这里曾经硬编码 `DiskListStore.shared` —— 与 ``MenuPopoverView`` 的 `store:`
    /// 参数不一致（那边早就可注入，`SnapshotRenderTests` 就靠它出「设计稿那两块盘」的图）。
    /// 硬编码的后果是：**「列表为空 → 画空状态」这条分支只能靠本机恰好没插盘才走得到**，
    /// 于是守着它的那条真机断言大部分时间都在跳过（见 ``AppDelegate/checkEmptyStateInsteadOfSkeleton``）。
    @ObservedObject private var store: DiskListStore
    @State private var isRefreshing = false
    @State private var ejectingDiskId: String? = nil

    /// 每个卷的占用检测结果 —— **与菜单栏面板读的是同一个字典**。
    ///
    /// 这里曾经是一个本视图私有的 `@State var occupancy`，配一条只在本视图存活的
    /// 15s 定时器。菜单栏面板另抄了一份 `@State`、且**没有定时器**，于是
    /// 「主窗口说被占用、面板说可以安全推出」在结构上就是可能的（2026-09-15 用户报告）。
    /// 状态与刷新节奏现在都收在 ``OccupancyStore``，两个界面退化成纯读取。
    @ObservedObject private var occupancyStore = OccupancyStore.shared

    /// 是否已授予「完全磁盘访问」（FDA）。决定是否在主窗口顶部展示未授权横幅。
    ///
    /// **必须**与 `OccupancyDetector.isFullDiskAccessAuthorized()` 的**实时探测值**同步——
    /// 该函数是 FDA 状态机的**单一事实来源**（探针选型与理由见 OccupancyDetector 注释）。
    /// 之前的实现只在占用检测末尾刷新一次、且被 `guard !disks.isEmpty` 保护，
    /// 导致「刚启动 / 没插硬盘 / 刚授权完回 app」三种场景下横幅状态都是过期的。
    /// 现在由独立的 `refreshFDAStatus()` 驱动，与占用检测彻底解耦。
    @State private var fdaAuthorized = false

    /// 本会话内是否曾经处于「未授权」状态。
    ///
    /// **为什么需要**：授权成功横幅只在「用户刚刚完成了授权动作」时才有意义。
    /// 若启动时就已授权，这个标记保持 `false`，横幅不会莫名其妙地闪一下。
    @State private var sawUnauthorizedThisSession = false

    /// 授权成功横幅是否可见（约 3 秒后淡出）。
    @State private var showGrantedBanner = false

    /// 300ms 的骨架闸门是否已经放行。
    ///
    /// **只在超过 300ms 时出现**：磁盘枚举通常 < 50ms，直接显示骨架会让界面「闪一下」，
    /// 比什么都不显示更糟。这个 `@State` **只由闸门置位、永远不会被复位** ——
    /// 「该不该显示骨架」由 ``showsSkeleton(gatePassed:hasFinishedInitialLoad:)``
    /// 现场算出来，不靠谁记得去关它。
    @State private var skeletonGatePassed = false

    /// 首屏加载是否已经结束（**无论成功与否、有没有磁盘**）。
    ///
    /// 与 ``skeletonGatePassed`` 一起决定骨架的显示，判据见
    /// ``showsSkeleton(gatePassed:hasFinishedInitialLoad:)``。
    @State private var hasFinishedInitialLoad = false

    /// 列表为空时，该画**骨架**还是**空状态**。
    ///
    /// **抽成纯函数是为了能被单测钉住** —— 这里曾经有一个确定性 bug
    /// （2026-09-17 用户报「没插移动硬盘时，主窗口一直显示骨架层」）：
    ///
    /// - 旧写法把骨架的**开启**判据写成「`disks` 为空」，
    ///   而**关闭**只挂在 `onChange(of: store.disks)` 上；
    /// - 没插盘时刷新前是 `[]`、刷新后还是 `[]` —— **列表根本没变化，`onChange` 不触发**；
    /// - 于是 300ms 闸门打开后，没有任何东西再把它关掉，骨架永驻。
    ///
    /// **判据**：「加载完了但机器上确实没有外置磁盘」与「还没加载完」是两种状态，
    /// 但它们在 `disks` 上的表现**都是空数组** —— 只看空数组分不开，必须看加载是否结束。
    static func showsSkeleton(gatePassed: Bool, hasFinishedInitialLoad: Bool) -> Bool {
        gatePassed && !hasFinishedInitialLoad
    }

    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    @Environment(\.colorScheme) private var colorScheme

    /// 是否跳过**首次**自动刷新（`.task` 里那一句）。
    ///
    /// **只给离屏出图用**，默认 `false` —— 生产行为一字不变。
    ///
    /// ## 为什么需要这个开关
    ///
    /// ``SnapshotRenderTests`` 出图时 `cacheDisplay` 是**同步**截的，而 `.task` 里的
    /// `await refreshDisks()` 会先把 `isRefreshing` 置真，再依次等磁盘枚举与占用检测
    /// （`lsof`）跑完。截图正好落在「**盘已经列出来、刷新还没收尾**」那个窗口里 ——
    /// 于是走查图右上角画的是 **spinner**，而设计稿 `01-main-window.html` 里是**箭头**。
    /// 连跑三次指纹完全一致（`4fde925d31bc`、峰值 161），是**确定性**的，不是随机。
    ///
    /// 出图侧因此改成传 `skipsInitialRefresh: true` 渲染 —— 走查图于是停在**稳态**，
    /// 右上角是设计稿里的箭头。
    ///
    /// 磁盘列表**不需要**额外准备：``DiskListStore/shared`` 的 `private init()` 会同步填一次
    /// `fetchExternalDisks()`，访问 `.shared` 时列表就是满的。
    /// ⚠️ 也**不要**在出图侧补 `await OccupancyStore.shared.refresh(disks:)` —— 那会真的跑
    /// `lsof`，实测把出图从十几秒拖到 6 分钟以上。
    ///
    /// ## 它是什么
    ///
    /// 与 ``DiskListStore`` 的 `monitoring:`、``OccupancyStore`` 的 `autoStart:` 同一种
    /// 「给测试/出图留的注入口」，不是顺手加的生产开关。**不要再加第二个** ——
    /// 想覆盖「刷新中」的观感请直接渲染 ``RefreshTitleBarButton``（`RefreshButtonTests` 就是这么做的）。
    let skipsInitialRefresh: Bool

    /// - Parameters:
    ///   - skipsInitialRefresh: 见上文。**调用方若自己准备了磁盘列表，必须传 `true`** ——
    ///     否则 `.task` 会真的去枚举本机磁盘，把它准备的列表覆盖掉。
    ///   - store: 磁盘列表来源，`nil`（生产）读 ``DiskListStore/shared``。
    ///     注入空列表实例即可在**任何硬件状态下**渲染空状态 ——
    ///     这是 `--preview-main-window-empty-keys` 与 `SnapshotRenderTests` 的入口。
    ///     ⚠️ 与 `skipsInitialRefresh` 是**两个独立参数**，故意不从彼此推导：
    ///     「读哪份数据」和「要不要自动刷新」是两件事，绑在一起会让调用方猜不出行为。
    init(skipsInitialRefresh: Bool = false, store: DiskListStore? = nil) {
        self.skipsInitialRefresh = skipsInitialRefresh
        self.store = store ?? .shared
    }

    private var accentColor: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    /// 行密度：≥ 4 块磁盘自动切紧凑行（设计稿 §3.3）。
    private var density: DiskRowDensity { .forCount(store.disks.count) }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            bannerArea
            scrollRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // **两层 frame 分工不同，别合并成一层**（2026-09-15 的「标题栏露底」就是这么来的）：
        // - 内层 = **设计稿尺寸** 800×520，内容按它排版；
        // - 外层 = **填满宿主**（窗口），``backgroundLayer`` 铺在这一层上。
        //
        // 之前只有一层 `frame(width:height:)` 挂在最外面，玻璃挂在它**里面**，
        // 于是「玻璃铺满整窗」这件事**依赖「窗口高度恰好等于内容高度」这个巧合**。
        // 一旦窗口被撑高（当时是 552），玻璃就只拿到 520，顶部 32pt 露出桌面。
        // 实测（`/tmp/winprobe`）：老结构在「宿主 552 + 无安全区」下玻璃是 y 16…536，
        // 新结构在宿主 520 / 552 / 600 × 有无安全区的六种组合下**全部铺满**。
        .frame(
            width: DesignTokens.Size.mainWindow.width,
            height: DesignTokens.Size.mainWindow.height
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundLayer)
        // 保险，不是主机制：宿主若报出安全区（如 `.fullSizeContentView` 的顶部 32pt），
        // 这一句让上面那层「填满」也跟着吃进安全区。
        //
        // **它单独并不够** —— 实测：安全区为 0 时它是 no-op；而内容若被内层 frame 定死，
        // 它也无处可扩展（老结构 + 宿主 552 就是 16…536 露底）。
        // 真正负责「窗口尺寸正确」的是 ``AppDelegate/makeMainWindow()`` 里的
        // `hosting.safeAreaRegions = []`。
        //
        // **不是** `sizingOptions = []` —— 那个听起来像「窗口尺寸归 AppKit 管」，
        // 实测却是把窗口的 `minSize`/`maxSize` **清成默认值**（`minSize` → 0×0），
        // 会静默清掉刚设好的 `minSize`。详见那里的注释。
        .ignoresSafeArea()
        // **这里只剩「内容视图自己的圆角」。**
        //
        // 窗口层面的配置（透明标题栏、`.fullSizeContentView`、`backgroundColor = .clear`、
        // `isOpaque`、min/max 尺寸、首焦点）全部搬到了 ``AppDelegate/makeMainWindow()`` ——
        // 那里是**确定生效**的时机，也才能被单测断言。
        //
        // 为什么搬：`WindowAccessor` 的 `configure` 走一次 `DispatchQueue.main.async`，
        // 实测在离屏环境里**推了布局又跑 run loop 也不会执行**（`MainWindowTests` 抓到）。
        // 把「窗口是玻璃还是一块不透明白板」交给它，等于交给运气。
        //
        // 圆角留在这里，是因为它要设在**已经进过窗口**的 `contentView` 上。
        .background(
            WindowAccessor { window in
                // 主窗口外框圆角（设计稿 12px）
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.cornerRadius = DesignTokens.Radius.window
                window.contentView?.layer?.masksToBounds = true
            }
        )
        .task {
            // 启动后立即同步探测一次 FDA 授权状态——`.task` 会在视图首次出现前异步执行，
            // 但本探测调用本身是同步的（探针只读 TCC 受保护目录的元数据，毫秒级返回），
            // 用户看不到「默认 false → 探测后变 true」的闪烁。
            refreshFDAStatus()
            // 出图时跳过：调用方已经把数据准备好了，见 ``skipsInitialRefresh`` 的文档。
            // 但「已加载完」必须置位 —— 否则 300ms 闸门会在出图时把骨架画出来。
            guard !skipsInitialRefresh else {
                hasFinishedInitialLoad = true
                return
            }
            await refreshDisks()
            // **无论有没有磁盘**，走到这里就说明首屏加载结束了。
            // 骨架的显示是算出来的（``showsSkeleton(gatePassed:hasFinishedInitialLoad:)``），
            // 置上这个标记它就自动不再显示 —— 不需要谁记得去「关」它。
            hasFinishedInitialLoad = true
        }
        .task {
            // 骨架屏延迟闸门：300ms 内加载完就永远不显示。
            try? await Task.sleep(nanoseconds: 300_000_000)
            skeletonGatePassed = true
        }
        .onChange(of: store.disks) { _ in
            // 磁盘列表变化时刷新 FDA（用户可能刚插了带占用进程的磁盘、也可能在系统设置里授权完了）。
            //
            // **占用检测不在这里**：它由 ``OccupancyStore`` 自己监听 `DiskListStore.$disks`
            // 完成。本视图再测一遍只会多一次 `lsof`，且两份结果还会互相覆盖。
            refreshFDAStatus()
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            // 每 15s 探测一次 FDA：覆盖「用户去系统设置授权后回到 app」的场景。
            // 即使没磁盘也探测（FDA 是应用级状态，与有没有盘无关）。
            //
            // **占用检测也不在这里**：``OccupancyStore`` 有自己的一条轮询，
            // 且它不依赖「主窗口是否打开」—— 面板单独开着时同样在刷新。
            refreshFDAStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // **关键**：app 重新激活时（用户在系统设置授权完切回 DiskEjector）立即刷新 FDA，
            // 否则要等下一次 15s tick 才更新——用户看到横幅没消失会去系统设置重试，体验差。
            //
            // 顺带让占用结论也跟上：用户在系统设置里刚授完权，回到应用应当立刻看到
            // 「占用情况未知」变成真实结论，而不是等下一个 tick。
            refreshFDAStatus()
            Task { await occupancyStore.refresh(disks: store.disks) }
        }
    }

    /// 把 FDA 授权状态同步到本地 `@State`，是横幅显示与否的**单一闸门**。
    ///
    /// 沙盒版（MAS 分发）不需要 FDA 概念：沙盒里没有 TCC 拦截，`OccupancyResult` 直接走 `.unknown`；
    /// 此时让 `fdaAuthorized = true` 即可让未授权横幅永远不出现。
    ///
    /// **顺带驱动授权成功横幅**：从「本会话曾未授权」到「已授权」的跳变，
    /// 意味着用户刚在系统设置里翻了一通——回到应用需要一次「我做对了」的正反馈，
    /// 否则他会怀疑是不是还要再授权一次。
    private func refreshFDAStatus() {
        let authorized =
            OccupancyDetector.isSandboxed || OccupancyDetector.isFullDiskAccessAuthorized()
        defer { fdaAuthorized = authorized }

        guard authorized, !fdaAuthorized else {
            if !authorized { sawUnauthorizedThisSession = true }
            return
        }
        // 刚刚从「未授权」变成「已授权」。
        guard sawUnauthorizedThisSession else { return }
        sawUnauthorizedThisSession = false
        withAnimation(DesignTokens.Motion.standard) { showGrantedBanner = true }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(DesignTokens.Motion.slow) { showGrantedBanner = false }
        }
    }

    // MARK: - 子层

    /// 窗口背景层：**与菜单面板、设置面板共用的同一块玻璃** —— ``GlassSurface``。
    ///
    /// 这里曾经只有 `VisualEffectBackground()`（裸系统材质，没有 `--bg-glass` 叠加色），
    /// 于是主窗口显示为系统材质那层偏冷的灰（离屏实测 RGB 240,240,240），
    /// 而设计稿 `.win` 是 `--bg-glass`（浅色 `rgba(255,255,255,.72)`）铺在模糊之上的一层暖白。
    /// 同时它也少了 `.win` 的 `0.5px var(--border-strong)` 外描边 ——
    /// 浅色壁纸下窗口边缘完全溶进背景。
    ///
    /// **挂法**：`.background(backgroundLayer)`，挂在 body 里那层 **「填满宿主」的 frame** 上
    /// （不是挂在定死 800×520 的内层上），**不要**放进 `ZStack`（理由见
    /// ``GlassSurface`` 的注释：离屏量测时会把 1.79e308 送进 AppKit 约束并崩掉进程）。
    ///
    /// **别指望 `.ignoresSafeArea()` 替你铺满**：它只在「宿主报出安全区」时才有可扩展的量，
    /// 而且扩展的是**它修饰的那一层**。玻璃要铺满，靠的是「它铺在填满宿主的那层上」。
    private var backgroundLayer: some View {
        GlassSurface(cornerRadius: DesignTokens.Radius.window)
    }

    // MARK: - 标题栏（设计稿 `.titlebar`，高 52）

    /// 上下文标题栏：左让位给红绿灯，中间是「外置磁盘 · N 块」，右侧刷新 / 设置。
    ///
    /// **为什么标题栏要有内容**：旧版标题栏是空的（只让位给红绿灯 + 两个图标按钮），
    /// 用户看不出这块区域有什么用。改成上下文标题后，它回答「我正在看什么」——
    /// 这也是 macOS 原生应用的惯例。
    ///
    /// **高度与对齐**：设计稿 `.titlebar` 是 `height: 52px; align-items: center` ——
    /// DOM 探针实测红绿灯 / 标题 / 图标按钮的中心**全在距顶 26pt**。
    /// 所以内容带就是整个 52pt（留白 0），内容居中后中心 26pt。
    ///
    /// 系统画的交通灯本来在中心 16pt（标准 28pt 标题栏的位置），由
    /// ``AppDelegate/alignTrafficLights(in:)`` 在装配窗口时挪到 26pt ——
    /// **不是**把标题拉下去迁就系统。理由与实测见
    /// ``DesignTokens/Size/titleBarBandHeight``。
    ///
    /// ⚠️ 这里历史上改过三次，每次都是「凭印象写数字」：`28 + 24`（猜灯在 14pt）、
    /// `32 + 20`（实测灯在 16pt，于是让标题迁就灯）、到现在的 `52 + 0`（按设计稿，把灯挪过来）。
    /// **不要再凭印象改** —— 现在有真机断言守着（`--preview-main-window-keys`）。
    private var titleBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            // 让位给 macOS 红绿灯（系统绘制，宽约 52pt）+ 左边距 20pt。
            Color.clear.frame(width: 52)

            Text(L10n.tr(.externalDisksTitle))
                .font(.system(size: DesignTokens.FontSize.title, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)

            if !store.disks.isEmpty {
                Text(String(format: L10n.tr(.diskCountFormat), store.disks.count))
                    .font(.system(size: DesignTokens.FontSize.caption))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                // 刷新中**就地换 spinner**，不是把按钮藏起来 —— 见 ``RefreshTitleBarButton``
                // 的文档：旧写法把 `.opacity` 排在 `.overlay` 之后，spinner 被一起调透明，
                // 那块位置在刷新期间是空的（用户 2026-09-16 报告）。
                RefreshTitleBarButton(
                    label: L10n.tr(.refresh),
                    isRefreshing: isRefreshing,
                    action: { Task { await refreshDisks() } }
                )

                titleBarButton(
                    systemName: "gear",
                    label: L10n.tr(.settings),
                    action: { openSettings() }
                )
            }
        }
        .padding(.leading, DesignTokens.Spacing.xl)
        .padding(.trailing, DesignTokens.Spacing.titleBarTrailing)
        .frame(height: DesignTokens.Size.titleBarBandHeight)
        .padding(.bottom, DesignTokens.Size.titleBarBandBottomPadding)
        // 设计稿 `.titlebar { border-bottom: 0.5px solid var(--hairline) }`。
        // 用 overlay 而不是加一条 `Hairline` 进 VStack：后者会占 1pt 高度，
        // 把下面的内容整体推低，标题栏也就不是 52pt 了。
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// 标题栏 28×28 图标按钮。
    private func titleBarButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        TitleBarIconButton(systemName: systemName, label: label, action: action)
    }

    // MARK: - 横幅区

    /// 顶部横幅：未授权时是琥珀色引导，刚授权完是绿色正反馈。
    ///
    /// **两者互斥**：刚授权成功时 `fdaAuthorized == true`，未授权横幅本就不会出现。
    @ViewBuilder
    private var bannerArea: some View {
        if !fdaAuthorized {
            NoticeBanner(
                kind: .warning,
                icon: "lock",
                message: L10n.tr(.fdaBannerLead),
                actionTitle: L10n.tr(.openSystemSettings),
                accent: accentColor,
                action: AppSettings.openFullDiskAccessSettings
            )
        } else if showGrantedBanner {
            NoticeBanner(
                kind: .success,
                // 设计稿标记写的是 `data-i="checkCircle"` —— **描边**的圆 + 勾，
                // 与全设计稿的图标（1.7px 描边、无填充）同一套。
                // 曾经用 `.fill` 的实心圆：在一排描边图标里，它是唯一一个实心的。
                icon: "checkmark.circle",
                message: L10n.tr(.fdaGrantedBanner),
                accent: accentColor
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - 滚动区

    private var scrollRegion: some View {
        ScrollView {
            LazyVStack(spacing: density == .compact ? DesignTokens.Spacing.xs : DesignTokens.Spacing.sm) {
                if store.disks.isEmpty {
                    if Self.showsSkeleton(
                        gatePassed: skeletonGatePassed,
                        hasFinishedInitialLoad: hasFinishedInitialLoad)
                    {
                        skeletonList
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(store.disks) { disk in
                        DiskRow(
                            disk: disk,
                            occupancy: occupancyStore.result(for: disk),
                            accent: accentColor,
                            onEject: { eject(disk) },
                            density: density,
                            isEjecting: ejectingDiskId == disk.id
                        )
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.lg)
        }
        .scrollContentBackground(.hidden)
    }

    /// 空状态。**不用警告色**（不是出错，是还没开始）；
    /// 文案提前解释筛选规则，消灭「插了盘却看不到」的困惑。
    private var emptyState: some View {
        EmptyStateView(
            systemName: "externaldrive",
            title: L10n.tr(.noRemovableDisks),
            description: L10n.tr(.insertDiskHint) + "\n" + L10n.tr(.emptyStateFilterHint),
            actionTitle: L10n.tr(.refresh),
            actionSystemImage: "arrow.clockwise",
            action: { Task { await refreshDisks() } },
            accent: accentColor
        )
        .frame(height: 380)
    }

    private var skeletonList: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonRow()
            }
        }
        .accessibilityLabel(L10n.tr(.loadingDisks))
    }

    // MARK: - 数据

    /// 打开设置面板。
    ///
    /// **走 nil-target 的 `sendAction`**，落点与主菜单的「设置…」（⌘,）、菜单栏面板的
    /// 「设置」**是同一个** `AppDelegate.showSettings` —— 三条入口必然打开**同一个窗口**。
    ///
    /// ## 为什么不再是 `.sheet`（2026-09-16 用户报告「设置窗口无法移动」）
    ///
    /// 这里曾经是 `showSettings = true` + `.sheet`。当时用探针实测过 sheet 窗口的
    /// `_isDraggable = false`、`_draggableFrame` 几乎是空的、**任何位置**按下
    /// `_shouldStartWindowDragForEvent:` 都返回 `false` —— sheet 在 macOS 上是**贴在父窗口上**
    /// 的，用户结构上就拖不动它。而菜单栏 / ⌘, 打开的是独立 `NSWindow`（实测顶部 52pt 可拖）。
    /// 于是同一个「设置」在两个入口下是两种东西，其中一种还拖不动。
    /// 现在统一成独立窗口，顺带删掉了一整套 `.sheet` 分支。
    ///
    /// `assert` 是「接线断了要立刻知道」：`sendAction` 找不到接收者时只是**安静返回 false**，
    /// 表现成「齿轮点了没反应」——正是本项目最忌讳的静默失败。
    ///
    /// **不要为此再加一条 `AppDelegate.instancesRespond(to: #selector(...))` 的测试**：
    /// `#selector` 表达式本身就要编译通过，那种断言恒为真、拦不住任何东西（原先有一条，已删）。
    /// 这条线真正靠的是这里的 `assert` + 编译期解析的 `#selector`；理由详见
    /// `SettingsWindowTests` 里 `// MARK: - 入口` 那段说明。
    private func openSettings() {
        let delivered = NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
        assert(delivered, "设置入口没接上：AppDelegate.showSettings 必须存在且是 @objc")
    }

    private func refreshDisks() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // **刷的是 `store` 自己，不是 `.shared`**：两者在出图/自检里可能是不同实例，
        // 写 `.shared` 会让「刷新」刷新一个本视图没在观察的对象（界面纹丝不动）。
        await store.refresh()
        // 显式再刷一次占用：`DiskListStore.refresh()` 会把新数组赋给 `disks`，
        // 正常情况下 ``OccupancyStore`` 的订阅会跟上；这里 await 一次是为了让
        // 「点刷新 → 按钮转完 → 界面已是新结论」这条链路在**同一帧**收口，
        // 而不是让用户看着旧结论等下一个 tick。
        await occupancyStore.refresh(disks: store.disks)
    }

    // MARK: - 推出

    /// 发起推出。
    ///
    /// **检测只用于展示，不干预决策**：被占用时按钮已经写成红色的「关闭并推出」，
    /// 点击后仍走系统接口——系统返回「忙」才弹确认窗。这样既兑现了「破坏性前置」的
    /// 设计意图，又保留了「有进程占用就失败」这层系统保护（绝不强制卸载）。
    private func eject(_ disk: DiskInfo) {
        ejectingDiskId = disk.id
        Task {
            let outcome = await EjectFlowController.shared.eject(disk: disk)
            ejectingDiskId = nil
            await refreshDisks()
            await EjectUI.handle(outcome, disk: disk)
        }
    }
}

// MARK: - 标题栏按钮（独立子视图以便管理 @State hover 状态）

/// 标题栏 28 × 28 图标按钮（刷新 / 设置）。
///
/// **hover 底色比按钮盒子小一圈**：``DesignTokens/Size/hoverBackgroundInset``（3pt）
/// → 22 × 22、圆角取同心值 ``DesignTokens/Radius/concentric(inset:)``（3）。
/// 点击区域仍是整个 28 × 28（靠 ``contentShape``）—— 底色是视觉，命中区不该跟着缩。
///
/// ⚠️ **`.padding` 只能加在 `.background` 里的形状上**，不能把 `.frame` 挪到它前面：
/// 那样会把 `foregroundStyle(hovering ? …)` 的作用范围一起改掉，
/// 图标颜色就不随 hover 变了（这是「只改一层」时最容易踩的坑）。
struct TitleBarIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering ? DesignTokens.Palette.foreground : DesignTokens.Palette.mutedForeground)
                .frame(
                    width: DesignTokens.Size.titleBarIconButton,
                    height: DesignTokens.Size.titleBarIconButton
                )
                .background(HoverBackground(color: hovering ? DesignTokens.Palette.subtle : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **去 SwiftUI 默认 focus 环**：启动时第一个 Button 会被自动 focus，
        // 蓝色环套在 RefreshButton 上看着像「按钮被高亮选中」——但用户没点任何按钮。
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering = $0 }
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.fast, reduceMotion: reduceMotion),
            value: hovering
        )
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 标题栏的「刷新」按钮：**刷新中就地换成 spinner**，而不是把按钮藏起来。
///
/// 设计稿的语言是「按钮就地变为 spinner、**保留原尺寸（换成 spinner 后不能塌陷）**、
/// 禁用重复点击」（`06-states.html` 的「推出中」；应用里 ``DiskRow`` 已经是这个写法）。
///
/// ## 为什么要单独抽一个类型
///
/// 原写法是：
///
/// ```swift
/// titleBarButton(…)
///     .overlay { if isRefreshing { ProgressView().controlSize(.small) } }
///     .opacity(isRefreshing ? 0 : 1)   // ← 排在 .overlay 之后
/// ```
///
/// `.opacity` 在 `.overlay` **之后**，所以它把 overlay 里的 spinner **一起**调成了透明。
/// 结果是：点一下刷新，箭头消失、spinner 也看不见，那块位置**什么都没有**，
/// 刷新完成后箭头又冒出来 —— 用户 2026-09-16 报告：
/// 「主窗口的刷新点击就消失了，刷新完成后就又出现了」。
///
/// **离屏实测**（`.build/probe/spinneropacity.swift`，判据是墨迹像素数）：
///
/// | 写法 | 墨迹 |
/// |---|---|
/// | 旧写法（`.overlay` 之后才 `.opacity`） | **0** |
/// | `.opacity` 提到 `.overlay` 之前 | 162 |
/// | 本类型的 if/else | 162 |
/// | 对照组 · 纯图标不透明 | 224 |
/// | 对照组 · 空视图 | 0 |
///
/// **对照组不可省**：「0 命中」有两种含义 —— 真的没有，或**渲染通路根本没通**
/// （`NSProgressIndicator` 是动画视图，`cacheDisplay` 有可能抓不到）。
/// 纯图标那组量到 224 才证明这个 0 是「真的没有」。
///
/// ## 改成 if/else 的两个额外好处
///
/// 1. 结构上**不可能**再被后续 modifier 误伤（`.overlay` + `.opacity` 那种写法，
///    谁在后面加一句 `.opacity` / `.blur` / `.saturation` 都会重演同一个 bug）。
/// 2. `isRefreshing` 变成**入参**，于是可以离屏断言 ——
///    旧写法的状态藏在 `@State private var` 里，测试根本够不着（这正是它逃过测试的原因）。
struct RefreshTitleBarButton: View {
    let label: String
    let isRefreshing: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isRefreshing {
                // 尺寸显式钉住 28 × 28：换 spinner 后不能塌陷（设计稿的硬要求）。
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        width: DesignTokens.Size.titleBarIconButton,
                        height: DesignTokens.Size.titleBarIconButton
                    )
                    // 别留一个没标签的 spinner —— VoiceOver 只会念「忙」或干脆跳过，
                    // 用户听不出在忙什么（与 ``DiskRow`` 同一条教训）。
                    .accessibilityLabel(label)
            } else {
                TitleBarIconButton(systemName: "arrow.clockwise", label: label, action: action)
            }
        }
        .disabled(isRefreshing)
        .animation(
            DesignTokens.Motion.animation(DesignTokens.Motion.fast, reduceMotion: reduceMotion),
            value: isRefreshing
        )
    }
}
