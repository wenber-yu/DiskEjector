import AppKit
import SwiftUI

/// 设置面板（设计稿 `05-settings.html` / `.win--settings`）。
///
/// **设计稿规格**：480 × 800，圆角 **12**（与主窗口同一个 `--r-window`），毛玻璃
/// （`.win` 规则：`--bg-glass` + `blur(30) saturate(180%)` + `0.5px var(--border-strong)`）；
/// 头部 52（「设置」+「完成」）；四组内容：外观 / 通用 / 诊断 / 关于。
///
/// **背景与主窗口、菜单面板共用同一个 ``GlassSurface``**。这里曾经叠了三层：
/// `--bg-glass-thick`（0.86，比设计稿白一档）+ SwiftUI `.ultraThinMaterial`
/// （又一种与 `NSVisualEffectView` 不同的材质）+ 圆角 16 + `--border`（0.10）描边 ——
/// 于是同一份设计稿里的三块玻璃出现了三种色温和两种圆角。
///
/// **不变量**：
/// - 偏好键由 ``AppSettings.Key`` 提供、`@AppStorage` 实时持久化
/// - 强调色由 ``AccentColor`` 提供（4 种，与设计稿一致）
/// - 登录启动用 ``LaunchAtLoginManager``，错误按原因分三类提示
///
/// **为什么拆成三个类型**（``SettingsView`` / ``SettingsHeaderBar`` / ``SettingsSectionsColumn``）：
/// 面板高度是常量，内容一旦高于它，面板底部的「关于」就会被折叠线藏在滚动区外
/// —— 用户实测反馈过「设置界面排版不好看」，根因正是内容远高于面板。
/// 拆开后单测能**分别渲染两个子视图、量出它们需要的真实高度**，把
/// 「头部 + 内容 ≤ 面板高度」钉成契约（见 `SettingsLayoutTests`）。
/// SPM 工程没有 Xcode 预览，这是让排版可验证的唯一手段。
struct SettingsView: View {

    /// 「完成」按钮的动作。
    ///
    /// **所有真实入口都传它**（`AppDelegate.makeSettingsWindow()` 里接的是关窗）。
    /// `nil` 时退回 SwiftUI 的 `dismiss` —— 只给离屏出图与单测用：那里没有窗口，
    /// 也不会有人去点「完成」。
    ///
    /// 这里曾经有**第二种真实场景**：主窗口齿轮按钮弹的 `.sheet`（有 presentation 上下文，
    /// `dismiss` 有效）。2026-09-16 那条路删掉了 —— 实测 sheet 的 `_isDraggable = false`、
    /// 任何位置都拖不动，用户报告「设置窗口无法移动」。现在齿轮 / 菜单栏 / ⌘, 三条入口
    /// 统一打开同一个独立窗口（见 ``ContentView/openSettings()``）。
    var onDone: (() -> Void)?

    /// 是否让**玻璃铺满宿主**（而不是刚好等于设计稿的 480×800）。
    ///
    /// - `true`：**独立窗口**用（`AppDelegate.makeSettingsWindow()`）。窗口可能因为
    ///   标题栏安全区被撑高，玻璃必须跟着铺满 —— 否则多出来的那一条会露出桌面。
    ///   实测（2026-09-16，补齐前）：窗口 598、玻璃只有 566（当时的尺寸），**上下各露 16pt**。
    /// - `false`（默认）：离屏出图与单测用。这时要的正是**理想尺寸 480×800**。
    ///   ⚠️ 这条路径**不能**开 `true` —— `.frame(maxHeight: .infinity)` 会让
    ///   `sizeThatFits(in: …greatestFiniteMagnitude)` 量出**无穷高**，
    ///   `writePNG` 里 `Int(∞ * 2)` 直接 SIGTRAP（快照那套代码的注释里记着这个坑）。
    var fillsHost: Bool = false

    /// ⚠️ **仅供离屏出图**：见 ``SettingsSectionsColumn/updateStateOverride``。
    ///
    /// 透传到 ``SettingsSectionsColumn``，让「更新」组那七态各出一张走查图。
    /// 真实入口（`AppDelegate.makeSettingsWindow()`）不传 → 走真实状态。
    var updateStateOverride: UpdateController.CheckRowState?

    /// ⚠️ **仅供离屏出图**：见 ``SettingsSectionsColumn/autoUpdateRowOverride``。
    var autoUpdateRowOverride: AutoUpdateRowState?

    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLoginPrompt: LaunchAtLoginPrompt?

    /// 登录项操作的提示内容。
    private struct LaunchAtLoginPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let offersOpenSettings: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeaderBar {
                if let onDone {
                    onDone()
                } else {
                    dismiss()
                }
            }
            ScrollView {
                SettingsSectionsColumn(
                    onLaunchAtLoginError: { error in
                        launchAtLoginPrompt = prompt(for: error)
                    },
                    updateStateOverride: updateStateOverride,
                    autoUpdateRowOverride: autoUpdateRowOverride
                )
                .padding(.bottom, SettingsMetrics.bottomInset)
            }
            .scrollContentBackground(.hidden)
        }
        // **两层 frame 分工不同，别合并成一层**（与 ``ContentView`` 同一处理，
        // 主窗口的「标题栏露底」就是这么来的）：
        // - 内层 = **设计稿尺寸** 480×800，内容按它排版；
        // - 外层 = **填满宿主**（窗口），``GlassSurface`` 铺在这一层上。
        //   少了外层，「玻璃铺满整窗」就退化成依赖「窗口高恰好等于内容高」这个巧合 ——
        //   巧合一破（窗口被安全区撑到 598）就上下各露 16pt。
        //
        // 外层只在独立窗口里加：`maxWidth/maxHeight` 传 `nil` 是 no-op，
        // 于是离屏出图与单测拿到的仍是理想尺寸 480×800（理由见 ``fillsHost``）。
        .frame(
            width: DesignTokens.Size.settingsPanel.width,
            height: DesignTokens.Size.settingsPanel.height
        )
        .frame(
            maxWidth: fillsHost ? .infinity : nil,
            maxHeight: fillsHost ? .infinity : nil
        )
        .background(GlassSurface(cornerRadius: DesignTokens.Radius.window))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.window, style: .continuous))
        .alert(item: $launchAtLoginPrompt) { prompt in
            guard prompt.offersOpenSettings else {
                return Alert(
                    title: Text(prompt.title),
                    message: Text(prompt.message),
                    dismissButton: .default(Text(L10n.tr(.ok))))
            }
            return Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text(L10n.tr(.openSystemSettings))) {
                    LaunchAtLoginManager.openSystemSettings()
                },
                secondaryButton: .cancel(Text(L10n.tr(.ok)))
            )
        }
    }

    /// 登录项错误 → 提示内容（三类原因各自文案）。
    private func prompt(for error: LaunchAtLoginError) -> LaunchAtLoginPrompt {
        switch error {
        case .requiresApproval:
            return LaunchAtLoginPrompt(
                title: L10n.tr(.launchAtLoginNeedsApprovalTitle),
                message: L10n.tr(.launchAtLoginNeedsApprovalMessage),
                offersOpenSettings: true)
        case .notFound:
            return LaunchAtLoginPrompt(
                title: L10n.tr(.launchAtLoginErrorTitle),
                message: L10n.tr(.launchAtLoginUnavailableMessage),
                offersOpenSettings: false)
        case .system(let text):
            LogService.shared.log(disk: nil, message: "登录项设置失败: \(text)")
            return LaunchAtLoginPrompt(
                title: L10n.tr(.launchAtLoginErrorTitle),
                message: L10n.tr(.launchAtLoginErrorMessage),
                offersOpenSettings: false)
        }
    }
}

