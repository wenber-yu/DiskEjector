import SwiftUI

// MARK: - IconBadge（圆角图标容器）
//
// 设计稿用法：图标坐在 `rgba(accent, 0.10~0.12)` 透明色背景的圆角方块里，
// 强调色直接用 AccentColor 渲染（蓝/紫/橙/绿都成立）。

struct IconBadge: View {
    enum Style {
        /// 主窗口磁盘卡片头：40×40，accent 12% 透明背景，5pt 图标。
        case diskCard
        /// 菜单栏磁盘行：32×32，accent 10% 透明背景，4.5pt 图标。
        case menuRow
        /// 弹窗警告图标：透明背景，警告色 8pt 图标。
        case dialogWarning
        /// 弹窗 FDA 锁图标：透明背景，强调色 8pt 图标。
        case dialogPrimary
        /// 空状态大图标：64×64，muted 背景，12pt 图标。
        case emptyState
        /// 设置面板 About：56×56，accent 实心背景，白色 7pt 图标。
        case settingsAbout
    }

    let systemName: String
    let style: Style
    let accent: AccentColor

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let cfg = configuration()
        Image(systemName: systemName)
            .font(.system(size: cfg.iconSize, weight: .medium))
            .foregroundStyle(cfg.foreground)
            .frame(width: cfg.container, height: cfg.container)
            .background(
                RoundedRectangle(cornerRadius: cfg.radius, style: .continuous)
                    .fill(cfg.background)
            )
            .accessibilityHidden(true)
    }

    private struct Config {
        let container: CGFloat
        let iconSize: CGFloat
        let radius: CGFloat
        let background: Color
        let foreground: Color
    }

    private func configuration() -> Config {
        let accentColor = accent.swiftUIColor
        switch style {
        case .diskCard:
            // 头部纯图标（无背景方块），保持约束框用于对齐 + accent 主调。
            return Config(
                container: 28,
                iconSize: 22,
                radius: 0,
                background: .clear,
                foreground: accentColor
            )
        case .menuRow:
            return Config(
                container: DesignTokens.Size.menuIconContainer,
                iconSize: 18,
                radius: DesignTokens.Radius.md - 2,
                background: accentColor.opacity(0.10),
                foreground: accentColor
            )
        case .dialogWarning:
            return Config(
                container: 0,
                iconSize: 32,
                radius: 0,
                background: .clear,
                foreground: DesignTokens.Palette.warning
            )
        case .dialogPrimary:
            return Config(
                container: 0,
                iconSize: 32,
                radius: 0,
                background: .clear,
                foreground: accentColor
            )
        case .emptyState:
            return Config(
                container: 64,
                iconSize: 32,
                radius: 32,
                background: DesignTokens.Palette.mutedBackground,
                foreground: DesignTokens.Palette.mutedForeground
            )
        case .settingsAbout:
            return Config(
                container: 56,
                iconSize: 28,
                radius: 16,
                background: accentColor,
                foreground: .white
            )
        }
    }
}

// MARK: - PrimaryButton（主按钮）
//
// 设计稿用法：圆角 md（10），高 32（标题栏图标按钮是 28），padding 0 16，
// accent 实心背景，白色文字，hover 时 opacity 0.9。

struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void
    let accent: AccentColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                }
                Text(title)
                    .font(.system(size: DesignTokens.FontSize.primaryButton, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .frame(height: DesignTokens.Size.primaryButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(accent.swiftUIColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // 用 SwiftUI 自带 hover 动效不能改背景色，这里用 NSViewRepresentable
            // 监听 enter/exit 不划算；直接靠系统按钮的 active 反馈即可。
            _ = hovering
        }
        .help(title)
    }
}

// MARK: - SecondaryButton（次要按钮，描边/文字）
//
// 设计稿用法：圆角 md，muted 背景，1px 边框，文字 13px / 500。

struct SecondaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(title)
                    .font(.system(size: DesignTokens.FontSize.primaryButton, weight: .medium))
            }
            .foregroundStyle(DesignTokens.Palette.foreground)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .frame(height: DesignTokens.Size.primaryButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(DesignTokens.Palette.mutedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - TextButton（纯文字按钮）
//
// 设计稿"打开系统设置"链接、"完成"等场景：透明背景，accent 文字，hover 加淡背景。
//
// **用 SwiftUI Button + .buttonStyle(.plain)**：相比 `onTapGesture`，SwiftUI Button
// 第一次点击响应更可靠（`onTapGesture` 在 SwiftUI 首次渲染后有约 1 个 runloop tick
// 的注册延迟，会让"第一次点击没反应"——这是用户报告的核心症状）。
//
// **去焦点环**：`.focusable(false)` + `.disableFocusRingIfAvailable()`，
// 与 MenuActionRow / ejectButton 保持同一处理策略。

struct TextButton: View {
    let title: String
    let action: () -> Void
    var accent: AccentColor = .default

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent.swiftUIColor)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(title)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - ProcessTag（进程标签）
//
// 设计稿"磁盘详情 - 占用进程列表"：圆角 pill（仅 muted 背景，**无边框**）+ 应用图标 + 应用名。
// 宽度按内容自适应（不设 maxWidth）：让 pill 紧贴内容、左右不留大片空白，
// 多个 pill 在磁盘行下方排成一行，视觉上更轻盈。
// 名称过长时单行截断（`.truncationMode(.tail)`），靠 `.help()` 暴露完整名给用户。

struct ProcessTag: View {
    let process: OccupyingProcess

    /// 图标尺寸：与 diskCard icon 视觉对齐。
    private let iconSize: CGFloat = 22

    var body: some View {
        // **参数顺序**：SwiftUI 要求 `alignment` 必须写在 `spacing` 之前，
        // 写成 `HStack(spacing:alignment:)` 会编译失败。
        HStack(alignment: .center, spacing: 6) {
            iconView
                // 显式固定图标容器为 iconSize，避免 NSImage 自带透明边距影响视觉中心。
                .frame(width: iconSize, height: iconSize)
            Text(process.name)
                .font(.system(size: DesignTokens.FontSize.processTag, weight: .regular))
                .foregroundStyle(DesignTokens.Palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                // 文字与图标同高，并在 22pt 容器内垂直居中，避免默认行高导致视觉上"偏下"。
                .frame(height: iconSize, alignment: .center)
        }
        .padding(.horizontal, 8)
        // 进程标签在磁盘卡片内视觉上略偏上，避免贴底边框线。
        // 原 .padding(.vertical, 5) 上下对称，底部留白不够显得"下沉"；
        // 调整为 top 8 / bottom 3，让 pill 视觉上更靠上、更透气。
        .padding(.top, 8)
        .padding(.bottom, 3)
        // **无 maxWidth**：pill 宽度严格按图标 + 文本 + 内边距 自适应，
        // 不会有"右侧大片空白"。若整体超卡片宽，truncationMode(.tail) 自动加 "…"。
        // **无边框 overlay**：去掉 1px border 让 pill 与磁盘卡片视觉分离更柔和。
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Palette.mutedBackground)
        )
        .help(process.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(process.name)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = process.appIcon() {
            Image(nsImage: icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "app")
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
                .frame(width: iconSize, height: iconSize)
        }
    }
}

// MARK: - StorageProgressBar（容量进度条）
//
// 设计稿用法：muted 背景轨道，accent 填充，圆角 full，h-1.5（6pt）。

struct StorageProgressBar: View {
    let ratio: Double  // 0.0 ~ 1.0
    let accent: AccentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(DesignTokens.Palette.mutedBackground)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent.swiftUIColor)
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
                    .animation(DesignTokens.Motion.standard, value: ratio)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - FdaBanner（FDA 授权引导横幅）
//
// 设计：跟磁盘卡片同款卡片样式（圆角 + 1px 边框 + 极轻 accent 染色 + 长条横向铺满）。
// 文案分两行：① 主结论（粗体 prominent）② 操作引导（次要静音）。
// 左右结构：左侧 lock 图标 + 文案（VStack 内两行），右侧固定「打开系统设置」按钮。

struct FdaBanner: View {
    let messageLead: String
    let messageTail: String
    let actionLabel: String
    let action: () -> Void
    let accent: AccentColor

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent.swiftUIColor)
                .accessibilityHidden(true)
            // 两行文案：上半段主结论（粗），下半段操作引导（淡）。
            VStack(alignment: .leading, spacing: 4) {
                Text(messageLead)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(messageTail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 固定按钮（独立右侧，不被滚动带走）
            TextButton(title: actionLabel, action: action, accent: accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(accent.swiftUIColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(messageLead + " " + messageTail + " " + actionLabel)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - SafeToEjectRow（"无进程占用"状态行）
//
// 紧凑单行：✓（小尺寸绿）+ "无进程占用"。无背景，无边框；
// 与 ProcessTag 视觉重量一致，让「无占用」与「有占用 + 标签」看起来同级。

struct SafeToEjectRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DesignTokens.Palette.success)
            Text(L10n.tr(.noProcessOccupied))
                .font(.system(size: DesignTokens.FontSize.processTag))
                .foregroundStyle(DesignTokens.Palette.success)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr(.safeToEject))
    }
}

// MARK: - EmptyStateView（空状态卡片）
//
// 设计稿用法：圆形 64×64 图标容器（muted 背景）+ 标题 + 描述（260px maxWidth）+ 次要按钮。

struct EmptyStateView: View {
    let systemName: String
    let title: String
    let description: String
    let actionTitle: String
    let actionSystemImage: String?
    let action: () -> Void
    let accent: AccentColor

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                IconBadge(systemName: systemName, style: .emptyState, accent: accent)
                    .padding(.bottom, 16)
                Text(title)
                    .font(.system(size: DesignTokens.FontSize.diskCardName, weight: .medium))
                    .foregroundStyle(DesignTokens.Palette.foreground)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 280)
                    .padding(.top, 8)
                SecondaryButton(
                    title: actionTitle,
                    systemImage: actionSystemImage,
                    action: action
                )
                .padding(.top, 20)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
