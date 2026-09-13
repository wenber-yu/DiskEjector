import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 进程标签（``ProcessTag``）的**布局契约**测试。
///
/// **为什么需要**：主窗口里「图标 + 应用名」这两样东西必须落在背景色块的**正中央**。
/// 这件事没有编译期约束——历史上正是靠 `.padding(.top, 8) / .padding(.bottom, 3)` 这种
/// 非对称内边距凑出来的，结果内容在色块里下压 2.5pt（上留白 9.5pt / 下留白 4pt），
/// 肉眼就是「没居中、贴着底边」，而且改一个数不会让任何测试变红。
///
/// 现在居中由 `.frame(height: DesignTokens.Size.processTagHeight)` 的结构保证，
/// 本测试把该内高钉死：一旦有人重新用非对称 padding（或删掉这个 frame）凑高度，
/// 渲染出的实际高度就会偏离契约值，测试立刻变红。
@MainActor
struct ProcessTagLayoutTests {

    /// 造一个标签并返回它的**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    private func renderedSize(name: String) -> CGSize {
        // `NSApp` 这个全局由 AppKit 建共享实例时赋值；宿主一个 SwiftUI 视图前必须先起它，
        // 否则 SwiftUI 内部拿 `NSApp` 会崩在隐式解包上。
        _ = NSApplication.shared
        let tag = ProcessTag(
            process: OccupyingProcess(pid: 4242, processName: name, path: "/Volumes/Demo/clip.mp4"))
        let hosting = NSHostingController(rootView: tag)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize
    }

    @Test func 背景色块内高等于契约值() {
        let size = renderedSize(name: "DemoApp")
        #expect(
            size.height == DesignTokens.Size.processTagHeight,
            "标签实际内高 \(size.height)pt ≠ 契约值 \(DesignTokens.Size.processTagHeight)pt——色块高度不是由 frame 固定的（很可能又用非对称 padding 凑数，那会让内容在色块里上下不居中）"
        )
    }

    /// 内高必须**大于**图标高，且差值可被上下**均分**——这是「内容垂直居中」的几何前提。
    @Test func 图标上下留白可均分() {
        let extra = DesignTokens.Size.processTagHeight - DesignTokens.Size.processTagIcon
        #expect(extra > 0, "色块内高必须大于图标高，否则图标会被压扁/裁切")
        #expect(extra.truncatingRemainder(dividingBy: 2) == 0, "上下留白应是整数点，避免半像素渲染")
    }

    /// 宽度至少要放下「左右内边距 + 图标 + 图标与文字间距 + 文字」，否则内容会被挤出色块。
    @Test func 宽度吃得住图标与文字() {
        let size = renderedSize(name: "DemoApp")
        let minimum = 16 + DesignTokens.Size.processTagIcon + 6
        #expect(size.width > minimum, "标签渲染宽度 \(size.width)pt 未超过仅有图标时的最小宽度 \(minimum)pt")
    }

    /// 造一个 `displayName` / `processName` 各异的标签并返回渲染宽度。
    private func renderedWidth(displayName: String, processName: String) -> CGFloat {
        _ = NSApplication.shared
        let tag = ProcessTag(
            process: OccupyingProcess(
                pid: 4242, processName: processName, displayName: displayName,
                path: "/Volumes/Demo/clip.mp4"))
        let hosting = NSHostingController(rootView: tag)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    /// **回归**：标签里渲染的是**应用名**（``OccupyingProcess/displayName``），不是进程可执行名。
    ///
    /// 用户报的现象是「应用叫 Bunny，界面显示 IMVIDEO」。这里用**渲染宽度**做判据：
    /// 把长字符串放到 `processName`、短字符串放到 `displayName`，再交换一次比宽度——
    /// 宽度跟着 `displayName` 走就证明渲染的确实是它。
    /// （变异：把 `Text(process.displayName)` 改回 `Text(process.processName)`，大小关系反转。）
    @Test func 渲染的是应用名而不是进程可执行名() {
        let longName = "IMVIDEO-NOT-SHOWN-NAME"
        let shortName = "Bunny"
        let shortAsDisplayName = renderedWidth(displayName: shortName, processName: longName)
        let longAsDisplayName = renderedWidth(displayName: longName, processName: shortName)
        #expect(
            shortAsDisplayName < longAsDisplayName,
            "标签宽度没跟着 displayName 走（短名 \(shortAsDisplayName)pt / 长名 \(longAsDisplayName)pt）——很可能渲染的是 processName"
        )
    }
}