// MARK: - 排版度量

/// 设置面板的排版度量（视图与布局契约测试共用同一份数字）。
enum SettingsMetrics {
    /// 面板内容左右内边距（设计稿 `.settings__body { padding: 20px 20px 16px }`）。
    static let sectionPaddingH: CGFloat = DesignTokens.Spacing.xl
    /// 滚动内容底部留白（设计稿 16）。
    static let bottomInset: CGFloat = DesignTokens.Spacing.lg
    /// 头部高度（设计稿 `.shead { height: 52px }`）。
    ///
    /// **由「内容带 + 下方留白」拼出来，而不是独立写一个 52**：这样「标题与主窗口标题
    /// 同高」这件事只由 ``DesignTokens/Size/titleBarBandHeight`` 一个数字决定，
    /// 头部总高自动跟着走，不会出现「改了带高忘了改总高」。
    /// 与设计稿的 52 是否一致由 `TitleBarBaselineTests` 断言。
    static let headerHeight: CGFloat =
        DesignTokens.Size.titleBarBandHeight + DesignTokens.Size.titleBarBandBottomPadding

    // MARK: 头部左右内边距

    /// 头部**前导**内边距（设计稿 `.shead { padding: 0 16px }`）。
    ///
    /// ⚠️ 这里**曾经是 20**（`.xl`）—— 那时设置面板还画着系统红绿灯，得先让位 52pt，
    /// 前导加到 20 才能让两个窗口的标题都落在 x = 80。
    /// 2026-09-16 按用户要求**去掉红绿灯**（见 ``SettingsWindow``）之后让位没了，
    /// 这个数就**回到设计稿字面的 16**。
    static let headerPaddingLeading: CGFloat = DesignTokens.Spacing.lg
    /// 头部**尾随**内边距（设计稿同样是 16，不跟主窗口的 12）。
    static let headerPaddingTrailing: CGFloat = DesignTokens.Spacing.lg
    /// 头部 `HStack` 的子项间距（标题 / 弹性空档 / 「完成」之间）。
    ///
    /// 必须与视图里的 `HStack(spacing:)` 同源。**它不再参与「标题左边界」的计算** ——
    /// 让位块删掉之后，标题就是头部的第一个子项，左边界就等于前导内边距本身。
    static let headerSpacing: CGFloat = DesignTokens.Spacing.sm

    /// 分组标题行高（11pt 文字 + 下方 6pt 间距）。
    static let groupTitlePaddingBottom: CGFloat = 6
    /// 分组之间的间距（设计稿 `.sgroup + .sgroup { margin-top: 20px }`）。
    static let groupSpacing: CGFloat = DesignTokens.Spacing.xl
    /// 设置行内边距（设计稿 `.sline { padding: 11px 12px; min-height: 44px }`）。
    static let linePaddingV: CGFloat = 11
    static let linePaddingH: CGFloat = DesignTokens.Spacing.md
    static let lineMinHeight: CGFloat = 44
}

// MARK: - 头部（"设置" + "完成"）

/// 设置面板头部（设计稿 `.shead`）。
///
/// **单独抽出来是为了可测**：``SettingsSectionsColumn`` 的可用高度 = 面板高 − 本视图高，
/// 契约测试要分别量出两者，才能断言「内容不会被折叠线藏起来」。
///
/// **横向**：就是设计稿 `.shead { padding: 0 16px }` 的字面写法 —— 左「设置」、右「完成」、
/// 中间弹性空档，两侧各 16。**这里曾经插过一个 `Color.clear.frame(width: 52)` 给系统红绿灯让位**
/// （`DESIGN-SPEC.md` §8.11.4）；2026-09-16 把红绿灯整个藏掉之后，那个让位块连同
/// 「让位宽度」这个常量一起删了 —— 见 ``SettingsWindow`` 与 §8.17。
///
/// **纵向对齐**：头部总高 52，内容（「设置」+「完成」）就在 52 里**居中**，中心距顶 26pt。
///
/// 本面板**自己不画红绿灯**，这个 26pt 单纯来自设计稿 —— DOM 探针实测 `.shead__title`
/// 与「完成」按钮的中心**都在 26pt**，与主窗口 `.titlebar` 逐项相同。
/// 两边共用 ``DesignTokens/Size/titleBarBandHeight`` 一个数字，
/// 数字来源与「系统交通灯怎么对齐过来」见那里的说明。主窗口的 `titleBar` 同源。
struct SettingsHeaderBar: View {

