import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 磁盘行的**排版与判定契约**测试。
///
/// **为什么需要**：这里同时钉住两类容易悄悄坏掉的东西 ——
/// ① 菜单栏面板宽 360pt，磁盘行里能放文本的宽度只剩约 320pt，
///    历史上四段信息被拼在**同一行** meta 里（实测文本宽约 250pt）→ 必然截断，
///    用户看到的就是「列表项显示不全」；
/// ② **「未知」不能被渲染成「没有占用」**。这是本应用最不能犯的错误：
///    未授权时若显示「可以安全推出」，用户会以为可以拔，而 Spotlight 可能正抓着这块盘。
@MainActor
struct MenuDiskRowLayoutTests {

    /// 菜单栏面板里磁盘行的**外框宽**：360 − 列表左右各 8pt。
    ///
    /// ⚠️ **不要再减行自己的 8pt**：`MenuBarDiskRow` 自带 `.padding(8)`，
    /// 它接收的宽度就是外框宽 344，内容列才是 328。
    /// 曾经写成 328（把行自己的内边距也减掉了），于是所有「会不会被截断」的判断
    /// 都是在**比真机窄 16pt** 的前提下做的 —— 真机上放得下的文案，测试里会判成截断；
    /// 反过来，真机上会被截断的长文案（如「占用程序：Finder、图像捕捉」），
    /// 测试里反而看不出问题。
    private let panelRowWidth = DesignTokens.Size.menuPopoverWidth - 2 * DesignTokens.Spacing.sm

    /// 行内真正能放**文本**的宽度。
    ///
    /// 设计稿 `.mrow` 是 `grid-template-columns: 32px 1fr auto` + `column-gap: 10px`，
    /// 文本列实测 248pt。这里按同一套算式算出来（外框 344 − 行内边距 16 − 图标 32
    /// − 两个 10pt 列间距 − 按钮 26 = 250），给「第三行会不会被截断」当判据。
    private var panelContentWidth: CGFloat {
        panelRowWidth - 2 * DesignTokens.Spacing.sm
            - DesignTokens.Size.menuIconContainer
            - DesignTokens.Size.buttonSmallHeight
            - 10 * 2
    }

    private let sampleDisk = DiskInfo(
        id: "/Volumes/My Passport",
        bsdName: "disk4s2",
        volumeName: "My Passport",
        mountPath: "/Volumes/My Passport",
        totalBytes: 1_000_000_000_000,
        usedBytes: 300_000_000_000,
        freeBytes: 700_000_000_000,
        deviceProtocol: "USB",
        deviceModel: "SanDisk Extreme 55AE"
    )

    private let sampleProcesses = [
        OccupyingProcess(pid: 5340, processName: "IINA", path: "/Volumes/My Passport/clip.mp4"),
        OccupyingProcess(pid: 39298, processName: "tail", path: "/Volumes/My Passport/clip.mp4"),
    ]

    /// 菜单栏模式的磁盘行。
    private func row(occupancy: OccupancyResult) -> some View {
        MenuBarDiskRow(
            disk: sampleDisk,
            occupancy: occupancy,
            accent: .default,
            onEject: {}
        )
    }

    /// 主窗口模式的磁盘行。
    private func mainRow(occupancy: OccupancyResult, density: DiskRowDensity = .regular) -> some View {
        DiskRow(
            disk: sampleDisk,
            occupancy: occupancy,
            accent: .default,
            onEject: {},
            density: density
        )
    }

    /// 在给定宽度下渲染，返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    ///
    /// ⚠️ 用 `sizeThatFits(in:)` 而不是 `setFrameSize + fittingSize`：
    /// 后者返回的是**无宽度约束的理想尺寸**，宽度根本不生效。菜单栏行的理想宽约 365pt，
    /// 而这里传入的是 328pt —— 旧写法量到的其实是「365pt 宽下的高」，
    /// 与「328pt 宽下的高」不是一回事（文案要折行时差别明显）。
    /// 详细对照实验见 `SettingsLayoutTests.renderedSize` 的注释。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        // `NSApp` 由 AppKit 建共享实例时赋值；宿主 SwiftUI 视图前必须先起它。
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// 不受宽度约束时的**理想宽度**——这是「会不会被截断」的判据：
    /// 理想宽度超过可用宽度，SwiftUI 只能截断。
    private func idealWidth(_ view: some View) -> CGFloat {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    // MARK: - 判定归约（安全关键）

    /// **本应用最不能犯的错误**：把「不知道」渲染成「没有占用」。
    @Test func 未知状态绝不被归约为安全() {
        #expect(DiskRowState(.unknown) == .unknown)
        #expect(
            DiskRowState(.needsFullDiskAccess) == .unknown,
            "「未授权」是「不知道」而不是「没有占用」，不能归约成 .safe——那会让用户以为可以拔盘"
        )
        #expect(DiskRowState(.none) == .safe)
        #expect(DiskRowState(.occupied(sampleProcesses)) == .busy(sampleProcesses))
    }

