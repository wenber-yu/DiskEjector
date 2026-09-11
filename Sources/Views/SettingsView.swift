import SwiftUI

/// 设置面板（与设计稿"设置面板"对齐）。
///
/// **设计稿规格**：440 × 520 面板，圆角 lg，毛玻璃 blur 24；
/// 头部"设置" + "完成"；6 段：视觉风格 / 强调色 / Dock 图标 / 登录启动 / 关于 / 更新。
///
/// **不变量**：
/// - 偏好键由 ``AppSettings.Key`` 提供、``@AppStorage`` 实时持久化
/// - 强调色由 ``AccentColor`` 提供（4 种，与设计稿一致）
/// - 登录启动用 ``LaunchAtLoginManager``，错误按原因分三类提示
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.visualStyle) private var visualStyleRaw = VisualStyle.default.rawValue
    @AppStorage(AppSettings.Key.accentColor) private var accentColorRaw = AccentColor.default.rawValue
    @AppStorage(AppSettings.Key.showDockIcon) private var showDockIcon = false
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled
    @State private var launchAtLoginPrompt: LaunchAtLoginPrompt?
    @Environment(\.colorScheme) private var colorScheme

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

    /// 登录项操作的提示内容。
    private struct LaunchAtLoginPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let offersOpenSettings: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            header
            // 滚动体
            ScrollView {
                VStack(spacing: 0) {
                    section {
                        visualStyleRow
                    }
                    section {
                        accentColorRow
                    }
                    section {
                        dockIconRow
                    }
                    section {
                        launchAtLoginSection
                    }
                    section {
                        aboutSection
                    }
                    .padding(.top, 4)
                    section {
                        updateSection
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: DesignTokens.Size.settingsPanel.width,
               height: DesignTokens.Size.settingsPanel.height)
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

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text(L10n.tr(.settings))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.foreground)
            Spacer()
            TextButton(title: L10n.tr(.done), action: { dismiss() })
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - 分段容器（统一上下 padding + 分隔线）

    @ViewBuilder
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.Palette.border)
                .frame(height: 1)
        }
    }

    // MARK: - 视觉效果

    private var visualStyleRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(.visualEffects))
                    .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                Text(L10n.tr(.transparentModeFootnote))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .lineLimit(2)
            }
            Spacer()
            // 自定义 select：下拉箭头 + 选中项
            HStack(spacing: 6) {
                Picker("", selection: $visualStyleRaw) {
                    Text(L10n.tr(.transparentMode)).tag(VisualStyle.transparent.rawValue)
                    Text(L10n.tr(.tintedMode)).tag(VisualStyle.tinted.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(DesignTokens.Palette.foreground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(DesignTokens.Palette.mutedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
            )
        }
    }

    // MARK: - 强调色

    private var accentColorRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr(.accentColor))
                .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()),
                          GridItem(.flexible()), GridItem(.flexible())],
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
        HStack {
            Text(L10n.tr(.showDockIcon))
                .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
            Spacer()
            CustomToggle(isOn: $showDockIcon, accent: accentColor)
        }
    }

    // MARK: - 登录启动

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr(.launchAtLogin))
                    .font(.system(size: DesignTokens.FontSize.settingsTitle, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                Spacer()
                CustomToggle(
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                try LaunchAtLoginManager.setEnabled(newValue)
                                launchAtLogin = newValue
                            } catch let error as LaunchAtLoginError {
                                launchAtLogin = newValue
                                switch error {
                                case .requiresApproval:
                                    launchAtLoginPrompt = LaunchAtLoginPrompt(
                                        title: L10n.tr(.launchAtLoginNeedsApprovalTitle),
                                        message: L10n.tr(.launchAtLoginNeedsApprovalMessage),
                                        offersOpenSettings: true)
                                case .notFound:
                                    launchAtLoginPrompt = LaunchAtLoginPrompt(
                                        title: L10n.tr(.launchAtLoginErrorTitle),
                                        message: L10n.tr(.launchAtLoginUnavailableMessage),
                                        offersOpenSettings: false)
                                case .system(let text):
                                    launchAtLoginPrompt = LaunchAtLoginPrompt(
                                        title: L10n.tr(.launchAtLoginErrorTitle),
                                        message: L10n.tr(.launchAtLoginErrorMessage),
                                        offersOpenSettings: false)
                                    LogService.shared.log(disk: nil, message: "登录项设置失败: \(text)")
                                }
                            } catch {
                                launchAtLoginPrompt = LaunchAtLoginPrompt(
                                    title: L10n.tr(.launchAtLoginErrorTitle),
                                    message: L10n.tr(.launchAtLoginErrorMessage),
                                    offersOpenSettings: false)
                            }
                        }
                    ),
                    accent: accentColor
                )
            }
            // 提示 + 链接"打开系统设置"
            HStack(alignment: .top, spacing: 0) {
                Text(L10n.tr(.launchAtLoginFootnote))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                TextButton(title: L10n.tr(.openSystemSettings), action: LaunchAtLoginManager.openSystemSettings)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                IconBadge(systemName: "externaldrive.fill", style: .settingsAbout, accent: accentColor)
                Text("DiskEjector")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                Text(String(format: L10n.tr(.versionFormat), appVersion))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                Text(String(format: L10n.tr(.buildFormat), buildNumber))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 更新

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                UpdateService.channel == .appStore
                    ? L10n.tr(.updateManagedByAppStore)
                    : L10n.tr(.updateDownloadPageHint)
            )
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.Palette.mutedForeground)

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
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                            .fill(accentColor.swiftUIColor)
                    )
                }
                .buttonStyle(.plain)
            }
        }
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 自定义 Toggle（设计稿 38×22 圆角开关，primary 填充 + 圆形 handle）

private struct CustomToggle: View {
    @Binding var isOn: Bool
    let accent: AccentColor

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? accent.swiftUIColor : DesignTokens.Palette.mutedBackground)
                    .overlay(
                        Capsule().strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
                    )
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .animation(DesignTokens.Motion.standard, value: isOn)
        .accessibilityLabel(isOn ? L10n.tr(.on) : L10n.tr(.off))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