    let onDone: () -> Void

    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    var body: some View {
        HStack(spacing: SettingsMetrics.headerSpacing) {
            Text(L10n.tr(.settings))
                .font(.system(size: DesignTokens.FontSize.title, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
            Spacer(minLength: 0)
            ActionButton(
                title: L10n.tr(.done),
                variant: .outline,
                size: .small,
                accent: AccentColor(rawValue: accentColorRaw) ?? .default,
                action: onDone
            )
        }
        .padding(.leading, SettingsMetrics.headerPaddingLeading)
        .padding(.trailing, SettingsMetrics.headerPaddingTrailing)
        // **内容带 + 下方留白**，不是直接 `.frame(height: 52)`。
        //
        // 保留「带 + 留白」这个结构是为了让「标题栏总高」只有一个来源：
        // 留白现在是 0，内容带吃满 52 —— 于是「设置」两个字居中到距顶 **26pt**，
        // 与设计稿 `.shead`（探针实测标题中心 26）、也与主窗口（交通灯已被
        // ``AppDelegate/alignTrafficLights(in:)`` 挪到 26）一致。
        // 数字只写在 ``DesignTokens/Size/titleBarBandHeight`` 一处，主窗口的 `titleBar` 同源。
        .frame(height: DesignTokens.Size.titleBarBandHeight)
        .padding(.bottom, DesignTokens.Size.titleBarBandBottomPadding)
        .overlay(alignment: .bottom) {
            Hairline()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 四组内容

/// 「自动更新」那一行的展示状态 —— **仅供离屏出图 / 预览**。
///
/// **为什么需要它**：这一行有两个输入是**跑出图那个进程的环境**决定的 ——
/// 开关值来自 Sparkle 的 `SPUUpdaterSettings`，而「宿主是否允许自动更新」
/// 由**构建有没有正确签名**决定。走查图跑在 xctest 进程里（未签名）→
/// 宿主不具备自动更新能力（出图进程里 updater 没建起来）→ 这一行**永远画成禁用态**，
/// 与设计稿 `08-update.html` 里开关打开的画法对不上（§8.44.4）。
///
/// 出图时按**设计稿假设的环境**（允许 + 开）渲染，这一行才能与设计稿并排比；
/// 「不允许」那一态另有单独一张图，不会被丢掉。
///
/// ⚠️ 与 ``SettingsSectionsColumn/autoUpdateOverride`` **不是一回事**：
/// 那个是「用户本次拨动后的覆盖值」（运行时会变，生产路径在用），
/// 这个是**只在出图时**注入的静态值。别把两者合并。
struct AutoUpdateRowState: Equatable {
    /// 开关是不是开着的。
    var isOn: Bool
    /// 宿主是否允许自动更新（真实环境下由签名状态决定）。
    var isAllowed: Bool
}

/// 设置面板的四组内容（不含头部与滚动容器）。
///
/// **自己读偏好、不接收绑定**：这样契约测试可以直接 `SettingsSectionsColumn { _ in }`
/// 构造真实视图量高度，不必在测试里搭一套假的绑定。
/// 唯一需要上抛的是登录项的失败原因（宿主负责弹 alert）。
struct SettingsSectionsColumn: View {

    /// 登录项操作失败时上抛（宿主弹提示；测试里给空实现）。
    var onLaunchAtLoginError: (LaunchAtLoginError) -> Void = { _ in }

    /// ⚠️ **仅供离屏出图 / 预览**：`nil` 时走真实状态 ``UpdateController/rowState``。
    ///
    /// **为什么需要它**：七态里「下载中 / 已就绪 / 失败」在真机上造不出来
    /// （要真实的 appcast + 下载 + 签名校验），而它们恰恰是最需要走查的三种画法 ——
    /// 没有这个口子，走查图永远只有首帧那一态，等于**没画过的状态没人看过**。
    ///
    /// **为什么注入的是「状态」而不是 ``UpdateController/phase``**：`phase` 只是
    /// ``UpdateController/rowState(phase:skippedVersion:lastCheck:)`` 的三个输入之一，
    /// 另外两个（已跳过的版本、上次检查时间）来自 `UserDefaults` ——
    /// 只注入 `phase` 会留下两个不确定输入，出图**不可复现**。
    /// 注入「状态」跳过的只有那个**纯函数**，而它每条分支都有自己的单测
    /// （`UpdateSettingsTests.行状态的优先级`）。
    ///
    /// ⚠️ **不要**改成「给 `UpdateController.shared` 塞一个假 phase」——
    /// 那会连带编出假的进度、假的「可以取消」，与 §8.30 记的「夹具保真度」是同一个坑。
    var updateStateOverride: UpdateController.CheckRowState?

    /// ⚠️ **仅供离屏出图 / 预览**：`nil` 时走真实值（Sparkle + 宿主签名状态）。
    /// 理由见 ``AutoUpdateRowState``。
    var autoUpdateRowOverride: AutoUpdateRowState?

    @AppStorage(AppSettings.Key.visualStyle) private var visualStyleRaw = VisualStyle.default.rawValue
    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue
    @AppStorage(AppSettings.Key.appLanguage) private var appLanguageRaw = AppLanguage.default.rawValue
    @AppStorage(AppSettings.Key.showDockIcon) private var showDockIcon = false
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled

    /// 用户本次拨动「自动更新」后的值；`nil` = 还没拨过，直接读 Sparkle。
    ///
    /// **为什么是「覆盖值」而不是一个镜像布尔**：镜像需要一个「加载完了吗」的位，
    /// 否则首帧会把 Sparkle 的默认值（开）显示成关。这里反过来 —— 没拨过就读真值，
    /// 永远不可能显示错的初始状态，也不需要那个位。
    @State private var autoUpdateOverride: Bool?

    /// 「更新」组要跟着 ``UpdateController/phase`` 变 —— 下载进度、已就绪、失败
    /// 三个状态都是**别人推着走**的（Sparkle 的回调），不订阅就永远停在首帧那一态。
    @ObservedObject private var updateController = UpdateController.shared

    private var accentColor: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

    /// 用户选的语言（`@AppStorage` 侧）。
    private var appLanguage: AppLanguage { AppLanguage.resolve(appLanguageRaw) }

    /// 「改了语言但还没重启」的第三态。
    ///
    /// 判定走 ``LanguageManager/isRestartPending(preferred:active:)`` 这个纯函数，
    /// 不读 ``LanguageManager/preferred`` —— 视图的值来自 `@AppStorage`，
    /// 两者在刷新时序上可能差一帧，混用会出现「下拉已经变了、说明还是旧的」。
    private var languageRestartPending: Bool {
        LanguageManager.isRestartPending(preferred: appLanguage)
    }

    // 这里**没有** `private var visualStyle` —— 它曾经存在且从未被使用（死代码）：
    // 本视图只需要把 raw 值交给分段控件，真正消费这个偏好的是 ``GlassSurface``
    // （窗口底色）。留一个没人读的解析属性，会让人以为「切换外观」的接线在本文件里。

    /// 从 Info.plist 读取版本号（打包时注入），缺失时回退 "1.0.0"。
    ///
    /// ⚠️ **不要为了让走查图「对上设计稿」去改这个兜底值**（2026-09-16 差点踩到）。
    ///
    /// 设计稿 `05-settings.html` 里写的是 `版本 1.0.0 · 构建 42`，而设计对照图上
    /// 实现侧显示的是 `构建 1` —— 看起来像「实现没读出版本号」，实际是**渲染夹具的产物**：
    /// 走查快照由**测试进程**渲染，它的 `Bundle.main` 是 xctest runner，
    /// **没有 `CFBundleShortVersionString` / `CFBundleVersion` 这两个键** → 落到这里的兜底值。
    ///
    /// 真机 app 读得到，值是 `2026.09.13.1` / `44`（`build_app.sh` 按提交数写入
    /// `Info.plist`，已用 `PlistBuddy` 核对）。
    ///
    /// 若把兜底值改成设计稿的 `42`，对照图会「对上」，但真机上万一读不到 plist
    /// 就会显示一个**假版本号** —— 用户报问题时给出的版本号会指向一个不存在的构建。
    /// **设计稿里的样本值（版本号、构建号、磁盘名）不是规格。**
    private var appVersion: String {
        AppVersionInfo.shortVersion() ?? "1.0.0"
    }

    /// 构建号，与版本号一并展示便于用户反馈问题时定位。兜底值的理由见 ``appVersion``。
    private var buildNumber: String {
        AppVersionInfo.build() ?? "1"
    }

    /// 分发渠道显示名。**必须区分**开发构建与正式直发构建：`DEBUG` 构建既没公证、
    /// 也不代表可分发状态，一律写成「官网直发版」会让使用者误判自己拿到的是可分发产物。
    ///
    /// （`.appStore` 分支已随「不上架 MAS」删除——渠道不存在，就没有第三个名字要显示。）
    private var channelName: String {
        switch UpdateService.channel {
        case .direct:
            return L10n.tr(.updateChannelDirect)
        case .development:
            return L10n.tr(.updateChannelDevelopment)
        }
    }

    // MARK: 「语言」行

    /// 「语言」行的说明。
    ///
    /// 三态，**每一态都要有可见落点**：
    /// - 跟随系统 → 「跟随系统语言（当前：简体中文）」；
    /// - 选了某个具体语言且**已生效** → 「当前：English」；
    /// - 选了但**还没重启** → 「将在重启后切换为 English」（并多出「立即重启」按钮）。
    ///
    /// 最后一态是必须的：macOS 只在启动时读 `AppleLanguages`，改完不可能当场生效。
    /// 不写出来，用户无法分辨「本来就要等重启」和「这个功能坏了」
    /// —— 与登录项「等待系统批准」、更新「已跳过 1.1.0」是同一类错误。
    private var languageDescription: String {
        if languageRestartPending {
            return String(format: L10n.tr(.languagePendingHintFormat), appLanguage.displayName)
        }
        switch appLanguage {
        case .system:
            return String(
                format: L10n.tr(.languageFollowSystemHintFormat),
                LanguageManager.active.displayName)
        default:
            return String(format: L10n.tr(.languageInEffectHintFormat), appLanguage.displayName)
        }
    }

    /// 「语言」行右侧的控件：下拉 + （待重启时）「立即重启」。
    ///
    /// **单独抽出来是为了让编译器喘口气**：整段塞在 `body` 里时，
    /// `SettingsPopUp` 的泛型 + `Binding(get:set:)` + `if` 分支会让类型检查器放弃，
    /// 报成 `failed to produce diagnostic for expression`（错误位置指在 `var body` 上）。
    @ViewBuilder
    private var languageControl: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            SettingsPopUp(
                items: AppLanguage.allCases,
                title: { $0.displayName },
                // 写回走 ``LanguageManager/apply(_:)`` —— 它同时更新 `appLanguage` 偏好
                // 与 `AppleLanguages`（系统认得的那个键）。只写前者的话，
                // 界面会显示「已选 English」而下次启动仍然是中文。
                selection: Binding(
                    get: { appLanguage },
                    set: { LanguageManager.apply($0) }
                ),
                accessibilityLabel: L10n.tr(.appLanguage)
            )
            // 第三态才出现的「立即重启」：让这个状态**可立刻见效**，
            // 而不是让人干等或去猜（设计稿 spec-note）。
            if languageRestartPending {
                ActionButton(
                    title: L10n.tr(.restartNow),
                    variant: .outline,
                    size: .small,
                    accent: accentColor,
                    action: { LanguageManager.restart() }
                )
            }
        }
    }

    // MARK: 「更新」组

    /// 自动更新开关的当前值。
    ///
    /// **真值在 Sparkle 那边**（`SPUUpdaterSettings`，写进同一份 UserDefaults），
    /// 这里不另存偏好 —— 见 ``AppSettings`` 顶部那段说明。
    private var autoUpdateOn: Bool {
        autoUpdateRowOverride?.isOn ?? autoUpdateOverride
            ?? UpdateController.shared.automaticallyChecksForUpdates
    }

    /// 宿主是否允许自动更新。
    ///
    /// ⚠️ **判据不看这个开关自己的值**（2026-09-21 真机修的 bug，§8.113.14）：
    /// 旧实现读 Sparkle 的 `allowsAutomaticUpdates`，而它在本应用里**恒等于
    /// 「自动检查」这个开关的当前值** ⇒ 用户关一次 ⇒ 整行 `onTap` 变 `nil`
    /// ⇒ **再也打不开**（重启也没用）。⇒ 判据是「updater 建没建起来」。
    private var canAutoUpdate: Bool {
        autoUpdateRowOverride?.isAllowed ?? UpdateController.shared.canAutoUpdate
    }

    /// 「自动更新」行的说明。不允许自动更新时**必须说明原因** ——
    /// 否则用户看到的是一个拨不动的开关，却不知道为什么。
    private var autoUpdateDescription: String {
        canAutoUpdate ? L10n.tr(.autoUpdateHint) : L10n.tr(.autoUpdateUnavailableHint)
    }

    /// 拨动「自动更新」。
    ///
    /// **一个开关驱动 Sparkle 的两个标志**：Sparkle 把「检查」与「下载」分成两级
    /// （`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate`），而设计稿只有一个开关
    /// —— 只开检查不开下载的话，用户开了「自动更新」却发现从没自动下载过，
    /// 那不是他要的。关的时候两级一起关，避免留下一个半开的状态。
    ///
    /// ⚠️ **不碰 `SUAutomaticallyUpdate` 的「静默强装」语义**：Sparkle 只在应用**退出时**
    /// 安装，不会在用户干活时重启（设计稿那句「并在下次启动时安装」说的就是这件事）。
    ///
    /// ⚠️ **两级都要写，且顺序见函数体**（2026-09-21）：早先这里写的是「两级一起关」，
    /// 实测**只关掉了一级**（`SUAutomaticallyUpdate` 的 setter 在 allows 为假时空操作）。
    private func toggleAutoUpdate() {
        let newValue = !autoUpdateOn
        // ⚠️ **两个标志的写入顺序有讲究**（2026-09-21 真机实测，§8.113.15）：
        // Sparkle 的 `automaticallyDownloadsUpdates` setter 在 `allowsAutomaticUpdates`
        // 为假时是**空操作**（连键都不写）—— 而它算的是
        // `SUAllowsAutomaticUpdates ?? automaticallyChecksForUpdates`，本应用没写前者
        // ⇒ 它**跟着 checks 走**。于是：
        //   - **开**：先写 checks（让 allows 变真）再写 downloads ⇒ 两个键都写得进去；
        //   - **关**：**反过来**，先写 downloads（此时 allows 还为真）再写 checks。
        // 顺序写反 ⇒ 关掉之后 `SUAutomaticallyUpdate` 停在旧值 1（实测：干净的关
        // 只写了 `SUEnableAutomaticChecks = 0`）。有效行为目前被 getter 与 allows
        // 相与掩盖，但**存储与意图不一致**，读 defaults 的人会被它骗（我自己就中过）。
        if newValue {
            UpdateController.shared.automaticallyChecksForUpdates = true
            UpdateController.shared.automaticallyDownloadsUpdates = true
        } else {
            UpdateController.shared.automaticallyDownloadsUpdates = false
            UpdateController.shared.automaticallyChecksForUpdates = false
        }
        autoUpdateOverride = newValue
    }

    /// 「自动更新」那一行的点击动作；不允许自动更新时为 `nil`（整行不可点）。
    private var autoUpdateTapAction: (() -> Void)? {
        guard canAutoUpdate else { return nil }
        return { toggleAutoUpdate() }
    }

    /// 「更新」组的第二行 —— **一个状态机，七种画法**（设计稿 `08-update.html` B 段 + C 段矩阵）。
    ///
    /// **为什么这一行不是「固定文案 + 固定按钮」**：设计稿把「发现新版本」「后台下载中」
    /// 「已就绪」「下载失败」四种中间状态**全部就地画在这一行上** —— 不弹遮罩、不加横幅、
    /// 不往主窗口塞东西。后台更新的全部意义就是别打扰用户。
    /// 而每种状态下**能做的事不一样**（查看更新 / 取消 / 立即重启 / 重试），
    /// 所以按钮也跟着状态走。
    ///
    /// **文案与判定都不在这里做**：判定是 ``UpdateController/rowState(phase:skippedVersion:lastCheck:)``
    /// 这个纯函数（可以逐态断言），视图只负责把它翻译成人话。
    /// 视图里 if/else 拼字符串就没法断言 —— 测试只能去比本地化的日期文本，
    /// 换台机器或换个语言必红，且红的原因与被测代码无关。
    ///
    /// ⚠️ **`.ready` 那一态故意不再显示「检查更新」按钮**：Sparkle 正在等我们回答
    /// `.install`（`sessionInProgress` 为真），此时点「检查更新」是**没有反应**的
    /// （见 ``UpdateController/readyReply``）。给一个点了没反应的按钮，
    /// 与「功能坏了」长得一模一样 —— 所以那一态换成「立即重启」。
    @ViewBuilder
    private var updateCheckLine: some View {
        switch updateStateOverride ?? updateController.rowState {
        case .neverChecked:
            line(
                label: L10n.tr(.checkForUpdates),
                description: L10n.tr(.updateNeverChecked)
            ) { checkForUpdatesButton }

        case .upToDate(let date):
            line(
                label: L10n.tr(.checkForUpdates),
                description: String(
                    format: L10n.tr(.updateUpToDateFormat),
                    Self.updateCheckDateFormatter.string(from: date))
            ) { checkForUpdatesButton }

        case .skipped(let version):
            line(
                label: L10n.tr(.checkForUpdates),
                description: String(format: L10n.tr(.updateSkippedFormat), version)
            ) { checkForUpdatesButton }

        case .checking:
            // ⚠️ **不给按钮**：此刻 Sparkle 正跑着，点「检查更新」是没有反应的
            // （`checkForUpdates()` 会先回到 `.idle` 再重来一遍，用户只看到闪一下）。
            // 给一个点了没反应的按钮，与「功能坏了」长得一模一样 —— 同 `.ready` 那条判据。
            //
            // ⚠️ **必须带 `description`**：面板是固定高度，而其余各态都有第二行
            // （进度条 / 说明 / 上次检查）。只有 label 的话实测会比别态矮 ——
            // §8.82 就是这么抓到「下载中（无百分比）」那一态的（矮 14.8pt）。
            line(
                label: L10n.tr(.updateChecking),
                description: L10n.tr(.updateCheckingHint)
            ) {
                EmptyView()
            }

        case .found(let version, let lastCheck):
            line(
                label: L10n.tr(.checkForUpdates),
                description: foundDescription(version: version, lastCheck: lastCheck),
                // 设计稿 B2 给这一行上了强调色：它是「有件事等你决定」，
                // 而其余几态都只是在陈述事实。
                descriptionAccent: true
            ) { viewUpdateButton }

        case .downloading(let version, let fraction):
            // `fraction == nil` = **百分比无从得知**（自动更新开着时那条路，§8.81）：
            // 那条路既不提供进度、也不提供取消入口
            // （`showDownloadInitiatedWithCancellation:` 由 `SPUUIBasedUpdateDriver` 发出，
            // 而自动那条路不经过它）。所以这一态**不画进度条、也不给「取消」** ——
            // 画一条停在 0% 的进度条、或给一个点了没反应的「取消」，
            // 都比什么都不画更让人怀疑（设计稿 B3 那条「百分比是真的，ETA 是编的」）。
            if let fraction {
                line(
                    label: String(format: L10n.tr(.updateDownloadingFormat), version),
                    progress: fraction
                ) { cancelUpdateButton }
            } else {
                // ⚠️ **这一支必须带一行说明，不能只有 label**（2026-09-19 实测，§8.82）：
                // 面板是**固定高度**，而其余各态都有第二行（进度条 / 说明 / 上次检查）——
                // 这一支既没有进度条也没有说明 ⇒ 实测比别态矮 **14.8pt**
                // ⇒ 切到这一态时底部会多出一条空白带（「更新行各态渲染出来必须一样高」
                // 就是这么抓到它的：走查图清单补上这一态之后立刻变红）。
                //
                // ⚠️ 这句说明必须对 `fraction == nil` 的**两种来源**都成立：
                // ① 自动那条路（全程 nil，终点是「退出应用时安装」）；
                // ② 手动那条路刚开始下载的那一瞬（随后有真进度，终点是「自动重启」）。
                // 所以只能说两句共同的那一句「下载完成后会自动安装」，
                // 不能写「退出时安装」—— 那对第 ② 种是假的。
                line(
                    label: String(format: L10n.tr(.updateDownloadingFormat), version),
                    description: L10n.tr(.updateDownloadingHint)
                ) {
                    EmptyView()
                }
            }

        case .ready(let version):
            line(
                label: String(format: L10n.tr(.updateReadyFormat), version),
                description: L10n.tr(.updateReadyHint)
            ) { restartUpdateButton }

        case .failed(let version):
            line(
                label: String(format: L10n.tr(.updateFailedFormat), version),
                description: L10n.tr(.updateFailedHint)
            ) { retryUpdateButton }

        case .installFailed(let version):
            // ⚠️ **不复用 `updateFailedFormat` / `updateFailedHint`**（2026-09-22，账本第 43 行）：
            // 那两条写的是「下载失败 / 网络不可用」，而这一态**下载是成功的**
            // （失败的是解压 / 验签 / 安装）。用户照着「网络不可用」会去查网络，
            // 而真相跟他网络无关 —— 那是句谎，且这一态会一直挂着（不会一闪而过）。
            //
            // 「重试」仍然是同一个按钮：它走 `retryDownload()` ⇒ 重新检查并再走一遍
            // ⇒ 对「装不上去」是一次**真的**重试（不是点了没反应）。
            line(
                label: String(format: L10n.tr(.updateInstallFailedFormat), version),
                description: L10n.tr(.updateInstallFailedHint)
            ) { retryUpdateButton }

        case .locationBlocked:
            // ⚠️ **不给按钮**：我们没法替用户把 `.app` 搬进「应用程序」文件夹，
            // 而「重试」在只读卷上**必然再失败**（Sparkle 连 appcast 都不会去取，
            // §8.94）—— 那就是下一个「点了没反应的按钮」。
            //
            // 这一态替换掉的是原先的**谎报**：只读卷上检查更新后，界面会说
            // 「已是最新版本」并把「上次检查」刷成当下，而它其实**一次网络请求都没发**。
            line(
                label: L10n.tr(.updateLocationBlocked),
                description: L10n.tr(.updateLocationBlockedHint)
            ) {
                EmptyView()
            }
        }
    }

    /// 「发现新版本」那一行的说明（设计稿 B2：`发现 1.1.0 · 上次检查：今天 14:30`）。
    ///
    /// 上次检查时间缺失时退化成不带时间的写法 —— **不能显示成「上次检查：」后面空着**，
    /// 那看起来像「时间没读出来」，而不是「还没检查过」。
    private func foundDescription(version: String, lastCheck: Date?) -> String {
        guard let lastCheck else {
            return String(format: L10n.tr(.updateFoundShortFormat), version)
        }
        return String(
            format: L10n.tr(.updateFoundFormat), version,
            Self.updateCheckDateFormatter.string(from: lastCheck))
    }

    // MARK: 「更新」组的五个按钮（各自绑一个动作，不是同一段代码换标题）

    private var checkForUpdatesButton: some View {
        ActionButton(
            title: L10n.tr(.checkForUpdates),
            variant: .outline,
            size: .small,
            accent: accentColor,
            // 走 Sparkle：由它负责下载与安装，UI 只负责发起。
            // updater 起不来时 `checkForUpdates()` 内部会退回打开 Releases 页并记日志。
            action: { UpdateController.shared.checkForUpdates() }
        )
    }

    /// 「查看更新」是**主按钮**（设计稿 B2）：用户按过 Esc 之后，
    /// 这一行是唯一能回到弹窗的入口，它必须比「检查更新」更显眼。
    private var viewUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.updateView),
            variant: .primary,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.presentFoundUpdate() }
        )
    }

    private var cancelUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.cancel),
            variant: .outline,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.cancelDownload() }
        )
    }

    private var restartUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.restartNow),
            variant: .primary,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.installReadyUpdate() }
        )
    }

    private var retryUpdateButton: some View {
        ActionButton(
            title: L10n.tr(.updateTryAgain),
            variant: .outline,
            size: .small,
            accent: accentColor,
            action: { UpdateController.shared.retryDownload() }
        )
    }

    /// 「上次检查」的时间格式（设计稿是「今天 14:30」）。
    ///
    /// `doesRelativeDateFormatting` 负责把当天说成「今天」；**它跟随 `Locale.current`** ——
    /// 所以断言不许比这个字符串（见 ``updateStatusDescription`` 的说明）。
    private static let updateCheckDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            group(title: L10n.tr(.settingsGroupAppearance)) {
                settingsCard {
                    line(
                        label: L10n.tr(.visualEffects),
                        description: L10n.tr(.transparentModeFootnote),
                        divider: false
                    ) {
                        SettingsSegmentedControl(
                            // 可见标签用**短名**（设计稿规定「透明」/「色调」），
                            // 长名交给无障碍朗读 —— 两者都要，不能只留一个。
                            options: VisualStyle.allCases.map { ($0.rawValue, $0.shortName, $0.displayName) },
                            selection: $visualStyleRaw,
                            accent: accentColor
                        )
                    }
                    line(label: L10n.tr(.accentColor)) {
                        accentSwatches
                    }
                }
            }
            group(title: L10n.tr(.settingsGroupGeneral)) {
                settingsCard {
                    // 语言行是「通用」组的第一行（设计稿 `05-settings.html` 的位置）。
                    // 顺序有理由：它是这一组里**唯一会「改了不立刻生效」**的一项，
                    // 放在最前面，用户改完往下看时不会以为自己漏了什么。
                    line(
                        label: L10n.tr(.appLanguage),
                        description: languageDescription,
                        divider: false
                    ) {
                        languageControl
                    }

                    // 设计稿这一行**只有标签、没有说明**（`.sline` 实测 44pt）。
                    // 曾给它加了一句「在 Dock 与 App 切换器中显示图标。」，
                    // 于是整行 44 → 59，四组内容比设计稿高出 15pt，
                    // 当时的面板（566pt）装不下，「关于」又被挤出滚动区。
                    // 「在 Dock 中显示图标」本身已经说清了后果，不需要再解释一遍。
                    line(
                        label: L10n.tr(.showDockIcon),
                        onTap: { showDockIcon.toggle() },
                        accessibilityValue: L10n.tr(showDockIcon ? .on : .off)
                    ) {
                        SettingsSwitch(isOn: showDockIcon, accent: accentColor)
                    }
                    line(
                        label: L10n.tr(.launchAtLogin),
                        description: launchAtLoginDescription,
                        onTap: toggleLaunchAtLogin,
                        accessibilityValue: L10n.tr(launchAtLogin ? .on : .off)
                    ) {
                        SettingsSwitch(isOn: launchAtLogin, accent: accentColor)
                    }
                }
            }
            group(title: L10n.tr(.settingsGroupDiagnostics)) {
                settingsCard {
                    line(
                        label: L10n.tr(.logSectionTitle),
                        description: L10n.tr(.logSectionHint),
                        divider: false
                    ) {
                        // 设计稿这里是**行尾文字链接**（`.linkbtn`，图标在文字右侧），
                        // 不是描边按钮 —— 详情见 ``TextLinkButton``。
                        TextLinkButton(
                            title: L10n.tr(.revealLogInFinder),
                            // 设计稿的图标是 `externalLink`（ds.js）：**一个方框 + 一支
                            // 从方框右上角伸出去的箭头**，语义是「跳到别的地方去」。
                            // 曾经用 `arrow.up.forward`（一支裸箭头）—— 那是「向前/上一个」，
                            // 与「在访达里打开」不搭；裸箭头也读不出「会离开本应用」这层意思。
                            systemImage: "arrow.up.forward.square",
                            accent: accentColor,
                            action: { LogService.shared.revealLogInFinder() }
                        )
                    }
                }
            }
            group(title: L10n.tr(.settingsGroupUpdates)) {
                settingsCard {
                    line(
                        label: L10n.tr(.autoUpdate),
                        description: autoUpdateDescription,
                        divider: false,
                        // 宿主不具备能力时**整行不可点** —— 否则用户点一下、
                        // 开关动一下、实际什么都没发生（updater 没建起来，没人会去写那两个标志）。
                        // 「设了没生效」与「没设」不能长得一样。
                        //
                        // ⚠️ **这个条件不许读开关自己的值**（2026-09-21 真机修的 bug）：
                        // 读了就变成单向开关 —— 关一次就再也打不开（§8.113.14）。
                        //
                        // ⚠️ 抽成属性而不是在这里写三元：`onTap` 的类型是 `(() -> Void)?`，
                        // 三元的两个分支是「方法引用」与 `nil`，编译器推不出那个可选闭包的
                        // 类型，于是整段 `body` 报 `failed to produce diagnostic for expression`
                        // —— 错误位置指在 `var body` 上，与真正的病根隔着 200 行。
                        onTap: autoUpdateTapAction,
                        accessibilityValue: L10n.tr(autoUpdateOn ? .on : .off)
                    ) {
                        SettingsSwitch(isOn: autoUpdateOn, accent: accentColor)
                    }
                    // 第二行是**一个状态机**（七种画法），见 ``updateCheckLine``。
                    updateCheckLine
                }
            }
            aboutRow
        }
        .padding(.horizontal, SettingsMetrics.sectionPaddingH)
        .padding(.top, SettingsMetrics.sectionPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 分组骨架

    @ViewBuilder
    private func group<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: DesignTokens.FontSize.groupTitle, weight: .semibold))
                .tracking(0.55)
                .textCase(.uppercase)
                .foregroundStyle(DesignTokens.Palette.textStrong)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.groupTitle
                )
                .padding(.horizontal, SettingsMetrics.linePaddingH)
                .padding(.bottom, SettingsMetrics.groupTitlePaddingBottom)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// 卡片容器（设计稿 `.scard`）：`bg-raised` + 内描边 + e1，行与行之间有内缩分隔线。
    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 0.5)
        )
        .shadow(
            color: DesignTokens.Elevation.e1.color,
            radius: DesignTokens.Elevation.e1.radius,
            y: DesignTokens.Elevation.e1.y
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }

    /// 一行设置项（设计稿 `.sline`）：左侧标签 + 可选说明，右侧控件。
    ///
    /// `divider` 只应给**卡片内第二行起**的行设为 `true` —— 设计稿的规则是
    /// `.sline + .sline`，首行上方不该顶着一条横线（那会让卡片看起来被切成两半）。
    ///
    /// `onTap` 用于开关行 —— **整行可点**，不只是那 38×22 的小开关。
    /// 只把小开关做成命中区时，用户瞄准「开关」稍有偏差就点空、什么都不发生，
    /// 主观感受就是「点了没反应 / 没有切换」；macOS 系统设置的开关行同样整行可点。
    ///
    /// `accessibilityValue` 专给开关行用（「开 / 关」）。**必须传**：``SettingsSwitch``
    /// 自己是 `accessibilityHidden`（它只是块视觉图形），不补这一句，
    /// VoiceOver 用户只会听到「显示 Dock 图标」而**永远不知道当前是开还是关** ——
    /// 看得见的人扫一眼就知道，看不见的人却拿不到这个信息。
    ///
    /// `progress` 给「后台下载中」那一行用（设计稿 B3）：说明位换成一个**固定 16pt 高**
    /// 的行内进度条。**高度必须固定** —— 与说明行同高，下载中这一行就不会被撑高，
    /// 于是整块面板在下载过程中不会跳一下。
    ///
    /// `descriptionAccent` 给「发现新版本」那一行用（设计稿 B2 的 `style="color:var(--accent)"`）。
    @ViewBuilder
    private func line<Control: View>(
        label: String,
        description: String? = nil,
        progress: Double? = nil,
        descriptionAccent: Bool = false,
        divider: Bool = true,
        onTap: (() -> Void)? = nil,
        accessibilityValue: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        let row = HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: DesignTokens.FontSize.body))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.body
                    )
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    SettingsProgressLine(fraction: progress, accent: accentColor)
                } else if let description {
                    Text(description)
                        .font(.system(size: DesignTokens.FontSize.footnote))
                        .foregroundStyle(
                            descriptionAccent
                                ? accentColor.swiftUIColor
                                : DesignTokens.Palette.mutedForeground
                        )
                        .designLineHeight(
                            DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
        .padding(.horizontal, SettingsMetrics.linePaddingH)
        .padding(.vertical, SettingsMetrics.linePaddingV)
        .frame(minHeight: SettingsMetrics.lineMinHeight)

        let content =
            Group {
                if let onTap {
                    SettingsLineButton(action: onTap) { row }
                } else {
                    row
                }
            }
            .overlay(alignment: .top) {
                if divider {
                    Hairline()
                }
            }

        // 空串会被 VoiceOver 读成「值：空」，所以只在真的有时才挂上去。
        if let accessibilityValue {
            content.accessibilityValue(accessibilityValue)
        } else {
            content
        }
    }

    /// 切换开机启动（失败原因上抛给宿主弹提示）。
    private func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do {
            try LaunchAtLoginManager.setEnabled(newValue)
            launchAtLogin = newValue
        } catch let error as LaunchAtLoginError {
            launchAtLogin = newValue
            onLaunchAtLoginError(error)
        } catch {
            onLaunchAtLoginError(.system(underlying: "\(error)"))
        }
    }

    // MARK: 强调色

    /// 色板（设计稿 `.swatch` 22 × 22 圆，选中态外描边 2px、偏移 4）。
    private var accentSwatches: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ForEach(AccentColor.allCases, id: \.self) { color in
                AccentSwatch(
                    color: color,
                    isSelected: accentColor == color,
                    onTap: { accentColorRaw = color.rawValue }
                )
            }
        }
    }

    // MARK: 登录项说明（含「需批准」第三态）

    /// 登录项说明文案。
    ///
    /// **第三态**：`SMAppService` 注册成功但用户尚未在系统设置里打开开关时，
    /// 开关看起来是「开」的、实际不会启动。这种情况必须显式说明，
    /// 否则用户会以为「设置好了」，重启后发现没启动。
    private var launchAtLoginDescription: String {
        if LaunchAtLoginManager.state == .requiresApproval {
            return L10n.tr(.launchAtLoginPendingHint)
        }
        return L10n.tr(.launchAtLoginFootnote)
    }

    // MARK: 关于（横向一行，设计稿 `.aboutrow`）

    /// 「关于」区：图标 + 名称/版本 + 更新按钮，**横向一行**。
    ///
    /// 旧版是「居中大图标 + 竖排版本号」，高 206pt —— 在当时的 566pt 面板里它是最大的一块，
    /// 却只承载三行静态文字。改为横向一行后降到 70pt，省下的空间留给了「诊断」分组。
    private var aboutRow: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: "eject.fill", style: .settingsAbout, accent: accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(.appName))
                    .font(.system(size: DesignTokens.FontSize.bodyStrong, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.bodyStrong)
                Text(
                    String(
                        format: L10n.tr(.versionLineFormat), appVersion, buildNumber, channelName)
                )
                .font(.system(size: DesignTokens.FontSize.footnote))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .designLineHeight(
                    DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                )
                .lineLimit(1)
                .truncationMode(.tail)

                // **脏构建要说出来**（2026-09-17 用户发现版本号停在 9/13）。
                //
                // 版本号取自最近的 tag、构建号是提交总数 —— 两者都只反映**已提交**的代码。
                // 工作区有未提交改动时，「版本 2026.09.13.1 · 构建 44」看起来像 9/13 那次
                // 正式构建，实际跑的却是今天的工作区：用户照着报的版本号会把人带到错误的代码上。
                //
                // 只在脏时出现（干净构建下这一行完全不存在，不占位、不改设计稿的版本行）。
                if let dirty = AppVersionInfo.dirtyCount(), dirty > 0 {
                    Text(
                        String(
                            format: L10n.tr(.versionDirtyNoticeFormat), dirty,
                            AppVersionInfo.commit() ?? "—")
                    )
                    .font(.system(size: DesignTokens.FontSize.footnote))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Palette.warningText)
                    .designLineHeight(
                        DesignTokens.LineHeight.base, fontSize: DesignTokens.FontSize.footnote
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // **这里曾经有一个「检查更新」按钮，2026-09-18 删掉了。**
            //
            // 设计稿 `05-settings.html` 规定「更新」组是这件事的**唯一入口**：
            // 同一个动作有两个入口时，用户会以为它们做的事不一样
            // （一个「检查」、一个「更新」，其实都只是问一句有没有新版本）。
            // 何况关于行的按钮和「更新」组那颗在同一个面板里，相隔不到 200pt。
            //
            // ⚠️ 删掉之后 `UpdateService.canOpenUpdateSource` 只剩 `openUpdateSource()`
            // 内部的失败兜底在用 —— 那是**另一条路**（updater 起不来时退回打开 Releases 页），
            // 不是「第二个入口」。
        }
        .padding(.horizontal, SettingsTokens.aboutPaddingH)
        .padding(.vertical, SettingsTokens.aboutPaddingV)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 0.5)
        )
        .shadow(
            color: DesignTokens.Elevation.e1.color,
            radius: DesignTokens.Elevation.e1.radius,
            y: DesignTokens.Elevation.e1.y
        )
        .accessibilityElement(children: .contain)
    }
}

