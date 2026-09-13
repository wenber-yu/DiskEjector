import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 菜单栏面板里磁盘行的**排版契约**测试。
///
/// **为什么需要**：面板宽 360pt，磁盘行里能放文本的宽度只剩约 220pt（扣掉图标容器、
/// 推出按钮与左右内边距）。历史上四段信息（总容量 / 已用 / 剩余 / 占用进程数）被拼在
/// **同一行** meta 里（实测文本宽约 250pt）→ 必然被截断，用户看到的就是「列表项显示不全」。
///
/// 现在拆成三行，本测试把两件事钉死：
/// ① 无占用时**不产生第三行**（行高随内容自适应，而不是留一行空白）；
/// ② 三行文案连同图标、按钮的总宽必须放得进 360pt 面板（放不下就会被截断）。
@MainActor
struct MenuDiskRowLayoutTests {

    /// 面板内容宽：360 − 磁盘列表左右各 8pt 内边距。
    private let panelContentWidth = DesignTokens.Size.menuPopoverWidth - 16

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

    /// 菜单栏模式（默认参数）的磁盘行。
    private func row(occupancy: OccupancyResult) -> some View {
        MenuDiskRow(
            disk: sampleDisk,
            occupancy: occupancy,
            accent: .default,
            onEject: {}
        )
    }

    /// 在给定宽度下渲染，返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    ///
    /// 先 `setFrameSize(width, 0)` 再 `layoutSubtreeIfNeeded()` 是必需的：NSHostingController
    /// 的内容在首次布局前 `preferredContentSize` 仍是 0，直接取会拿到无约束的理想尺寸。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        // `NSApp` 由 AppKit 建共享实例时赋值；宿主 SwiftUI 视图前必须先起它。
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(NSSize(width: width, height: 0))
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize
    }

    /// 不受宽度约束时的**理想宽度**——这是「会不会被截断」的判据：
    /// 理想宽度超过可用宽度，SwiftUI 只能截断。
    private func idealWidth(_ view: some View) -> CGFloat {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    // MARK: - 文案构成

    @Test func 无占用进程时不产生占用行文案() {
        #expect(MenuDiskRowText.occupancy(.none) == nil)
        #expect(
            MenuDiskRowText.occupancy(.needsFullDiskAccess) == nil,
            "「未授权」是「不知道」而不是「没有占用」，不能渲染成占用行或安全提示"
        )
        #expect(MenuDiskRowText.occupancy(.unknown) == nil)
    }

    @Test func 有占用进程时逐行列名() {
        let text = MenuDiskRowText.occupancy(.occupied(sampleProcesses))
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
        let text = MenuDiskRowText.occupancy(.occupied(processes))
        #expect(text?.contains("Bunny") == true, "实际：\(text ?? "nil")")
        #expect(
            text?.contains("IMVIDEO") != true,
            "占用行出现了进程可执行名，用户认不出这是哪个应用；实际：\(text ?? "nil")")
    }

    @Test func 总容量以括号附在名称右侧() {
        let text = MenuDiskRowText.capacity(sampleDisk)
        #expect(text.contains(sampleDisk.totalFormatted))
        // 括号本身来自本地化，中文全角 / 英文半角都算通过——不能把断言绑死在当前语言上。
        #expect(text.hasPrefix("（") || text.hasPrefix("("), "总容量必须被括号包起来，实际：\(text)")
        #expect(text.hasSuffix("）") || text.hasSuffix(")"))
    }

    @Test func 已用与剩余同处一行且不换行() {
        let text = MenuDiskRowText.usage(sampleDisk)
        #expect(text.contains(L10n.tr(.usedSpace)))
        #expect(text.contains(L10n.tr(.freeSpace)))
        #expect(!text.contains("\n"))
    }

    // MARK: - 自适应与截断

    @Test func 有占用时行高变高但只多一行() {
        let free = renderedSize(row(occupancy: .none), width: panelContentWidth)
        let busy = renderedSize(row(occupancy: .occupied(sampleProcesses)), width: panelContentWidth)
        #expect(
            busy.height > free.height,
            "有占用进程时应多出第三行、行高变大；实际 无占用 \(free.height)pt / 有占用 \(busy.height)pt"
        )
        #expect(
            busy.height - free.height <= 20,
            "新增高度 \(busy.height - free.height)pt 超过一行（11pt 字 + 2pt 行距）——占用行撑成了两块或行距失控"
        )
    }

    @Test func 整行放得进菜单栏面板不被截断() {
        for (tag, occupancy) in [
            ("无占用", OccupancyResult.none),
            ("有占用", OccupancyResult.occupied(sampleProcesses)),
        ] {
            let width = idealWidth(row(occupancy: occupancy))
            #expect(
                width <= panelContentWidth,
                "\(tag)时整行理想宽度 \(width)pt > 面板可用 \(panelContentWidth)pt，会被截断"
            )
        }
    }
}
