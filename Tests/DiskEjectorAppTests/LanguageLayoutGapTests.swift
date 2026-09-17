import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// **已知缺陷的记录：固定高度容器只放得下中文。**
///
/// ## 这不是「测试写错了」，是产品缺陷
///
/// 设计稿写的是「四组内容在**中英文**下的实测高度决定 440 × 566」，
/// 但 2026-09-17 在英文下实测：**内容需要 612.25pt，容器只有 566pt**。
/// 多出来的部分会被折叠线藏到滚动区外 —— 与「关于」分组曾整个看不见是同一个后果。
///
/// 引导面板同理（设计稿 503.3，英文下实测 +56.7pt），弹窗的四处高度差 18–19pt 同源。
///
/// ## 这些测试为什么要「断言缺陷存在」
///
/// 它是一条**锁**：设计稿给出中英两套方案、容器随之变大之后，这些断言会**变红**，
/// 提醒你删掉本文件、改由 `SettingsLayoutTests` / `OnboardingLayoutTests` 里
/// 那条 `<=` 断言接管。**把缺陷钉住，比让它静默通过更有价值** ——
/// 静默通过意味着没人知道英文用户看到的是被截断的面板。
///
/// ## 为什么不在 `SettingsLayoutTests` 里顺手写
///
/// 那个文件的断言钉的是「**中文排版与设计稿一致**」（设计稿数字按中文实测），
/// 它已经被 `TestLanguage.with(TestLanguage.design)` 钉在中文下。
/// 本文件钉的是相反的问题 —— 「**换成英文会怎样**」。两件事，分开写才不会互相稀释。
///
/// 设计侧后续：由 UI 设计在设计稿中定义中英两套方案，本文件届时删除。
@MainActor
struct LanguageLayoutGapTests {

    /// 与各布局 suite 同口径：`sizeThatFits` 才是「给定宽度下的真实渲染尺寸」
    /// （`NSHostingView.fittingSize` 返回的是无宽度约束的理想尺寸）。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func settingsNeed(panelWidth: CGFloat) -> CGFloat {
        renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth).height
            + renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth).height
            + SettingsMetrics.bottomInset
    }

    @Test func 英文下设置面板放不下_已知缺陷() {
        let width = DesignTokens.Size.settingsPanel.width
        let container = DesignTokens.Size.settingsPanel.height

        let zh = TestLanguage.with(TestLanguage.design) { settingsNeed(panelWidth: width) }
        let en = TestLanguage.with("en") { settingsNeed(panelWidth: width) }
        print("[layout-gap] 设置面板内容高度：zh-Hans=\(zh)pt，en=\(en)pt，容器=\(container)pt")

        // 中文下必须放得下 —— 这是设计稿的硬契约，由 SettingsLayoutTests 详查。
        #expect(zh <= container, "中文下不该溢出（\(zh) > \(container)）—— 这属于 SettingsLayoutTests 的管辖")

        // 「英文确实更长」是下面那条「英文放不下」的**前提**。
        // 两者相等只有两种可能：① `TestLanguage` 的钉失效（`L10n.forcedLocale` 没传到渲染）；
        // ② 英文文案缺失、`tr` 回退到中文源语言。**两种都不是「缺陷被修好」**。
        // 没有这一条时，钉失效会以「英文放得下了」的面貌出现，把人引向
        // 「删掉本文件」这个**相反**的动作 —— 一条会骗人的诊断比没有诊断更糟。
        #expect(
            en > zh,
            """
            英文下（\(en)pt）没有比中文下（\(zh)pt）高 —— 这不是缺陷被修好了，
            而是「钉语言」失效或英文文案缺失导致回退到中文。
            请检查 L10n.forcedLocale 是否还能传到 SwiftUI 渲染。
            """
        )

        // 英文下**确实放不下**：钉住这个已知缺陷。
        #expect(
            en > container,
            """
            英文下设置面板已经放得下了（需要 \(en)pt，容器 \(container)pt）。
            这说明设计稿已给出英文方案 —— 请删掉本文件，并让 SettingsLayoutTests 的
            `<=` 断言直接覆盖英文。
            """
        )
    }

    @Test func 英文下引导面板更高_已知缺陷() {
        let width = DesignTokens.Size.onboardingPanelWidth
        // 设计稿总高 503.3（中文实测）。这里只比较中英差异，不重复断言绝对值。
        let zh = TestLanguage.with(TestLanguage.design) {
            renderedSize(
                OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}), width: width
            ).height
        }
        let en = TestLanguage.with("en") {
            renderedSize(
                OnboardingView(accent: .default, onOpenSettings: {}, onLater: {}), width: width
            ).height
        }
        print("[layout-gap] 引导面板高度：zh-Hans=\(zh)pt，en=\(en)pt")

        #expect(en > zh, "英文文案更长，面板只会更高；若不然说明英文文案被改短了，请复核设计稿")
        #expect(
            abs(zh - 503.3) <= 4,
            "中文下应仍是设计稿的 503.3（实际 \(zh)）—— 这属于 OnboardingLayoutTests 的管辖"
        )
    }
}
