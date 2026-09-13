import SwiftUI

/// 设置面板（与设计稿"设置面板"对齐）。
///
/// **设计稿规格**：440 宽面板，圆角 lg，毛玻璃 blur 24；
/// 头部"设置" + "完成"；6 段：视觉效果 / 强调色 / Dock 图标 / 登录启动 / 关于 / 更新。
///
/// **不变量**：
/// - 偏好键由 ``AppSettings.Key`` 提供、``@AppStorage`` 实时持久化
/// - 强调色由 ``AccentColor`` 提供（4 种，与设计稿一致）
/// - 登录启动用 ``LaunchAtLoginManager``，错误按原因分三类提示
///
/// **为什么拆成三个类型**（``SettingsView`` / ``SettingsHeaderBar`` / ``SettingsSectionsColumn``）：
/// 面板高度是常量，内容一旦高于它，面板底部的「关于 / 更新」就会被折叠线藏在滚动区外
/// —— 用户实测反馈过「设置界面排版不好看」，根因正是内容（约 720pt）远高于面板（520pt）。
/// 拆开后单测能**分别渲染两个子视图、量出它们需要的真实高度**，把
/// 「头部 + 内容 ≤ 面板高度」钉成契约（见 `SettingsLayoutTests`）。
/// SPM 工程没有 Xcode 预览，这是让排版可验证的唯一手段。
struct SettingsView: View {

    /// 「完成」按钮的动作。
    ///
    /// **默认走 SwiftUI 的 `dismiss`（sheet 场景）**；独立窗口场景
    /// （菜单栏 → 设置：`AppDelegate.showSettings()` 里是 `NSHostingView` 直挂）
    /// **没有 presentation 上下文，`dismiss` 是空操作** —— 那种情况由宿主传入 onDone 关窗。
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
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
        }
        .frame(
            width: DesignTokens.Size.settingsPanel.width,
            height: DesignTokens.Size.settingsPanel.height
        )
        .background(DesignTokens.Palette.popoverBackground(for: colorScheme))
        // 整体毛玻璃：仅 macOS 15+ 接近设计稿的 Liquid Glass，14 自动用 .regularMaterial 兜底
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
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
    /// 分段容器左右内边距（设计稿 px-5）。
    static let sectionPaddingH: CGFloat = 20
    /// 分段容器上下内边距（设计稿 py-4 = 16，收紧到 14 以便六段在面板内放得下）。
    static let sectionPaddingV: CGFloat = 14
    /// 滚动内容底部留白。
    static let bottomInset: CGFloat = 10
    /// 头部上下内边距。
    static let headerPaddingV: CGFloat = 14

    /// 面板内可容纳的内容高度（面板高 − 头部高）。
    static func contentHeightBudget(headerHeight: CGFloat) -> CGFloat {
        DesignTokens.Size.settingsPanel.height - headerHeight - bottomInset
    }
}

// MARK: - 头部（"设置" + "完成"）

/// 设置面板头部。
///
/// **单独抽出来是为了可测**：``SettingsSectionsColumn`` 的可用高度 = 面板高 − 本视图高，
/// 契约测试要分别量出两者，才能断言「内容不会被折叠线藏起来」。
struct SettingsHeaderBar: View {

    let onDone: () -> Void

    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.tr(.settings))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
            Spacer(minLength: 0)
            // `TextButton` 自带 12pt 左右内边距，这里只补 8pt，让「完成」右边缘
            // 与下方分段内容（内边距 20pt）严格对齐。
            TextButton(
                title: L10n.tr(.done),
                action: onDone,
                accent: AccentColor(rawValue: accentColorRaw) ?? .default
            )
        }
        .padding(.leading, SettingsMetrics.sectionPaddingH)
        .padding(.trailing, SettingsMetrics.sectionPaddingH - 12)
        .padding(.vertical, SettingsMetrics.headerPaddingV)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 六段内容