/// 「关于」行的内边距（设计稿 `.aboutrow { padding: 13px 16px }`）。
private enum SettingsTokens {
    static let aboutPaddingH: CGFloat = DesignTokens.Spacing.lg
    static let aboutPaddingV: CGFloat = 13
}

// MARK: - 强调色色板（设计稿 `.swatch`）

private struct AccentSwatch: View {
    let color: AccentColor
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(
                    width: DesignTokens.Size.swatchSize,
                    height: DesignTokens.Size.swatchSize
                )
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                )
                // 选中态：外描边 2px、偏移 4（设计稿 `inset: -4px`）。
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(color.swiftUIColor, lineWidth: 2)
                            .padding(-DesignTokens.Size.swatchRingOffset)
                    }
                }
                .scaleEffect(hovering ? 1.12 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering = $0 }
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 分段控件（设计稿 `.seg` / `.seg__opt`）

/// 自定义分段控件。
///
/// **为什么不用原生 `Picker(.menu)`**：踩过的两个坑 ——
/// ① 「原生 Picker + 手写 chevron」会让控件上有**两个箭头**（系统 pop-up 自带一组）；
/// ② `Menu` + `.menuStyle(.borderlessButton)` 想藏箭头时，SwiftUI 把 label 折成
///    `NSButton` 的 image + title，**背景与描边被丢弃、箭头还被挪到文字左边**。
/// 设计稿给的是「外高 28（2 内边距 + 24 选项）」的分段控件，自己画反而最简单可靠：
/// 没有系统指示器、没有样式丢失，点击行为由 SwiftUI `Button` 保证。
/// 非 `private`：`SettingsLayoutTests` 要单独量它的固有宽度，
/// 钉住「控件不许把同行的标签列挤成竖排」（与 `SettingsSectionsColumn` 同样的放开理由）。
struct SettingsSegmentedControl: View {
    /// (值, 可见短标签, 无障碍全名)
    ///
    /// **为什么可见标签必须是短的**：末尾的 `.fixedSize()` 让控件**无视可用宽度**、
    /// 强占固有宽度（这是药丸外观需要的）。同行的标签列是 `maxWidth: .infinity` 的弹性列，
    /// 于是「控件要多少、标签列就剩多少」。用长标签时实测溢出 305pt，
    /// 标签被压成竖排单字（详见 ``VisualStyle/shortName``）。
    let options: [(rawValue: String, title: String, accessibilityTitle: String)]
    @Binding var selection: String
    let accent: AccentColor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.rawValue) { option in
                let isSelected = selection == option.rawValue
                Button {
                    selection = option.rawValue
                } label: {
                    Text(option.title)
                        .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? DesignTokens.Palette.foreground
                                : DesignTokens.Palette.mutedForeground
                        )
                        .lineLimit(1)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? DesignTokens.Palette.raised : Color.clear)
                        )
                        .shadow(
                            color: isSelected ? DesignTokens.Elevation.e1.color : .clear,
                            radius: DesignTokens.Elevation.e1.radius,
                            y: DesignTokens.Elevation.e1.y
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disableFocusRingIfAvailable()
                // 视觉上只有「透明」两个字，VoiceOver 念完整表述，
                // 否则用户听到的选项名没有说明「透明什么」。
                .accessibilityLabel(option.accessibilityTitle)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DesignTokens.Palette.subtle)
        )
        .fixedSize()
    }
}

