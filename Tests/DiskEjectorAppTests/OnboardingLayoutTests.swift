import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 「完全磁盘访问」引导面板（设计稿 `04-onboarding.html` 第一块）的**排版契约**测试。
///
/// **为什么需要**：这块面板此前根本不存在（用的是系统 `NSAlert`），
/// 落地时每一处的尺寸都来自设计稿实测 —— 图标容器 52、步骤圆点 22、连接线 1.5×16、
/// 提示块 340×54、按钮 30 高、面板总高 503.3。这些数字一旦被后续改动碰歪，
/// 人眼是看不出来的：面板宽 380 是死的，里面每一块矮 2pt 只表现为「底部留白多一点」。
///
/// **为什么逐个块量而不是只量总高**：两处偏差可以互相抵消。
/// 实测过「图标容器矮 4pt、提示块高 4pt」的巧合，总高完全正常。
/// 所以 `OnboardingView` 的四个块故意留成 internal，让测试能分别量。
@MainActor
struct OnboardingLayoutTests {

    private let panelWidth = DesignTokens.Size.onboardingPanelWidth

    private func makeView() -> OnboardingView {
        OnboardingView(accent: .default, onOpenSettings: {}, onLater: {})
    }

    /// 在给定宽度下渲染并返回**真实渲染尺寸**。
    ///
    /// ⚠️ 必须用 `sizeThatFits(in:)`：`NSHostingView.fittingSize` 返回的是
    /// **无宽度约束的理想尺寸**，宽度根本没生效（详见
    /// `SettingsLayoutTests.renderedSize` 的对照实验）。
    private func renderedSize(_ view: some View, width: CGFloat) -> CGSize {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: view)
        return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    // MARK: 整体