/// 设置面板的六段内容（不含头部与滚动容器）。
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
    private var visualStyle: VisualStyle { VisualStyle(rawValue: visualStyleRaw) ?? .default }

    /// 从 Info.plist 读取版本号（打包时注入），缺失时回退 "1.0.0"。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 构建号，与版本号一并展示便于用户反馈问题时定位。
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 第一段不画分隔线：设计稿的分隔线规则是 `.disk-section + .disk-section`，
            // 也就是「只在段与段之间」，头部下面不该出现一条横线。
            section(divider: false) { visualStyleRow }
            section { accentColorRow }
            section { dockIconRow }
            section { launchAtLoginSection }
            section { aboutSection }
            section { updateSection }
        }
    }

    // MARK: - 分段容器（统一内边距 + 段间分隔线）

    @ViewBuilder
    private func section<Content: View>(
        divider: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, SettingsMetrics.sectionPaddingH)
            .padding(.vertical, SettingsMetrics.sectionPaddingV)
            .overlay(alignment: .top) {
                if divider {
                    Rectangle()
                        .fill(DesignTokens.Palette.border)
                        .frame(height: 1)
                }
            }
    }

    // MARK: - 视觉效果

    private var visualStyleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L10n.tr(.visualEffects))
                    .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                Spacer(minLength: 0)
                styleMenu
            }
            // 说明文字**独占一行、拿满可用宽度**：与下拉同处一行时只剩约 200pt，
            // 会被截断成「…毛玻璃效果（需 macOS 1…」。挪到下一行后可完整显示。
            Text(L10n.tr(.transparentModeFootnote))
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 视觉风格下拉。
    ///
    /// **用原生 `Picker(.menu)`，不自己画下拉**。踩过的两个坑：
    /// ① 之前是「原生 Picker + 手写 `chevron.down`」——系统 pop-up 自带一组上下三角
    ///    指示器，于是**控件上有两个箭头**；
    /// ② 换成 `Menu` + `.menuStyle(.borderlessButton)` 想把指示器藏掉时，SwiftUI 会把
    ///    自定义 label 折成 `NSButton` 的 `image` + `title`（实测视图树里就是
    ///    `SwiftUIPopupButton`），**背景与描边被丢弃、箭头还被挪到文字左边**。
    /// 原生 pop-up 在视图树里是实打实的 `NSButton(menu: …)`，点击行为有保障。
    private var styleMenu: some View {
        Picker("", selection: $visualStyleRaw) {
            ForEach(VisualStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(L10n.tr(.visualEffects))
    }

    // MARK: - 强调色

    private var accentColorRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr(.accentColor))
                .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
            LazyVGrid(
                columns: [
                    GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible()),
                ],
                spacing: 8
            ) {
                ForEach(AccentColor.allCases, id: \.self) { color in
                    AccentOptionButton(
                        color: color,
                        isSelected: accentColor == color,
                        onTap: { accentColorRaw = color.rawValue }
                    )
                }
            }
        }
    }

    // MARK: - Dock 图标

    private var dockIconRow: some View {
        SettingsToggleRow(
            title: L10n.tr(.showDockIcon),
            isOn: $showDockIcon,
            accent: accentColor
        )
    }

    // MARK: - 登录启动

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsToggleRow(
                title: L10n.tr(.launchAtLogin),
                isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
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
                ),
                accent: accentColor
            )
            // 说明 + 链接「打开系统设置」同处一行：链接用 accent 着色、无额外内边距，
            // 避免像原生 TextButton 那样把整行撑高（行高由 12pt 说明文字决定）。
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(L10n.tr(.launchAtLoginFootnote))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                inlineLink(title: L10n.tr(.openSystemSettings), action: LaunchAtLoginManager.openSystemSettings)
                    .padding(.leading, 4)
            }
        }
    }

    /// 行内文字链接（accent 着色、hover 加下划线），比 ``TextButton`` 更紧凑。
    private func inlineLink(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColor.swiftUIColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(spacing: 10) {
            IconBadge(systemName: "externaldrive.fill", style: .settingsAbout, accent: accentColor)
            Text(L10n.tr(.appName))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
            VStack(spacing: 2) {
                Text(String(format: L10n.tr(.versionFormat), appVersion))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                Text(String(format: L10n.tr(.buildFormat), buildNumber))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                UpdateService.channel == .appStore
                    ? L10n.tr(.updateManagedByAppStore)
                    : L10n.tr(.updateDownloadPageHint)
            )
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.Palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            if UpdateService.canOpenUpdateSource {
                Button {
                    UpdateService.openUpdateSource()
                } label: {
                    Text(
                        UpdateService.channel == .appStore
                            ? L10n.tr(.openInAppStore)
                            : L10n.tr(.openDownloadPage)
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .fill(accentColor.swiftUIColor)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disableFocusRingIfAvailable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 强调色选项按钮（设计稿：圆形色点 + 名称 + 选中态边框）

private struct AccentOptionButton: View {
    let color: AccentColor
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 16, height: 16)
                Text(color.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.foreground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(isSelected ? color.swiftUIColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? color.swiftUIColor : DesignTokens.Palette.border,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .animation(DesignTokens.Motion.fast, value: isSelected)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 自定义 Toggle（设计稿 38×22 圆角开关，accent 填充 + 圆形 handle）

/// 开关行：**整行可点**，不只是那 38×22 的小开关。
///
/// **为什么**：只把小开关本身做成按钮时，命中区就只有 38×22pt —— 用户瞄准"开关"
/// 点下去稍有偏差就落在旁边、什么都不发生，主观感受就是「点了没反应 / 没有切换」。
/// macOS 系统设置里开关行的文字标签同样可点，这里与之一致。
/// 顺带把命中区从 38×22 扩到整行（约 400×50），点哪都能切换。
struct SettingsToggleRow: View {

    let title: String
    @Binding var isOn: Bool
    let accent: AccentColor

    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                Spacer(minLength: 0)
                SettingsSwitch(isOn: isOn, accent: accent)
            }
            // 行高保持 22pt（= 开关高度），不加内边距 —— 面板高度是按内容量出来的，
            // 加 10pt 就会顶破预算。命中区靠 `.contentShape(Rectangle())` 铺满整行宽度。
            //
            // hover 底色用**负内边距向外扩**，让它比行本身宽一圈却**不改变布局**：
            // 若改成给行加正内边距，标题会从 20pt 缩进变成 28pt，与其它段落的标题错位。
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(hovering ? DesignTokens.Palette.mutedBackground : Color.clear)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? L10n.tr(.on) : L10n.tr(.off))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// 开关本体（纯视觉，不含点击行为 —— 点击由 ``SettingsToggleRow`` 整行承担）。
///
/// **滑块位移用 `offset(x:)`，不用 `ZStack(alignment:)`**：两者两端位置完全相同
/// （左 2pt / 右 2pt 内缩，行程 18pt），但 `offset` 是明确的几何位移属性，与轨道配色的
/// `.animation` 处于同一事务；`alignment` 改的是**布局对齐**，「变化能否插值」取决于
/// SwiftUI 内部实现，不是可依赖的契约。
///
/// **但别把「没有动画」当成 `alignment` 的锅**：录屏逐帧量过两版，**两者都动画**
/// （各 6–7 个中间帧，行程 36.3px@2x，轨道色从灰平滑插值到 accent）。用户报的
/// 「点了没有切换动画」真实原因是命中区只有 38×22pt、瞄不准就点空 ——
/// 修法在 ``SettingsToggleRow``（整行可点），不是改这里的写法。
private struct SettingsSwitch: View {
    let isOn: Bool
    let accent: AccentColor

    /// 轨道宽（设计稿 38）。
    private let trackWidth: CGFloat = 38
    /// 轨道高（设计稿 22）。
    private let trackHeight: CGFloat = 22
    /// 滑块直径（设计稿 16）。
    private let knobDiameter: CGFloat = 16
    /// 滑块与轨道的内缩（设计稿 2）。
    private let knobInset: CGFloat = 2

    /// 滑块行程 = 轨道宽 − 两侧内缩 − 滑块直径。
    /// 抽成计算属性而非字面量：改任一尺寸时行程自动跟着变，不会出现「滑块滑出轨道」。
    private var knobTravel: CGFloat { trackWidth - knobInset * 2 - knobDiameter }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? accent.swiftUIColor : DesignTokens.Palette.mutedBackground)
                .overlay(
                    // 打开时描边跟随 accent（设计稿 `.disk-toggle:checked { border-color }`），
                    // 关闭时是中性 hairline。
                    Capsule().strokeBorder(
                        isOn ? accent.swiftUIColor : DesignTokens.Palette.border,
                        lineWidth: 1)
                )
                .frame(width: trackWidth, height: trackHeight)
            Circle()
                .fill(Color.white)
                .frame(width: knobDiameter, height: knobDiameter)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .padding(.leading, knobInset)
                .offset(x: isOn ? knobTravel : 0)
        }
        .frame(width: trackWidth, height: trackHeight)
        // 动画挂在开关本身上：轨道配色与滑块位移在同一个事务里插值，不会一前一后。
        .animation(DesignTokens.Motion.standard, value: isOn)
        .accessibilityHidden(true)
    }
}