// MARK: - 行内下载进度（设计稿 `.progressline`）

/// 设置行里的行内下载进度（设计稿 `08-update.html` B3）。
///
/// **为什么只画百分比、不画「还需 1 分钟」**：下载有确定的字节数，进度条说的是实话；
/// 而「还需 1 分钟」在任何网络下都是猜的。设计稿把这条写成了硬规则 ——
/// 「百分比是真的，ETA 是编的」。（主窗口那条「推出中」不画进度，理由正好相反：
/// 系统的推出接口不提供进度。）
///
/// **外层固定 16pt 高**：与说明行同高，于是这一行不会被撑高
/// （见 ``DesignTokens/Size/settingsProgressLineHeight``）。
///
/// 与 ``StorageMeter`` 的差别只有两处：百分比**不固定宽**（设计稿给 `.progressline`
/// 单独写了 `width: auto`），以及没有「高用量转琥珀」那套 ——
/// 下载到 90% 不是预警，是快好了。
struct SettingsProgressLine: View {

    /// 0…1。
    let fraction: Double
    var accent: AccentColor = .default

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(DesignTokens.Palette.subtle)
                    Capsule(style: .continuous)
                        .fill(accent.swiftUIColor)
                        .frame(width: clamped * proxy.size.width)
                }
            }
            .frame(height: DesignTokens.Size.meterHeight)

            Text(percentText)
                .font(.system(size: DesignTokens.FontSize.groupTitle, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .fixedSize()
        }
        .frame(height: DesignTokens.Size.settingsProgressLineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.tr(.usagePercentFormat), clamped * 100))
    }

    /// **夹到 0…1**：服务器给的总长可能偏小（`showDownloadDidReceiveExpectedContentLength`
    /// 的文档明确说这个值可能不准），不夹的话填充宽度会超出轨道。
    private var clamped: Double { min(max(fraction, 0), 1) }

    private var percentText: String { String(format: "%.0f%%", clamped * 100) }
}