    @Test func 占用列表为空时归约为安全() {
        #expect(DiskRowState(.occupied([])) == .safe, "lsof 返回 0 行时是「确认没占用」，不是「忙」")
    }

    // MARK: - 文案构成

    @Test func 无占用进程时不产生占用行文案() {
        #expect(DiskRowText.occupancy(.none) == nil)
        #expect(
            DiskRowText.occupancy(.needsFullDiskAccess) == nil,
            "「未授权」是「不知道」而不是「没有占用」，不能渲染成占用行或安全提示"
        )
        #expect(DiskRowText.occupancy(.unknown) == nil)
    }

    @Test func 有占用进程时逐行列名() {
        let text = DiskRowText.occupancy(.occupied(sampleProcesses))
        #expect(text?.contains("IINA") == true, "占用行必须列出进程名，实际：\(text ?? "nil")")
        #expect(text?.contains("tail") == true)
        #expect(
            text?.contains(L10n.tr(.processNameListSeparator)) == true,
            "多个进程之间要用本地化分隔符（中文「、」/ 英文「, 」）"
        )
    }

    /// **回归**：占用行必须显示**应用名**，而不是进程可执行名。
    ///
    /// 用户报的原话是「占用程序的应用叫 Bunny，现在显示的是 IMVIDEO」。
    /// 这条把该现象钉在文案层：两者不一致时，只能出现应用名。
    /// （变异：把 `map(\.displayName)` 改回 `map(\.processName)`，本断言立刻变红。）
    @Test func 占用行显示应用名而不是进程可执行名() {
        let processes = [
            OccupyingProcess(
                pid: 75019, processName: "IMVIDEO", displayName: "Bunny",
                appBundlePath: "/Applications/IMVIDEO.app", path: "/Volumes/wenbo-data/clip.mp4")
        ]
        let text = DiskRowText.occupancy(.occupied(processes))
        #expect(text?.contains("Bunny") == true, "实际：\(text ?? "nil")")
        #expect(
            text?.contains("IMVIDEO") != true,
            "占用行出现了进程可执行名，用户认不出这是哪个应用；实际：\(text ?? "nil")")
    }

    // MARK: - 行内动作的可访问性标签

    /// **回归**：行内按钮的 a11y 标签必须**自带磁盘名**。
    ///
    /// VoiceOver 是线性朗读的：焦点落到按钮上时，上一行念过的磁盘名早就过去了。
    /// 只念「推出」/「推出中」，多盘并列时用户根本听不出在动哪块盘。
    /// （变异：把 `ejectingAccessibilityLabel` 改回 `L10n.tr(.ejecting)`，本断言立刻变红。）
    @Test func 行内动作标签都带磁盘名() {
        let labels = [
            DiskRowText.ejectAccessibilityLabel(sampleDisk),
            DiskRowText.closeAndEjectAccessibilityLabel(sampleDisk),
            DiskRowText.ejectingAccessibilityLabel(sampleDisk),
        ]
        for label in labels {
            #expect(
                label.contains(sampleDisk.displayName),
                "「\(label)」里没有磁盘名 —— VoiceOver 用户听不出在操作哪块盘"
            )
        }
    }

    /// 三种标签必须彼此不同：否则「推出」「关闭并推出」「正在推出」在 VoiceOver 里
    /// 听起来一样，用户无法判断当前点到的是哪个动作、盘现在什么状态。
    @Test func 行内动作标签互不重复() {
        let eject = DiskRowText.ejectAccessibilityLabel(sampleDisk)
        let close = DiskRowText.closeAndEjectAccessibilityLabel(sampleDisk)
        let ejecting = DiskRowText.ejectingAccessibilityLabel(sampleDisk)
        #expect(Set([eject, close, ejecting]).count == 3, "三种动作标签出现重复：\(eject) / \(close) / \(ejecting)")
    }

    /// 证据区标题必须带进程个数（「2 个程序正在占用」），拿不到具体进程时退化为无数字版本。
    @Test func 证据区标题带进程个数() {
        let busy = DiskRowText.evidenceTitle(.busy(sampleProcesses))
        #expect(busy.contains("2"), "证据区标题应包含进程个数，实际：\(busy)")

        let fallback = DiskRowText.evidenceTitle(.busy([]))
        #expect(!fallback.isEmpty)
    }

    /// 三种状态的紧凑行短标签必须**两两不同**，否则用户无法区分「安全」与「未知」。
    @Test func 紧凑行三种状态标签互不相同() {
        let busy = DiskRowText.compactStatus(.busy(sampleProcesses))
        let safe = DiskRowText.compactStatus(.safe)
        let unknown = DiskRowText.compactStatus(.unknown)
        #expect(Set([busy, safe, unknown]).count == 3, "实际：\(busy) / \(safe) / \(unknown)")
    }

    @Test func 总容量以括号附在名称右侧() {
        let text = DiskRowText.capacity(sampleDisk)
        #expect(text.contains(sampleDisk.totalFormatted))
        // 括号本身来自本地化，中文全角 / 英文半角都算通过——不能把断言绑死在当前语言上。
        #expect(text.hasPrefix("（") || text.hasPrefix("("), "总容量必须被括号包起来，实际：\(text)")
        #expect(text.hasSuffix("）") || text.hasSuffix(")"))
    }

    /// 主窗口的容量徽标**不带括号**（设计稿 `.row__fs` 是独立 pill，括号是多余的）。
    @Test func 主窗口容量徽标不带括号() {
        let text = DiskRowText.capacityBadge(sampleDisk)
        #expect(text == sampleDisk.totalFormatted, "实际：\(text)")
    }

    @Test func 已用与剩余同处一行且不换行() {
        let text = DiskRowText.usage(sampleDisk)
        #expect(text.contains(L10n.tr(.usedSpace)))
        #expect(text.contains(L10n.tr(.freeSpace)))
        #expect(!text.contains("\n"))
    }

    @Test func 紧凑行meta同时含总容量已用与剩余() {
        let text = DiskRowText.compactMeta(sampleDisk)
        #expect(text.contains(sampleDisk.totalFormatted))
        #expect(text.contains(L10n.tr(.usedSpace)))
        #expect(text.contains(L10n.tr(.freeSpace)))
    }

    // MARK: - 自适应与截断

    /// 占用检测是**异步**的（`lsof` 较慢），结果到达时行高**不许跳动**。
    ///
    /// 菜单栏行固定三行文案（名称+容量 / 已用剩余 / 占用结论），
    /// 结论行三种状态都渲染（安全态是「可安全推出」、未知态是「占用情况未知」），
    /// 所以行高与占用结果无关 —— 用户不会看到列表在检测完成的瞬间抖一下。
    ///
    /// （旧实现是「有占用才多一行」，检测结果到达时整列会向下跳 16pt。
    /// 变异：把安全态/未知态的结论行改成不渲染，本断言立刻变红。）
    @Test func 占用结果到达时菜单栏行高不跳动() {
        let states: [(String, OccupancyResult)] = [
            ("无占用", .none),
            ("有占用", .occupied(sampleProcesses)),
            ("未知", .unknown),
            ("未授权", .needsFullDiskAccess),
        ]
        var heights: [(String, CGFloat)] = []
        for (tag, occupancy) in states {
            heights.append((tag, renderedSize(row(occupancy: occupancy), width: panelRowWidth).height))
        }
        let unique = Set(heights.map { $0.1 })
        #expect(
            unique.count == 1,
            "四种占用状态下的行高不一致 \(heights) —— 检测结果到达时列表会跳动"
        )
    }

    /// 但**内容**必须随状态变化：三种状态各自有结论文字（不能只有配色不同）。
    @Test func 菜单栏行结论文字随状态变化() {
        let safe = renderedSize(row(occupancy: .none), width: panelRowWidth)
        let busy = renderedSize(row(occupancy: .occupied(sampleProcesses)), width: panelRowWidth)
        // 行高相同、宽度可不同（文字长度不同）—— 这里断言两者都渲染成功且尺寸合理。
        #expect(safe.width > 0 && busy.width > 0)
        #expect(
            DiskRowText.compactStatus(.safe) != DiskRowText.compactStatus(.busy(sampleProcesses)),
            "安全态与占用态的结论文字不能相同"
        )
        #expect(
            DiskRowText.compactStatus(.unknown) != DiskRowText.compactStatus(.safe),
            "未知态不能复用安全态的文案——那等于把「不知道」说成「可以拔」"
        )
    }

    @Test func 菜单栏整行放得进面板不被截断() {
        for (tag, occupancy) in [
            ("无占用", OccupancyResult.none),
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
        ] {
            let width = idealWidth(row(occupancy: occupancy))
            #expect(
                width <= panelRowWidth,
                "\(tag)时整行理想宽度 \(width)pt > 面板可用 \(panelRowWidth)pt，会被截断"
            )
        }
    }

    /// 面板第三行的占用文案必须放得进文本列。
    ///
    /// **这是「占用程序：…」这一行的真实约束**：它比原来的「2 个程序占用」长得多，
    /// 而文本列只有约 250pt。一旦放不下，用户看到的是「占用程序：Finder、图像…」——
    /// 而「谁挡着」正是这一行存在的全部理由，截掉就等于没写。
    ///
    /// 用**设计稿里那对进程名**（Finder、图像捕捉）一起量，因为它们是这一行的
    /// 典型长度；只量 `IINA、tail` 这种短名字会高估余量。
    @Test func 菜单栏占用行放得进文本列() throws {
        let designLike = [
            OccupyingProcess(pid: 1, processName: "Finder", path: "/Volumes/x/a"),
            OccupyingProcess(pid: 2, processName: "图像捕捉", path: "/Volumes/x/b"),
        ]
        let candidates = [
            try #require(DiskRowText.occupancy(.occupied(sampleProcesses))),
            try #require(DiskRowText.occupancy(.occupied(designLike))),
        ]
        for text in candidates {
            let width = idealWidth(
                Text(text)
                    .font(.system(size: DesignTokens.FontSize.footnote, weight: .medium))
                    .lineLimit(1))
            #expect(
                width <= panelContentWidth,
                "占用行「\(text)」宽 \(width)pt > 文本列 \(panelContentWidth)pt，会被省略号截断"
            )
        }
    }

    /// 菜单栏磁盘行与动作行的高度必须与设计稿实测一致（69 / 32）。
    ///
    /// 面板是「一眼扫完」的界面，行高差 7pt 就是「比设计稿挤」的全部来源：
    /// 三行文本各按系统自然行高排时，整行只有 62pt（设计稿 69），
    /// 面板整体矮 7pt —— 单看每一行都不觉得错。
    @Test func 菜单栏行高与动作行高与设计稿一致() {
        let tolerance: CGFloat = 2
        for (tag, occupancy) in [
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
            ("无占用", OccupancyResult.none),
            ("未知", OccupancyResult.unknown),
        ] {
            let height = renderedSize(row(occupancy: occupancy), width: panelRowWidth).height
            #expect(
                abs(height - DesignTokens.Size.menuRowHeight) <= tolerance,
                "\(tag)时菜单栏行高 \(height)pt，设计稿实测 \(DesignTokens.Size.menuRowHeight)pt"
            )
        }

        let actionHeight = renderedSize(
            MenuActionRow(systemName: "macwindow", label: "打开主窗口", shortcut: "⌘O", action: {}),
            width: panelRowWidth
        ).height
        #expect(
            abs(actionHeight - DesignTokens.Size.menuActionRowHeight) <= tolerance,
            "动作行高 \(actionHeight)pt，设计稿实测 \(DesignTokens.Size.menuActionRowHeight)pt"
        )
    }

    /// 紧凑行必须**明显矮于**完整行——否则「一屏 8 块」的设计目标落空。
    @Test func 紧凑行显著矮于完整行() {
        let regular = renderedSize(mainRow(occupancy: .none, density: .regular), width: 800)
        let compact = renderedSize(mainRow(occupancy: .none, density: .compact), width: 800)
        #expect(
            compact.height < regular.height / 2,
            "紧凑行 \(compact.height)pt 未显著矮于完整行 \(regular.height)pt，切换密度没有意义"
        )
    }

    /// 阈值：≥ 4 块盘自动切紧凑行（设计稿 §3.3）。
    @Test func 四块盘起自动切紧凑行() {
        #expect(DiskRowDensity.forCount(1) == .regular)
        #expect(DiskRowDensity.forCount(3) == .regular)
        #expect(DiskRowDensity.forCount(4) == .compact)
        #expect(DiskRowDensity.forCount(8) == .compact)
    }

    /// 主窗口 800 × 520 里，**设计稿演示的那三块盘必须放得下**。
    ///
    /// 预算 = 窗口高 − 标题栏 − 列表上下内边距 = 520 − 52 − 28 = 440，
    /// 与设计稿实测的 `.disklist [766 × 440]` 一致。
    ///
    /// ⚠️ **这条断言曾经断言的是「最坏组合」**：1 块忙 + 2 块未知。
    /// 那个组合即使按设计稿的真实行高（169 / 133 / 133）也是
    /// `169 + 133×2 + 8×2 = 451 > 440` —— **设计稿自己都放不下**，
    /// 因为它的 `.scrollarea` 是 `overflow:hidden`，超出部分直接裁掉。
    /// 换句话说：这条断言在要求实现做到设计稿没做到的事。
    ///
    /// 现在改成断言**设计稿首页实际展示的组合**（1 忙 + 2 安全），
    /// 这正是 `.disklist` 恰好 440 的那个场景；更高的组合允许滚动 ——
    /// 主窗口有 `ScrollView`，比设计稿的硬裁更宽容，不是退化。
    @Test func 主窗口放得下设计稿演示的三块盘() {
        let titleBar = DesignTokens.Size.titleBarHeight
        let listPadding = DesignTokens.Spacing.md + DesignTokens.Spacing.lg
        let budget = DesignTokens.Size.mainWindow.height - titleBar - listPadding
        let spacing = DesignTokens.Spacing.sm

        let busy = renderedSize(mainRow(occupancy: .occupied(sampleProcesses)), width: 800).height
        let safe = renderedSize(mainRow(occupancy: .none), width: 800).height
        let need = busy + safe * 2 + spacing * 2
        #expect(
            need <= budget,
            "三块盘共需 \(need)pt（忙 \(busy) + 安全 \(safe) ×2 + 行距 \(spacing) ×2），超出预算 \(budget)pt —— 用户会看到滚动条"
        )
    }

    /// 单块盘无论什么状态都必须放得进列表区 —— 否则第一块盘就被裁掉了。
    @Test func 任意单块盘都放得进列表区() {
        let budget =
            DesignTokens.Size.mainWindow.height - DesignTokens.Size.titleBarHeight
            - DesignTokens.Spacing.md - DesignTokens.Spacing.lg
        for (tag, occupancy) in [
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
            ("无占用", OccupancyResult.none),
            ("未知", OccupancyResult.unknown),
        ] {
            let height = renderedSize(mainRow(occupancy: occupancy), width: 800).height
            #expect(height <= budget, "\(tag)时单行 \(height)pt > 列表预算 \(budget)pt")
        }
    }

    /// 完整行的高度必须与设计稿实测值一致（169 / 127 / 133）。
    ///
    /// **这是「看起来和设计稿一样」的核心数字**：三块盘各差 2pt，整列就差 6pt，
    /// 用户扫一眼就会觉得「比设计稿挤」——而每一处单独看都不觉得错。
    /// 曾经这里只有一条「总高 ±12」，把「行高整体矮 11pt」兜住了（详见
    /// `AlertLayoutTests` 里同类问题的记录）。
    @Test func 完整行三种状态高度与设计稿一致() {
        let tolerance: CGFloat = 2
        let specs: [(String, OccupancyResult, CGFloat)] = [
            ("有占用", .occupied(sampleProcesses), DesignTokens.Size.diskRowBusyHeight),
            ("无占用", OccupancyResult.none, DesignTokens.Size.diskRowSafeHeight),
            ("未知", .unknown, DesignTokens.Size.diskRowUnknownHeight),
        ]
        for (tag, occupancy, expected) in specs {
            let height = renderedSize(mainRow(occupancy: occupancy), width: 800).height
            #expect(
                abs(height - expected) <= tolerance,
                "\(tag)行高 \(height)pt，设计稿实测 \(expected)pt，差 \(height - expected)pt"
            )
        }
    }

    /// 证据区折叠后行高必须变矮（「收起清单」不是装饰）。
    @Test func 紧凑行按钮保留在行内() {
        let width = idealWidth(mainRow(occupancy: .occupied(sampleProcesses), density: .compact))
        #expect(
            width <= 800,
            "紧凑行理想宽度 \(width)pt 超过窗口宽 800pt，会被截断"
        )
    }
}
