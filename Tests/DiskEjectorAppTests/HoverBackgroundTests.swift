import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 「hover 底色比按钮盒子小一圈」的守卫。
///
/// 用户 2026-09-16：「设置窗口的完成按钮以及主窗口的刷新、设置按钮的 hover 效果背景小一点」。
/// 机制收在 ``HoverBackground`` **一个类型**里，所以这里量它一次，三处（标题栏刷新、
/// 标题栏设置、设置面板「完成」）都算守住了。
///
/// ## ⚠️ 这是**有意偏离设计稿**，别拿设计稿当依据改回去
///
/// `ds.css` 写的是整盒变底色：`.iconbtn:hover { background: var(--bg-subtle) }`（`.iconbtn` 28×28）、
/// `.btn--outline:hover { background: var(--bg-subtle) }`。实现最初照抄了它，
/// 用户明确要求收小 —— **用户偏好优先于设计稿字面**。依据记在 `DESIGN-SPEC.md` §8.19。
///
/// ## 为什么能量到
///
/// `hovering` 是 `@State private`，只能由真实鼠标移动触发（`.onHover` 需要应用在前台
/// 且鼠标真的移过去，`NSApp.postEvent` 合成的 NSEvent 走不到窗口服务器），
/// 离屏测试够不着 —— 这正是「底色到底多大」原本没人守的原因。
/// 把底色抽成 ``HoverBackground`` 之后，可以直接给它一个纯色、量渲染后的包围盒。
@MainActor
struct HoverBackgroundTests {

    private let box = DesignTokens.Size.titleBarIconButton  // 28

    /// 纯黑底色的包围盒 —— **必须用纯色**：`subtle` 在浅色底上接近白，
    /// 阈值怎么定都说不清；纯黑才让「覆盖到哪」是确定的。
    private func coveredSize(inset: CGFloat) -> CGSize? {
        OffscreenRender.boundingBox(
            HoverBackground(color: .black, inset: inset),
            size: CGSize(width: box, height: box)
        ) { $0.redComponent < 0.5 && $0.greenComponent < 0.5 && $0.blueComponent < 0.5 }?.size
    }

    @Test func 底色比盒子小一圈() {
        guard let size = coveredSize(inset: DesignTokens.Size.hoverBackgroundInset) else {
            Issue.record("没量到任何底色像素 —— 渲染没成功，或判据坏了，这条断言不能算通过")
            return
        }
        let expected = box - 2 * DesignTokens.Size.hoverBackgroundInset
        let inset = DesignTokens.Size.hoverBackgroundInset
        let measured = "\(size.width)×\(size.height)"
        print("  [hover 底色] 盒 \(box)pt，内缩 \(inset)pt，量到 \(measured)pt（期望 \(expected)）")
        #expect(
            abs(size.width - expected) < 1 && abs(size.height - expected) < 1,
            """
            底色量到 \(size.width)×\(size.height)，期望 \(expected)×\(expected)。\
            量到 \(box)×\(box) 说明 `.padding(inset)` 没了 —— 又变回设计稿的「整盒变底色」；\
            用户 2026-09-16 要的正是「hover 背景小一点」。
            """
        )
    }

    /// **这条守的是「用户诉求」本身，不是机制。**
    ///
    /// 为什么不能只留上面那条：它的期望值 `box − 2 × inset` 是**从令牌算出来的** ——
    /// 把 `hoverBackgroundInset` 改成 0，「期望」也跟着变成整盒，断言照样通过。
    /// 那就成了「拿常量跟自己比」：看着在守，其实守不住（本项目栽过这个坑，
    /// 见 `TitleBarBaselineTests` 里 `bandCenterSlack` 那段变异验证记录）。
    ///
    /// 用户要的是「小一点」这件事**本身**，所以这里钉一个**绝对**下限：
    /// 每边至少缩 2pt，否则就不叫「小一点」。
    @Test func 底色必须明显小于盒子() {
        guard let size = coveredSize(inset: DesignTokens.Size.hoverBackgroundInset) else {
            Issue.record("没量到任何底色像素 —— 渲染没成功，或判据坏了，这条断言不能算通过")
            return
        }
        #expect(
            size.width <= box - 4 && size.height <= box - 4,
            """
            底色量到 \(size.width)×\(size.height)，盒子是 \(box)×\(box) —— 每边缩不到 2pt，\
            这和设计稿的「整盒变底色」就没区别了。用户 2026-09-16 要的是「hover 效果背景小一点」，\
            请调大 `DesignTokens.Size.hoverBackgroundInset`（当前 \(DesignTokens.Size.hoverBackgroundInset)）。
            """
        )
    }

    /// **反面对照**：`inset: 0` 必须量到整盒。
    ///
    /// 没有这一条的话，上面那条「比盒子小」有可能只是**量测本身偏小**
    /// （判据太严、边缘抗锯齿被排除）—— 两者看起来一模一样。
    @Test func 内缩为零时底色就是整盒() {
        guard let size = coveredSize(inset: 0) else {
            Issue.record("inset=0 时没量到底色像素 —— 判据坏了，上面那条断言也不能算通过")
            return
        }
        #expect(
            abs(size.width - box) < 1 && abs(size.height - box) < 1,
            "inset=0 时底色量到 \(size.width)×\(size.height)，期望整盒 \(box)×\(box)"
        )
    }

    /// 收小不能收过头：底色得**装得下图标**，否则图标会溢出底色，看着像没对齐。
    @Test func 底色仍然装得下图标() {
        let iconSize = 14.0  // 标题栏图标的字号
        let inner = box - 2 * DesignTokens.Size.hoverBackgroundInset
        #expect(
            inner >= iconSize,
            "底色只有 \(inner)pt，比图标 \(iconSize)pt 还小 —— 图标会溢出底色，看着像没对齐")
    }

    /// 圆角必须**随内缩同心**，否则小一圈的底色在四角会比外框更「方」，
    /// 描边与底色之间的缝在角上比边上宽，看上去像没对齐。
    @Test func 圆角随内缩同心() {
        #expect(
            abs(DesignTokens.Radius.concentric(inset: 0) - DesignTokens.Radius.sm) < 0.001,
            "内缩为 0 时圆角必须回到设计稿的 sm（\(DesignTokens.Radius.sm)）")
        #expect(
            DesignTokens.Radius.concentric(inset: 3) < DesignTokens.Radius.sm,
            "内缩时圆角必须跟着变小，否则底色四角会比外框「方」")
        #expect(
            DesignTokens.Radius.concentric(inset: 99) == 0,
            "内缩超过圆角本身时应夹到 0，不能变负数（负圆角会让 RoundedRectangle 画出怪形）")
    }
}