// MARK: - 下拉（设计稿 `.popup`）

/// 设置面板里的下拉（设计稿 `.popup`：28pt 高、`--bg-subtle` 底 + 内缩发丝描边、11pt chevron）。
///
/// **为什么是手绘 + `popover`，而不是原生 `Menu` / `Picker(.menu)`**（2026-09-18 实测两次）：
///
/// | 写法 | 结果 |
/// |---|---|
/// | `Menu` + `.menuStyle(.borderlessButton)` | 标签被折成 `NSButton` 的 image+title，**箭头被挪到文字左边** |
/// | `Menu` + 默认样式（去掉 `menuStyle`） | 箭头回到右边了，但**系统按钮外观盖掉自绘的底色与描边**（白底 + 系统描边） |
///
/// 两条都做不到「设计稿的样子」。这与 ``SettingsSegmentedControl`` 是同一个结论：
/// 需要精确外观时，借系统的**行为**可以，借系统的**外观**不行 ——
/// 所以这里 `popover` 借弹出行为，按钮与选项列表全部自绘。
///
/// ⚠️ **`popover` 的内容在离屏出图里不渲染**（没有窗口就没有弹出层）——
/// 走查图只能核对闭合态。选项列表的样子要靠单测或真机看。
///
/// 非 `private`：`SettingsLayoutTests` 要单独量它的固有宽度 ——
/// 与分段控件一样，它是行内**不可压缩**的元素，会挤同行的标签列。
struct SettingsPopUp<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    let accessibilityLabel: String

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            chrome
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        // 宽度由**最长的那一项**决定，不许被同行标签列压缩 ——
        // 压窄的结果是文字被截成「跟…」，用户看不出选了什么。
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title(selection))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            optionList
        }
    }

    /// 闭合态：当前值 + chevron。
    private var chrome: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title(selection))
                .font(.system(size: DesignTokens.FontSize.caption, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: DesignTokens.Size.popUpHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(DesignTokens.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// 展开态：选项列表，当前项打勾。
    ///
    /// **必须有选中记号**：不打勾的话用户得靠「记住刚才选了什么」来判断，
    /// 而这里恰好有一个「选了但还没重启生效」的中间态 —— 记错就会以为没生效。
    private var optionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                    isOpen = false
                } label: {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(title(item))
                            .font(.system(size: DesignTokens.FontSize.caption))
                            .foregroundStyle(DesignTokens.Palette.foreground)
                            .lineLimit(1)
                        Spacer(minLength: DesignTokens.Spacing.lg)
                        if item == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignTokens.Palette.foreground)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disableFocusRingIfAvailable()
            }
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(minWidth: 140)
    }
}

