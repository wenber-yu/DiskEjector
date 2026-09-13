import AppKit
import SwiftUI

/// 状态栏菜单的 SwiftUI 视图（与设计稿"菜单栏弹出面板"对齐）。
///
/// **规格**：360px 宽，毛玻璃 blur 20 + saturate 180（用 .ultraThinMaterial 近似）；
/// 标题"外置磁盘"；磁盘行（32×32 图标容器 + 名称 + meta + 推出按钮）；
/// 分隔线 + 动作区（打开主窗口 / 刷新 / 设置 / 退出）。
struct MenuPopoverView: View {

    @ObservedObject private var store = DiskListStore.shared
    let accent: AccentColor
    let onOpenMainWindow: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    /// 每个卷的占用检测结果（菜单栏用，与主窗口共用同一份语义）。
    @State private var occupancy: [String: OccupancyResult] = [:]

    /// 由 AppDelegate 注入的"在菜单栏上点推出"的回调。
    /// 这里只发动作、列出进程名，真正删除前还是会通过 ``EjectUI`` 弹窗二次确认。
    let onEject: (DiskInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionCaption
            if store.disks.isEmpty {
                emptyState
            } else {
                diskList
            }
            separator
            actions
        }
        .frame(width: DesignTokens.Size.menuPopoverWidth)
        .task { await refreshOccupancy() }
        .onChange(of: store.disks) { _ in
            Task { await refreshOccupancy() }
        }
    }

    // MARK: - 头部
    //
    // 面板顶部显示**应用自身**的名称（配状态栏同款 eject 图标、accent 着色），
    // 让用户在打开面板时知道这是哪个 App；「外置磁盘」下沉为列表的分组标题。

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "eject.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent.swiftUIColor)
                .accessibilityHidden(true)
            Text(L10n.tr(.appName))
                .font(.system(size: DesignTokens.FontSize.menuTitle, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 分组标题（"外置磁盘"），只给列表区做语义分组，不再兼任应用名。
    private var sectionCaption: some View {
        HStack {
            Text(L10n.tr(.menuExternalDisks))
                .font(.system(size: DesignTokens.FontSize.sectionCaption, weight: .medium))
                .foregroundStyle(DesignTokens.Palette.mutedForeground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                Text(L10n.tr(.noRemovableDisks))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }

    // MARK: - 磁盘列表

    private var diskList: some View {
        VStack(spacing: 4) {
            ForEach(store.disks) { disk in
                MenuDiskRow(
                    disk: disk,
                    occupancy: occupancy[disk.id] ?? .none,
                    accent: accent,
                    onEject: { onEject(disk) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: - 分隔线

    private var separator: some View {
        Rectangle()
            .fill(DesignTokens.Palette.border)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    // MARK: - 动作区

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionRow(
                systemName: "macwindow",
                label: L10n.tr(.openMainWindow),
                action: onOpenMainWindow
            )
            MenuActionRow(
                systemName: "arrow.clockwise",
                label: L10n.tr(.refresh),
                action: onRefresh
            )
            MenuActionRow(
                systemName: "gear",
                label: L10n.tr(.openSettings),
                action: onOpenSettings
            )
            Rectangle()
                .fill(DesignTokens.Palette.border)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            MenuActionRow(
                systemName: "rectangle.portrait.and.arrow.right",
                label: L10n.tr(.quit),
                action: onQuit,
                isDestructive: true
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: - 数据

    private func refreshOccupancy() async {
        let disks = store.disks
        guard !disks.isEmpty else {
            occupancy = [:]
            return
        }
        var results: [String: OccupancyResult] = [:]
        await withTaskGroup(of: (String, OccupancyResult).self) { group in
            for d in disks {
                group.addTask {
                    let r = await EjectFlowController.shared.checkOccupancy(mountPath: d.mountPath)
                    return (d.id, r)
                }
            }
            for await (id, r) in group {
                results[id] = r
            }
        }
        occupancy = results
    }
}

// MARK: - 菜单栏紧凑行的文案（纯函数，UI 只渲染不判断）
//
// **为什么单独抽出来**：菜单栏面板宽 360pt，这三行文案必须放得进去，否则又会回到
// 「列表项显示不全」。把文案构成收敛成无视图依赖的纯函数后，单测可以直接断言
// 「无占用时不产生第三行文案」（= 不渲染、行高自适应）与「总容量带括号」，
// 而不必去视图里猜字符串是怎么拼的。

enum MenuDiskRowText {

    /// ① 名称右侧的括号总容量，如「（1 TB）」。
    ///
    /// 括号本体来自本地化（中文全角「（）」/ 英文半角「()」），不写死。
    static func capacity(_ disk: DiskInfo) -> String {
        String(format: L10n.tr(.capacityInParenthesesFormat), disk.totalFormatted)
    }

    /// ② 已用 / 剩余，如「已用 300 GB · 剩余 700 GB」。
    static func usage(_ disk: DiskInfo) -> String {
        "\(L10n.tr(.usedSpace)) \(disk.usedFormatted) · "
            + "\(L10n.tr(.freeSpace)) \(disk.freeFormatted)"
    }

    /// ③ 占用进程行，如「占用程序: IINA、tail」。列表分隔符随语言（中文「、」/ 英文「, 」）。
    ///
    /// **没有可列出的进程时返回 `nil`**，调用方据此**整行不渲染**，行高自适应。
    /// 注意 `.needsFullDiskAccess` / `.unknown` 也返回 `nil`——它们是「不知道」而不是
    /// 「没有占用」，若渲染成「无进程占用」会让用户误以为可以安全推出。
    static func occupancy(_ result: OccupancyResult) -> String? {
        let names = result.processes.map(\.name)
        guard !names.isEmpty else { return nil }
        let joined = names.joined(separator: L10n.tr(.processNameListSeparator))
        return "\(L10n.tr(.occupiedProcessesTitle)) \(joined)"
    }
}

// MARK: - 磁盘列表行（设计稿：图标容器 + 名称 + meta + 描边推出按钮）
//
// 主窗口（800×520）与菜单栏 panel（360px）共用同一套行布局，但文本列按模式分两套排版：
// - 菜单栏（默认）：三行——「名称 （总容量）」「已用 X · 剩余 Y」「占用进程（有占用才有）」。
// - 主窗口（`expandProcessTags: true`）：名称 + 一行 meta，占用进程用 `ProcessTag` 标签另起一行。
// `hasCard: true` 把整行框成圆角 + 1px 边框的卡片，跟菜单栏 panel 的 `.disk-popup-card`
// 视觉一致；主窗口独占。

struct MenuDiskRow: View {
    let disk: DiskInfo
    let occupancy: OccupancyResult
    let accent: AccentColor
    let onEject: () -> Void
    /// 主窗口用：在行下方展开占用进程标签（菜单栏默认 false，节省纵向空间）。
    var expandProcessTags: Bool = false
    /// 主窗口用：在安全/未授权分支显示「✓ 无进程占用」一行（菜单栏默认 false，meta 已含信息）。
    var showSafeToEjectCaption: Bool = false
    /// 主窗口用：推出中显示 spinner + "推出中"（菜单栏用不到）。
    var isEjecting: Bool = false
    /// 主窗口用：把整行包成圆角 + 1px 边框卡片（菜单栏 panel 同款）。
    var hasCard: Bool = false

    @State private var hovering = false

    var body: some View {
        // 头部与状态区之间的间距由 `spacing: 2` + 头部非对称 padding 控制：
        // 应用信息（进程标签）视觉上更靠近顶部，不再被大间距"压沉"。
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                IconBadge(systemName: "externaldrive.fill", style: .menuRow, accent: accent)
                infoColumn
                Spacer(minLength: 8)
                if isEjecting {
                    ejectingButton
                } else {
                    ejectButton
                }
            }
            .padding(.horizontal, 12)
            // 头部上下留白非对称：上 12 / 下 6（卡片展开模式），让下方进程标签整体上提。
            .padding(.top, expandProcessTags ? 12 : 8)
            .padding(.bottom, expandProcessTags ? 6 : 8)

            if expandProcessTags {
                // 状态区（占用/安全/未知/FDA 未授权）
                statusSection
                    .padding(.leading, 10 + DesignTokens.Size.menuIconContainer)
                    .padding(.bottom, 4)
            }
        }
        .background(rowBackground)
        .overlay(rowBorder)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(DesignTokens.Motion.fast, value: hovering)
    }

    /// 行背景：菜单栏 panel 模式 = hover 时出 muted 背景（无 hasCard）；
    /// 主窗口卡片模式 = 始终显示极轻 accent 染色卡片，hover 时加深。
    @ViewBuilder
    private var rowBackground: some View {
        if hasCard {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(
                    hovering
                        ? accent.swiftUIColor.opacity(0.10)
                        : accent.swiftUIColor.opacity(0.06)
                )
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(hovering ? DesignTokens.Palette.mutedBackground : Color.clear)
        }
    }

    /// 行边框：hasCard 时绘制 1px accent hairline（菜单栏 panel 同款）。
    @ViewBuilder
    private var rowBorder: some View {
        if hasCard {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(
                    hovering ? accent.swiftUIColor.opacity(0.30) : DesignTokens.Palette.border,
                    lineWidth: 1
                )
        }
    }

    /// 副标题：容量 + 占用状态（设计稿"1 TB · 已用 300 GB / 剩余 700 GB"）。
    ///
    /// **仅主窗口（``expandProcessTags == true``）使用**。菜单栏面板只有 360pt 宽，
    /// 这一整串（实测约 250pt）必然被截断成"显示不全"，因此菜单栏改走
    /// ``MenuDiskRowText`` 的三行排版，不再复用本属性。
    private var metaText: String {
        let cap =
            "\(ByteFormat.string(disk.totalBytes)) · \(L10n.tr(.usedSpace)) \(ByteFormat.string(disk.usedBytes)) / \(L10n.tr(.freeSpace)) \(ByteFormat.string(disk.freeBytes))"
        switch occupancy {
        case .occupied(let ps):
            return cap + " · " + String(format: L10n.tr(.menuOccupiedFormat), ps.count)
        case .none:
            return cap
        case .needsFullDiskAccess, .unknown:
            return cap
        }
    }

    /// 行内文本列。**菜单栏与主窗口是两套排版**，不能共用同一串 meta：
    ///
    /// - 主窗口（``expandProcessTags == true``）：名称 + 一行 meta（容量/已用/剩余/占用个数），
    ///   下方再用 ``ProcessTag`` 标签列出进程——卡片有 800pt 宽，放得下。
    /// - 菜单栏（默认）：面板只有 360pt 宽，原先那行 meta 实测需要约 250pt 的文本宽度，
    ///   而实际可用仅约 220pt → **必然截断**（用户报的"列表项显示不全"）。故拆成三行：
    ///   ① `名称 （总容量）` ② `已用 X · 剩余 Y` ③ 占用进程（**无占用时整行不存在**，行高自适应）。
    @ViewBuilder
    private var infoColumn: some View {
        if expandProcessTags {
            VStack(alignment: .leading, spacing: 2) {
                nameText
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaText)
                    .font(.system(size: DesignTokens.FontSize.menuDiskMeta))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                // ① 名称 （总容量）。容量取 `layoutPriority(1) + fixedSize()`：
                //   名称过长时截断的是名称，括号里的容量始终完整可见。
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    nameText
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(MenuDiskRowText.capacity(disk))
                        .font(.system(size: DesignTokens.FontSize.menuDiskMeta))
                        .foregroundStyle(DesignTokens.Palette.mutedForeground)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .fixedSize()
                }
                // ② 已用 / 剩余
                Text(MenuDiskRowText.usage(disk))
                    .font(.system(size: DesignTokens.FontSize.menuDiskMeta))
                    .foregroundStyle(DesignTokens.Palette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // ③ 占用进程——没有占用时**不渲染这一行**，行高随内容自适应。
                if let occupancyText = MenuDiskRowText.occupancy(occupancy) {
                    Text(occupancyText)
                        .font(.system(size: DesignTokens.FontSize.menuDiskMeta))
                        .foregroundStyle(DesignTokens.Palette.warning)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// 磁盘名（字号随模式：主窗口卡片 14pt / 菜单栏 13pt）。
    private var nameText: some View {
        Text(disk.displayName)
            .font(
                .system(
                    size: expandProcessTags
                        ? DesignTokens.FontSize.diskCardName - 2
                        : DesignTokens.FontSize.menuDiskName,
                    weight: .medium)
            )
            .foregroundStyle(DesignTokens.Palette.foreground)
    }

    /// 状态区（仅在主窗口展开模式下展示），与 ProcessTag 的视觉权重对齐。
    @ViewBuilder
    private var statusSection: some View {
        switch occupancy {
        case .occupied(let processes):
            HStack(spacing: 12) {
                ForEach(processes) { p in
                    ProcessTag(process: p)
                }
            }
        case .none:
            if showSafeToEjectCaption {
                SafeToEjectRow()
            }
        case .needsFullDiskAccess, .unknown:
            // 这两种状态已通过主窗口顶部 FDA 横幅或全局状态覆盖，行内不重复。
            EmptyView()
        }
    }

    /// 推出按钮（描边 → hover 反色）。
    ///
    /// **用 SwiftUI Button**：SwiftUI Button 的点击响应在 macOS 上经过 NSButton 路径，
    /// 第一次点击立即可触发，比 `onTapGesture` 可靠（`onTapGesture` 在 SwiftUI 第一次
    /// 渲染后存在约 1 个 runloop tick 的注册延迟，会导致"第一次点击没反应，第二次
    /// 才有反应"——这是用户报告的核心症状）。
    ///
    /// **去焦点环**：配 `.buttonStyle(.plain)` + `.focusable(false)` +
    /// `.disableFocusRingIfAvailable()`——`focusable(false)` 让视图不进入 focus 系统
    /// （SwiftUI 默认会让第一个 Button 拿到 firstResponder），`focusEffectDisabled`
    /// 在 macOS 14+ 兜底。
    private var ejectButton: some View {
        Button(action: onEject) {
            Text(L10n.tr(.eject))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent.swiftUIColor)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .strokeBorder(accent.swiftUIColor, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .help(L10n.tr(.eject))
        .accessibilityAddTraits(.isButton)
    }

    /// 推出中状态（不能用原按钮，否则 disabled 视觉破坏对齐）。
    private var ejectingButton: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(L10n.tr(.ejecting))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(DesignTokens.Palette.mutedForeground)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(DesignTokens.Palette.mutedForeground.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - 菜单栏动作行（设计稿：图标 + 文字，hover 加 muted 底色）
//
// **用 SwiftUI Button + .buttonStyle(.plain)**：相比 `onTapGesture`，SwiftUI Button
// 第一次点击响应更可靠（`onTapGesture` 在 SwiftUI 首次渲染后有约 1 个 runloop tick
// 的注册延迟，会让"第一次点击没反应"——这是用户报告的核心症状）。
//
// **去焦点环**：`.buttonStyle(.plain)` + `.focusable(false)` +
// `.disableFocusRingIfAvailable()`——`focusable(false)` 让视图不进入 focus 系统
// （SwiftUI 默认会让第一个 Button 拿到 firstResponder），`focusEffectDisabled` 在
// macOS 14+ 兜底。Hover 高亮仍由 `@State hovering` + `.onHover` 手动驱动。

struct MenuActionRow: View {
    let systemName: String
    let label: String
    let action: () -> Void
    var isDestructive: Bool = false

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(
                        isDestructive
                            ? DesignTokens.Palette.error
                            : DesignTokens.Palette.mutedForeground
                    )
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(
                        isDestructive
                            ? DesignTokens.Palette.error
                            : DesignTokens.Palette.foreground
                    )
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(hovering ? DesignTokens.Palette.mutedBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disableFocusRingIfAvailable()
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
