import AppKit
import SwiftUI

/// 设置面板（设计稿 `05-settings.html` / `.win--settings`）。
///
/// **设计稿规格**：440 × 566，圆角 **12**（与主窗口同一个 `--r-window`），毛玻璃
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

    /// 是否让**玻璃铺满宿主**（而不是刚好等于设计稿的 440×566）。
    ///
    /// - `true`：**独立窗口**用（`AppDelegate.makeSettingsWindow()`）。窗口可能因为
    ///   标题栏安全区被撑高，玻璃必须跟着铺满 —— 否则多出来的那一条会露出桌面。
    ///   实测（2026-09-16，补齐前）：窗口 598、玻璃只有 566，**上下各露 16pt**。
    /// - `false`（默认）：离屏出图与单测用。这时要的正是**理想尺寸 440×566**。
    ///   ⚠️ 这条路径**不能**开 `true` —— `.frame(maxHeight: .infinity)` 会让
    ///   `sizeThatFits(in: …greatestFiniteMagnitude)` 量出**无穷高**，
    ///   `writePNG` 里 `Int(∞ * 2)` 直接 SIGTRAP（快照那套代码的注释里记着这个坑）。
    var fillsHost: Bool = false

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
                SettingsSectionsColumn { error in
                    launchAtLoginPrompt = prompt(for: error)
                }
                .padding(.bottom, SettingsMetrics.bottomInset)
            }
            .scrollContentBackground(.hidden)
        }
        // **两层 frame 分工不同，别合并成一层**（与 ``ContentView`` 同一处理，
        // 主窗口的「标题栏露底」就是这么来的）：
        // - 内层 = **设计稿尺寸** 440×566，内容按它排版；
        // - 外层 = **填满宿主**（窗口），``GlassSurface`` 铺在这一层上。
        //   少了外层，「玻璃铺满整窗」就退化成依赖「窗口高恰好等于内容高」这个巧合 ——
        //   巧合一破（窗口被安全区撑到 598）就上下各露 16pt。
        //
        // 外层只在独立窗口里加：`maxWidth/maxHeight` 传 `nil` 是 no-op，
        // 于是离屏出图与单测拿到的仍是理想尺寸 440×566（理由见 ``fillsHost``）。
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

    /// 面板内可容纳的内容高度（面板高 − 头部高 − 底部留白）。
    static func contentHeightBudget(headerHeight: CGFloat) -> CGFloat {
        DesignTokens.Size.settingsPanel.height - headerHeight - bottomInset
    }
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

/// 设置面板的四组内容（不含头部与滚动容器）。
///
/// **自己读偏好、不接收绑定**：这样契约测试可以直接 `SettingsSectionsColumn { _ in }`
/// 构造真实视图量高度，不必在测试里搭一套假的绑定。
/// 唯一需要上抛的是登录项的失败原因（宿主负责弹 alert）。
struct SettingsSectionsColumn: View {

    /// 登录项操作失败时上抛（宿主弹提示；测试里给空实现）。
    var onLaunchAtLoginError: (LaunchAtLoginError) -> Void = { _ in }

    @AppStorage(AppSettings.Key.visualStyle) private var visualStyleRaw = VisualStyle.default.rawValue
    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue
    @AppStorage(AppSettings.Key.showDockIcon) private var showDockIcon = false
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled

    private var accentColor: AccentColor { AccentColor(rawValue: accentColorRaw) ?? .default }

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

    /// 分发渠道显示名。**必须区分**：自签与 ad-hoc 构建无法公证、无法上架，
    /// 一律写成「Developer ID」会让使用者误判自己已具备分发条件。
    private var channelName: String {
        UpdateService.channel == .appStore
            ? L10n.tr(.updateChannelAppStore)
            : L10n.tr(.updateChannelDirect)
    }

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
                    // 设计稿这一行**只有标签、没有说明**（`.sline` 实测 44pt）。
                    // 曾给它加了一句「在 Dock 与 App 切换器中显示图标。」，
                    // 于是整行 44 → 59，四组内容比设计稿高出 15pt，
                    // 566pt 的面板装不下，「关于」又被挤出滚动区。
                    // 「在 Dock 中显示图标」本身已经说清了后果，不需要再解释一遍。
                    line(
                        label: L10n.tr(.showDockIcon),
                        divider: false,
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
    @ViewBuilder
    private func line<Control: View>(
        label: String,
        description: String? = nil,
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
                if let description {
                    Text(description)
                        .font(.system(size: DesignTokens.FontSize.footnote))
                        .foregroundStyle(DesignTokens.Palette.mutedForeground)
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
    /// 旧版是「居中大图标 + 竖排版本号」，高 206pt —— 在 566pt 的面板里它是最大的一块，
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

            if UpdateService.canOpenUpdateSource {
                ActionButton(
                    title: UpdateService.channel == .appStore
                        ? L10n.tr(.openInAppStore)
                        : L10n.tr(.checkForUpdates),
                    variant: .outline,
                    size: .small,
                    accent: accentColor,
                    action: { UpdateService.openUpdateSource() }
                )
            }
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