    @Test func 面板宽为设计稿的380且内容宽340() {
        let panel = makeView()
        #expect(panel.contentWidth == 340, "内容宽应为 380 − 20×2 = 340，实际 \(panel.contentWidth)")
        let size = renderedSize(panel, width: panelWidth)
        #expect(
            abs(size.width - 380) < 0.5,
            "面板宽应为设计稿的 380，实际 \(size.width) —— 宽度飘了说明文字就会重新折行")
    }

    /// 面板总高。
    ///
    /// **容差 ±4 而不是「等于」，这 2.5pt 的缺口是已知且解释清楚的**：
    /// 设计稿总高 503.3，实现 500.9。差在两处**带小标的注释行**：
    /// - 第 1 步的注释整条是小标 → 该行取小标自身高 16（设计稿 17.5）；
    /// - 第 2 步的注释是「文字 + 小标 + 文字」→ 取两者较高 16.5（设计稿 17.5）。
    ///
    /// 根因是 **Blink 会把行内元素的垂直内边距算进行盒高度**
    /// （`.path { padding: 1px 5px }` → 该行 17.5），而 SwiftUI 里小标是独立视图，
    /// 行盒只取「行内各视图较高者」。要把这 1pt/行补回来，得给小标加 0.75pt 的
    /// 上下外边距 —— 代价是小标的圆角边落在半像素上、边缘发虚。
    /// **用一个看得见的模糊去换 1pt 的高度是不划算的**，所以这里如实容差。
    ///
    /// 容差仍然有约束力：任何一处行高令牌（`LineHeight` / `designLineHeight`）
    /// 或段间距被改动，位移都 ≥2.5pt，一定会越界。
    @Test func 面板总高与设计稿相差不超过4() {
        let height = renderedSize(makeView(), width: panelWidth).height
        #expect(
            abs(height - 503.3) <= 4,
            "面板总高应约为设计稿的 503.3，实际 \(height) —— 偏差超过 4pt 说明某一段的行高或间距被改了"
        )
    }

    // MARK: 逐块

    @Test func 顶部图标容器为设计稿的52() {
        // 图标容器 52 + 与标题之间 12 的外边距。
        let size = renderedSize(makeView().iconContainer, width: panelWidth)
        #expect(
            abs(size.width - 52) < 0.5 && abs(size.height - 64) < 0.5,
            "图标容器应为 52×52 + 下方 12 间距（合计 52×64），实际 \(size.width)×\(size.height)"
        )
    }

    @Test func 三步合计高与设计稿相差不超过3() {
        let size = renderedSize(makeView().steps, width: 340)
        #expect(
            abs(size.height - 135.5) <= 3,
            "三步合计高应约为设计稿的 135.5，实际 \(size.height) —— 步骤正文/注释的行高是 18 / 16.5"
        )
    }

    @Test func 信息提示块为设计稿的340乘54() {
        let size = renderedSize(makeView().callout, width: 340)
        #expect(
            abs(size.width - 340) < 0.5 && abs(size.height - 54) <= 2,
            "信息提示块应为 340×54（设计稿实测），实际 \(size.width)×\(size.height)"
        )
    }

    @Test func 按钮组高为设计稿的30() {
        let size = renderedSize(makeView().buttons, width: 340)
        #expect(
            abs(size.height - 30) < 0.5,
            "按钮组高应为设计稿的 30（`.btn` 默认尺寸），实际 \(size.height)"
        )
    }

    /// 两个按钮的**宽度**是设计稿量出来的硬数字：50 / 102。
    ///
    /// 宽度直接由「文字宽度 + 左右内边距 12」决定 —— 改内边距或改字号都会让它变，
    /// 而按钮组是右对齐的，变宽只会往左长，肉眼很难发现「内边距不是 12」。
    @Test func 两个按钮的宽度与设计稿一致() {
        let later = renderedSize(
            ActionButton(
                title: L10n.tr(.notNow), variant: .outline, size: .medium, accent: .default, action: {}),
            width: 340)
        let open = renderedSize(
            ActionButton(
                title: L10n.tr(.openSystemSettings), variant: .primary, size: .medium, accent: .default,
                action: {}),
            width: 340)
        #expect(
            abs(later.width - 50) <= 2,
            "「稍后」应约为设计稿的 50pt 宽（2 字 × 13 + 左右各 12），实际 \(later.width)")
        #expect(
            abs(open.width - 102) <= 2,
            "「打开系统设置」应约为设计稿的 102pt 宽（6 字 × 13 + 左右各 12），实际 \(open.width)")
        #expect(later.height == 30 && open.height == 30, "两个按钮都应是 30pt 高")
    }

    /// 第 1 步的路径小标是面板里最宽的一个固定元素（设计稿实测 226）。
    ///
    /// 它的宽度决定了**它会不会折行** —— 340 的内容宽减去编号列 22 与间距 12 只剩 306，
    /// 小标 226 时安全，但如果字体/内边距变了让它涨到 306 以上，第 1 步就会变成两行。
    @Test func 路径小标宽度与设计稿一致() {
        let size = renderedSize(
            PathPill(text: L10n.tr(.fdaOnboardingPathSettings)), width: 400)
        #expect(
            abs(size.width - 226) <= 6,
            "路径小标应约为设计稿的 226pt 宽（等宽 11 + 左右各 5 内边距），实际 \(size.width)"
        )
        // 小标是 11pt 等宽 + 上下各 1 内边距（设计稿 `.path` 实测 15）。
        #expect(abs(size.height - 16) <= 1.5, "路径小标高应约为 16，实际 \(size.height)")
    }

    // MARK: 步骤数据

    @Test func 面板画三步且序号连续递增() {
        #expect(OnboardingStep.all.count == 3, "设计稿是三步，实际 \(OnboardingStep.all.count) 步")
        #expect(
            OnboardingStep.all.map(\.number) == [1, 2, 3],
            "圆点里的序号必须连续递增，实际 \(OnboardingStep.all.map(\.number))")
    }

    /// 三步的注释形态各不相同，这里逐个钉住 —— 形态错了（比如第 1 步被写成纯文字）
    /// 界面上只是「少了块底色」，很容易被当成有意为之。
    @Test func 三步的注释形态与设计稿一致() {
        let steps = OnboardingStep.all
        #expect(
            steps[0].note == .pill(.fdaOnboardingPathSettings),
            "第 1 步的注释整条就是设置路径小标")
        #expect(
            steps[1].note == .template(.fdaOnboardingStep2Note, pill: .fdaOnboardingPathAdd),
            "第 2 步的注释是「文字 + 小标 + 文字」")
        #expect(steps[2].note == .text(.fdaOnboardingStep3Note), "第 3 步的注释是纯文字")
        #expect(steps[2].note.pillKey == nil, "只有第 3 步没有小标")
    }

    /// 注释模板按 `%@` 切分。
    ///
    /// **为什么不用 `String(format:)`**：`%@` 在这里不是「格式化参数」而是
    /// 「小标的插入位置」—— 小标是个带底色的独立视图，格式化字符串给不了。
    /// 切分逻辑要是坏了（比如空段没丢掉），行首会多出半个间距，小标不再贴着边。
    @Test func 注释模板按占位符切分且丢掉空段() {
        let pieces = OnboardingView.notePieces(
            of: L10n.tr(.fdaOnboardingStep2Note), pill: L10n.tr(.fdaOnboardingPathAdd))

        #expect(pieces.count == 3, "「文字 + 小标 + 文字」应切成 3 段，实际 \(pieces.count)")
        #expect(pieces[1].isPill, "中间那段是小标")
        #expect(!pieces[0].isPill && !pieces[2].isPill, "首尾两段是文字")
        #expect(
            pieces.map(\.text) == ["若不在列表中，点左下角", L10n.tr(.fdaOnboardingPathAdd), "从「应用程序」添加"],
            "切分结果不对：\(pieces.map(\.text)) —— 段首尾的空白必须被吃掉，否则行首会多出半个间距")

        // 模板以占位符开头/结尾时，空段不能进布局。
        let leading = OnboardingView.notePieces(of: "%@ 尾巴", pill: "P")
        #expect(
            leading.map(\.text) == ["P", "尾巴"] && leading.count == 2,
            "以占位符开头的模板应切成「小标 + 文字」两段，实际 \(leading.map(\.text))")
        let only = OnboardingView.notePieces(of: "%@", pill: "P")
        #expect(only.count == 1 && only[0].isPill, "整条只有占位符时应只剩一个小标")
    }

    // MARK: 文案

    /// 说明段里的 `**粗体**` 与换行是**设计稿的内容**，不是格式巧合：
    /// 加粗的那半句是「为什么要给权限」，`<br>` 之后的半句是「不给会怎样」。
    @Test func 说明段带加粗标记与换行() {
        let body = L10n.tr(.fdaOnboardingBody)
        #expect(body.contains("**"), "说明段必须保留 Markdown 加粗标记，否则整段会读成一句平铺的说明")
        #expect(body.contains("\n"), "设计稿在两句之间有一个硬换行（`<br>`），丢了会合成一行")
    }

    /// 第 1 步的正文与第 2 步的正文里各有一处需要保留原样的专名。
    @Test func 步骤正文里的专名原样保留() {
        #expect(
            L10n.tr(.fdaOnboardingStep2Text).contains("DiskEjector"),
            "第 2 步要让用户在系统设置的列表里找到这个确切的名字")
        #expect(
            L10n.tr(.fdaOnboardingStep3Text).contains("DiskEjector"),
            "第 3 步同样要指名道姓，否则「切回哪个应用」是含糊的")
    }
}