// MARK: - 可点的设置行容器

/// 把一整行设置项包成可点区域（用于开关行）。
///
/// 命中区从 38×22 的开关本身扩到整行（约 400 × 50），点哪都能切换。
/// hover 底色用**负内边距向外扩**，让它比行本身宽一圈却**不改变布局** ——
/// 若改成给行加正内边距，标签会从 12pt 缩进变成 20pt，与其它行错位。
private struct SettingsLineButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(hovering ? DesignTokens.Palette.subtle : Color.clear)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering = $0 }
    }
}

/// 开关本体（纯视觉，不含点击行为 —— 点击由所在设置行承担）。
///
/// **滑块位移用 `offset(x:)`，不用 `ZStack(alignment:)`**：两者两端位置完全相同，
/// 但 `offset` 是明确的几何位移属性，与轨道配色的 `.animation` 处于同一事务；
/// `alignment` 改的是**布局对齐**，「变化能否插值」取决于 SwiftUI 内部实现，不是可依赖的契约。
struct SettingsSwitch: View {
    let isOn: Bool
    let accent: AccentColor

    private var trackWidth: CGFloat { DesignTokens.Size.switchTrackWidth }
    private var trackHeight: CGFloat { DesignTokens.Size.switchTrackHeight }
    private var knobDiameter: CGFloat { DesignTokens.Size.switchKnob }
    private var knobInset: CGFloat { DesignTokens.Size.switchInset }

    /// 滑块行程 = 轨道宽 − 两侧内缩 − 滑块直径。
    /// 抽成计算属性而非字面量：改任一尺寸时行程自动跟着变，不会出现「滑块滑出轨道」。
    private var knobTravel: CGFloat { trackWidth - knobInset * 2 - knobDiameter }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? accent.swiftUIColor : DesignTokens.Palette.subtleHighlight)
                .frame(width: trackWidth, height: trackHeight)
            Circle()
                .fill(Color.white)
                .frame(width: knobDiameter, height: knobDiameter)
                .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                .padding(.leading, knobInset)
                .offset(x: isOn ? knobTravel : 0)
        }
        .frame(width: trackWidth, height: trackHeight)
        // 动画挂在开关本身上：轨道配色与滑块位移在同一个事务里插值，不会一前一后。
        .animation(DesignTokens.Motion.standard, value: isOn)
        .accessibilityHidden(true)
    }
}
