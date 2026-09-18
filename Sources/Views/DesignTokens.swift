import AppKit
import SwiftUI

/// 全局设计令牌（与设计稿统一规范的视觉常量集中声明处）。
///
/// **单一事实来源**：`DiskEjector-UI-Design/v2/`（`index.html` 为总览入口）。
/// 本文件是设计稿里 `assets/ds.css` 的 Swift 侧镜像 —— 两边数值必须一致，
/// 改设计稿时同步改这里，不要各写一份。
///
/// **为什么不再用「系统色 + 半透明」拼视觉**：旧实现用 `Color.primary.opacity(0.06)`
/// 这类派生色，导致同一语义（如「被占用」）在不同视图里透明度各不相同，
/// 且小号文字的对比度没人核算过。现在所有语义色都以**具体 hex + 明暗两套**声明，
/// 对比度在设计稿阶段逐项核算过（WCAG AA），实现侧只取值、不再自创。
///
/// **实现策略**：
/// - 语义色用 `NSColor(name:dynamicProvider:)` 做明暗自适应，无需把 `colorScheme`
///   一路透传到每个子视图，也不会漏掉某处忘记适配深色。
/// - 毛玻璃按 macOS 版本优雅降级：15+ 用 `.ultraThinMaterial`（接近 Liquid Glass），
///   14 用 `.regularMaterial` 兜底。
enum DesignTokens {

    // MARK: 圆角

    /// 设计稿 §2.4。命名与 `ds.css` 的 `--r-*` 一一对应。
    enum Radius {
        /// 4 —— 芯片内的小标、行内小按钮。
        static let xs: CGFloat = 4
        /// 6 —— 按钮、分段选项。
        static let sm: CGFloat = 6
        /// 10 —— 磁盘行、证据区、设置卡片、图标容器。
        static let md: CGFloat = 10
        /// 14 —— 菜单栏面板、弹窗、引导面板。
        static let lg: CGFloat = 14
        /// 18 —— 空状态大图标容器。
        static let xl: CGFloat = 18
        /// 12 —— 主窗口外框。
        static let window: CGFloat = 12
        /// 999 —— 容量条、芯片、开关、色板（用 `Capsule()` 表达，此处仅作语义索引）。
        static let full: CGFloat = 999
        /// 设置面板外框。
        ///
        /// **曾经是 16，理由是「设计稿比菜单栏面板更圆」—— 这句是错的。**
        /// 设计稿里设置面板就是 `.win`，圆角取 `--r-window` = **12**，与主窗口同一个值
        /// （`05-settings.html` 的 DOM 实测 `borderRadius=12px`）。
        /// 16 让设置面板与主窗口并排时外框弧度对不上。现在两个都是 ``window``。
        static let settings: CGFloat = window

        /// **底色内缩后**该用的同心圆角 —— 由内缩量求出。
        ///
        /// **为什么不能直接沿用 ``sm``（6）**：hover 底色是**内缩**后贴在按钮盒子里的。
        /// 圆角不跟着缩的话，小一圈的底色在四角会比外框更「方」，
        /// 描边与底色之间的缝在**角上比边上宽**，看上去像没对齐。
        ///
        /// 写成函数而不是常量，是因为**内缩量因变体而异**：
        /// ``ActionButton`` 只在「底色悬浮才出现」的变体上内缩（``Size/hoverBackgroundInset``），
        /// 其余变体不缩（0）—— 两者的圆角必须各自算，不能共用一个写死的数。
        static func concentric(inset: CGFloat) -> CGFloat { max(0, sm - inset) }
    }

    // MARK: 间距（4pt 基准）

    /// 设计稿 §2.3：`4 / 8 / 12 / 16 / 20 / 24 / 32`。
    enum Spacing {
        /// 4 —— 图标与文字、芯片间距。
        static let xs: CGFloat = 4
        /// 8 —— 按钮间距、行间距。
        static let sm: CGFloat = 8
        /// 12 —— 行内边距、图标与文本列间距。
        static let md: CGFloat = 12
        /// 16 —— 列表左右内边距、卡片内边距。
        static let lg: CGFloat = 16
        /// 20 —— 窗口内边距、弹窗内边距。
        static let xl: CGFloat = 20
        /// 24 —— 引导面板内边距。
        static let xxl: CGFloat = 24
        /// 32 —— 空状态横向留白。
        static let xxxl: CGFloat = 32

        /// **标题栏右侧留白（12）** —— 见 ``DesignTokens/Size/titleBarInsetCenter``。
        ///
        /// 与 ``md`` 数值相同，但**语义不同**，不要用 ``md`` 代替：
        /// ``md`` 是「行内边距」这一档，改它会影响列表；
        /// 这一条只服务「设置按钮中心落在距右 26pt」，由
        /// `--preview-main-window-keys` 的水平对称断言守着。
        static let titleBarTrailing: CGFloat = 12
    }

    // MARK: 字号

    /// 设计稿 §2.2。数值即 pt，字重在使用处给出。
    enum FontSize {
        /// 20 / 600 —— 弹窗、引导主标题。
        static let display: CGFloat = 20
        /// 17 / 600 —— 引导页标题。
        static let heading: CGFloat = 17
        /// 15 / 600 —— 磁盘名、窗口标题、弹窗标题。
        static let title: CGFloat = 15
        /// 13 / 600 —— 紧凑行磁盘名、设置项标签。
        static let bodyStrong: CGFloat = 13
        /// 13 / 400 —— 设置项、动作行、正文。
        static let body: CGFloat = 13
        /// 12 / 400 —— 容量、说明、弹窗正文。
        static let caption: CGFloat = 12
        /// 11 / 400 —— 状态、百分比、快捷键。
        static let footnote: CGFloat = 11
        /// 11 / 600 —— 分组标题（配 `tracking`）。
        static let groupTitle: CGFloat = 11

        // 兼容旧命名（语义等价，保留以免调用点大改）。
        /// 主窗口标题栏标题 —— 15 / 600。
        static let titleBar: CGFloat = title
        /// 磁盘行磁盘名 —— 15 / 600。
        static let diskCardName: CGFloat = title
        /// 容量标签 —— 12。
        static let capacity: CGFloat = caption
        /// 进程芯片文字 —— 12。
        static let processTag: CGFloat = caption
        /// 主按钮文字 —— 12 / 500（设计稿按钮统一 sm 尺寸）。
        static let primaryButton: CGFloat = caption
        /// 菜单栏磁盘名 —— 13 / 600。
        static let menuDiskName: CGFloat = bodyStrong
        /// 菜单栏磁盘 meta —— 11。
        static let menuDiskMeta: CGFloat = footnote
        /// 弹出面板标题 —— 13 / 600。
        static let menuTitle: CGFloat = bodyStrong
        /// 设置面板分组标题 —— 11 / 600。
        static let settingsTitle: CGFloat = groupTitle
    }

    // MARK: 行高

    /// 设计稿的行高倍数（`ds.css` 里的 `line-height`）。
    ///
    /// **为什么行高要单独建一组令牌、而不是让 SwiftUI 用默认值**：
    /// CSS 的 `line-height` 是**行盒高度**，对每一行（含第一行）都生效；
    /// SwiftUI 的 `Text` 用的是字体的**自然行高**，`lineSpacing` 只补**行与行之间**。
    /// 两者对 12pt 文字相差 3pt/行 —— 单行看不出来，一个三行的提示块就差 9pt，
    /// 弹窗整体高度会偏出十几 pt（实测 A 变体多 17pt、B 变体少 11pt）。
    /// 所以按设计稿的倍数显式声明，配合 ``SwiftUI/View/designLineHeight(_:fontSize:)`` 使用。
    enum LineHeight {
        /// 1.3 —— 弹窗标题（15 → 19.5）。
        static let tight: CGFloat = 1.3
        /// 1.45 —— 页面正文基准（`ds.css` 的 `body`，分组头 / 进程行 / 小标都用它）。
        static let base: CGFloat = 1.45
        /// 1.5 —— 弹窗正文与提示块。
        static let relaxed: CGFloat = 1.5
        /// 1.55 —— 「可能的原因」清单（设计稿里是行内 `line-height:1.55`）。
        static let loose: CGFloat = 1.55
        /// 1.6 —— 引导面板的说明段（设计稿 `.onboard__desc { line-height: 1.6 }`）。
        ///
        /// 这是全设计稿最大的一档行高，只用在「居中、两行以上、需要慢慢读」的段落上。
        static let spacious: CGFloat = 1.6
    }

    /// 系统字体的自然单行高度（**实测值**，不是算出来的）。
    ///
    /// **为什么要写死一张表**：`lineSpacing` 补的是行间距，要算「该补多少」就必须先知道
    /// 系统给这个字号的自然行高。而它并不是字号的简单倍数 —— 实测 11→14、12→15、
    /// 13→16、15→19，比值在 1.23~1.27 之间来回跳。乘一个系数会在某些字号上差 1pt。
    /// `AlertLayoutTests.自然行高表与实测一致` 会真的量一遍来守住这张表。
    static func naturalLineHeight(_ fontSize: CGFloat) -> CGFloat {
        switch fontSize {
        case 11: return 14
        case 12: return 15
        case 13: return 16
        case 15: return 19
        default: return (fontSize * 1.25).rounded()
        }
    }

    // MARK: 尺寸

    /// 设计稿里量出来的硬性规格。**改任何数值前先看注释里的依据**。
    enum Size {
        /// 主窗口尺寸（设计稿硬性规格）。
        static let mainWindow = CGSize(width: 800, height: 520)

        /// 设置面板尺寸。
        ///
        /// **高度是量出来的，不是拍脑袋定的**：内容自然高度随文案变化，
        /// 历史值 520pt 装不下（实测内容 602pt），于是面板底部的「关于 / 更新」被
        /// 折叠线挡在滚动区外 —— 用户看到的就是「设置界面排版不好看」。
        ///
        /// 演进（每一步都是**加内容**之后重新量的）：
        /// `440×566`（v2 重排，四组：外观 / 通用 / 诊断 / 关于）
        /// → `440×724`（加「更新」组：组标题 22 + 两行 59×2 + 组间距 20）
        /// → `480×752`（**改宽**：英文在 440 宽下内容要 612.25pt，容器只有 566 —— 二分测得临界 477，
        ///    取 480 后中英都装得下，高度**不用动**）
        /// → `480×800`（「通用」组加「语言」行；高度按**英文** 782.6 + 余量 17.4 定）。
        ///
        /// ⚠️ **宽 480 与高 800 是两件事**，别把它们记成一次改动：
        /// 宽度解决的是「英文放不下」，高度解决的是「多了一行」。
        ///
        /// ⚠️ **为什么不是设计稿写的 826**（2026-09-18 实测，别改回去）：
        ///
        /// | | 中文 | 英文 |
        /// |---|---|---|
        /// | 设计稿（Chrome/CSS 渲染） | 766.44 | 814.25 |
        /// | 实现（SwiftUI 渲染） | 766.60 | **782.60** |
        ///
        /// 中文两边只差 **0.16pt** —— 说明结构是忠实的；英文差 31.65pt（≈2 行折行），
        /// 来源是 CSS 与 CoreText 对英文断行的差异（本仓库已记为「已知不是 bug」）。
        /// 设计稿的 826 = 它自己的英文 814.25 + 余量；而实现只需要 782.6，
        /// 沿用 826 会在**中文**下留 59.4pt 空白带（≈1.4 行，肉眼可见）——
        /// `SettingsLayoutTests/面板高度不留大片空白` 会直接把它判红。
        ///
        /// 改任何一段文案/内边距后，`SettingsLayoutTests` 会要求同步更新这两个数。
        static let settingsPanel = CGSize(width: 480, height: 800)

        /// 菜单栏弹出面板宽度。
        static let menuPopoverWidth: CGFloat = 360
        /// 推出确认对话框最大宽度（设计稿 400，上限 420）。
        static let confirmDialogMaxWidth: CGFloat = 420

        /// 推出弹窗宽度（设计稿 `.alert { width: 400px }`，实测 400×330 / 400×314）。
        ///
        /// **为什么不是「由内容决定」**：设计稿把 400 定为硬规格（`03-eject-flow.html`
        /// 的 Handoff：「弹窗宽 400（最大 420）」），因为换行位置会影响「可能的原因」
        /// 那类长句的断行，宽度飘了断行就飘了。
        static let alertWidth: CGFloat = 400
        /// 弹窗图标容器 38 × 38，圆角 10，图标 20（设计稿 `.alert__icon`）。
        static let alertIconContainer: CGFloat = 38
        static let alertIconSize: CGFloat = 20
        /// 进程行高 29（设计稿 `.alert__item { padding: 5px 6px }` + 内容 19）。
        static let alertProcessRowHeight: CGFloat = 29
        /// 进程行内应用图标 18 × 18 圆角 4（设计稿 `.alert__item .appicon`）。
        static let alertProcessIcon: CGFloat = 18
        /// 警示块内边距 9 / 11（设计稿 `.callout { padding: 9px 11px }`）。
        static let calloutPaddingV: CGFloat = 9
        static let calloutPaddingH: CGFloat = 11
        /// 警示块图标 14（设计稿 `.callout svg { width: 14px }`）。
        static let calloutIconSize: CGFloat = 14
        /// 弹窗操作区高度（设计稿实测 54 = 按钮 30 + 上下内边距 12）。
        static let alertFootHeight: CGFloat = 54
        // MARK: 授权引导面板（设计稿 `04-onboarding.html`）

        /// 面板宽度（设计稿 `.onboard { width: 380px }`）。
        ///
        /// **为什么是硬规格而不是「由内容决定」**：说明文字是居中的两段，
        /// 宽度飘了断行就飘；第 1 步的路径小标实测 226pt，正好卡在 340pt 的内容宽里，
        /// 再窄一点它就会折行，三步的高度跟着一起变。
        static let onboardingPanelWidth: CGFloat = 380
        /// 顶部图标容器 52 × 52，圆角 14，图标 26（设计稿 `.onboard__icon`）。
        static let onboardingIconContainer: CGFloat = 52
        static let onboardingIconSize: CGFloat = 26
        /// 图标容器与标题之间 12（设计稿 `.onboard__icon { margin: 0 auto 12px }`）。
        static let onboardingIconBottomGap: CGFloat = 12
        /// 步骤序号圆点 22 × 22（设计稿 `.step__dot`，`border-radius: 999px`）。
        static let onboardingStepDot: CGFloat = 22
        /// 步骤编号列宽（设计稿 `.step__rail` 实测 22）。
        static let onboardingStepRailWidth: CGFloat = 22
        /// 连接线：宽 1.5、最小高 16、上下各 2 外边距（设计稿 `.step__line`）。
        static let onboardingStepLineWidth: CGFloat = 1.5
        static let onboardingStepLineHeight: CGFloat = 16
        static let onboardingStepLineMargin: CGFloat = 2
        /// 编号列与正文列的水平间距（设计稿 `.step { gap: 12px }`）。
        static let onboardingStepGap: CGFloat = 12
        /// 步骤正文底部内边距（设计稿 `.step__text { padding-bottom: 12px }`，
        /// 最后一步在设计稿里被行内样式改成 0）。
        static let onboardingStepTextPaddingBottom: CGFloat = 12
        /// 正文与其下方注释之间 2（设计稿 `.step__text small { margin-top: 2px }`）。
        static let onboardingNoteTopGap: CGFloat = 2
        /// 行内「路径」小标（设计稿 `.path`）：等宽 11、内边距 1/5、圆角 4。
        static let onboardingPathRadius: CGFloat = 4
        static let onboardingPathPaddingH: CGFloat = 5
        static let onboardingPathPaddingV: CGFloat = 1

        /// 标题栏**视觉总高**（设计稿 `.titlebar { height: 52px }`）。
        ///
        /// ⚠️ 它**不是**内容带的高度 —— 内容带是 ``titleBarBandHeight``。
        static let titleBarHeight: CGFloat = 52

        /// 标题栏**内容带**高度 —— 标题文字与图标按钮都在这条带子里垂直居中。
        ///
        /// **它就是设计稿的 52，不带留白**：设计稿 `.titlebar` 是
        /// `height: 52px; align-items: center`，DOM 探针实测三样东西的中心**全在 26pt** ——
        /// `.traffic`（红绿灯）`y 20 / 高 12`、`.titlebar__title` `y 15 / 高 22`、
        /// `.iconbtn` `y 12 / 高 28`。设置面板 `.shead` 同样是 26pt。
        ///
        /// ## 这里曾经是 32，而且那个数**是错的**
        ///
        /// 32 的来历是「迁就系统红绿灯」：macOS 把三个交通灯画在**距窗口顶 9pt** 处、
        /// 每个高 14pt（真机实测并集 `y 9…23`），垂直中心**距顶 16pt** —— 取 32 的带子
        /// 让内容居中后正好与灯同高。用户 2026-09-17 反馈「红绿灯、标题、按钮与窗口顶部
        /// 的距离与设计稿不一致」，量出来正是这 **10pt**。
        ///
        /// **迁就系统是不必要的**：`NSWindow.standardWindowButton` 的 frame 可以改，
        /// 实测（2026-09-17）改完在 run loop、key 切换、移动窗口、`setContentSize`
        /// 之后都不会被 AppKit 拨回去。所以正确做法是**把灯挪到设计稿要的 26pt**
        /// （见 ``trafficLightNudgeY``），而不是把标题拉到系统给的 16pt。
        static let titleBarBandHeight: CGFloat = 52

        /// 内容带下方的留白，使标题栏**视觉总高**保持设计稿的 52pt（52 + 0）。
        ///
        /// 现在是 0 —— 内容带已经吃满整个 52pt。留着这个常量是为了
        /// 「内容带 + 留白 == 标题栏总高」这条自洽关系仍有一个显式的位置，
        /// 也免得将来有人想加回留白时直接把 52 改成 32（那会重新引入这 10pt 偏差）。
        static let titleBarBandBottomPadding: CGFloat = 0

        /// 系统**默认**把交通灯画在距窗口顶多高处（垂直中心）。
        ///
        /// **实测值，不要凭印象改**：macOS 26.7 上三个按钮的并集是 `y 9…23`（窗口坐标，
        /// 原点在左下 → 距顶 9pt），高 14pt，中心 **16pt**。
        /// 系统用的是「标准 28pt 标题栏」那一套位置，跟设计稿的 52pt 无关。
        static let systemTrafficLightCenterFromTop: CGFloat = 16

        /// ⚠️ **不要把「该挪多少」写死成常量** —— 那是本仓库踩过的坑：
        /// 早期写死 `trafficLightNudge = 10`，结果 `NSHostingView` 上屏时的重排
        /// 会把灯的 **x 拨回 4pt**（实测请求 +10、实得 +6），写死的补偿量就对不上了。
        /// 正确做法是**运行时量出当前位置再补到位**（见
        /// ``AppDelegate/alignTrafficLights(in:)``），这样无论系统把灯放在哪、
        /// 中途被拨回多少，都能收敛到 ``titleBarInsetCenter``。
        ///
        /// 这两个常量因此**只作文档与自检的诊断参考**，不参与位置计算。

        /// 标题栏图标按钮（设计稿 28 × 28）。
        static let titleBarIconButton: CGFloat = 28

        /// **标题栏两个「边缘部件」的光学中心到窗口边的距离（26pt）**。
        ///
        /// DOM 探针实测设计稿 `01-main-window.html`（2026-09-17）：
        ///
        /// | 部件 | 盒 / 墨迹 | 边缘距窗口边 | **中心距窗口边** |
        /// |---|---|---|---|
        /// | 红灯 | 12pt 圆点 | 左 20.5 | **左 26.5** |
        /// | 设置按钮 | 28pt 盒 / 14pt 图标 | 右 12.5 / 右 19.5 | **右 26.5** |
        ///
        /// 注意中间的陷阱：**「盒边缘」差 8pt，但「中心」是齐的**。
        /// 圆点直径 12、按钮盒 28，两者贴边留白天然不同 ——
        /// 拿边缘去比会得出「设计稿自己就不对称」的错误结论，然后改错实现。
        /// **判据只能用中心。**（真机窗口没有 0.5px 边框，所以取 26 而非 26.5。）
        static let titleBarInsetCenter: CGFloat = 26

        /// 系统交通灯的**水平**中心到窗口左边的距离。
        ///
        /// 与 ``systemTrafficLightCenterFromTop`` 同理：这是**实测值**，不是设计稿给的数。
        /// 实测（2026-09-17，macOS 26.7）：close 按钮 `frame=(9, …, 14, 14)`
        /// → 中心 = 9 + 7 = **16pt**。
        ///
        /// ⚠️ **这个值最初被我写成 20**（交通灯「标准间距」的印象值），
        /// 是回读校验时才发现的 —— 一边写「别凭印象写系统实测值」一边自己写错，
        /// 正是这条判据存在的理由。**系统值只能从真机量，不能从文档或记忆里取。**
        ///
        /// 它现在**不参与位置计算**（对齐是幂等的、量出当前值再补差额），
        /// 只作文档与自检的诊断参考。
        static let systemTrafficLightCenterFromLeft: CGFloat = 16

        /// **hover 底色相对按钮盒子向内缩多少点。**
        ///
        /// ## 这是**有意偏离设计稿**，别再照着设计稿「改回去」
        ///
        /// `ds.css` 写的是**整盒**变底色：`.iconbtn:hover { background: var(--bg-subtle) }`
        /// （`.iconbtn` 是 28 × 28）、`.btn--outline:hover { background: var(--bg-subtle) }`。
        /// 实现最初照抄了这个写法，用户 2026-09-16 明确要求
        /// **「设置窗口的完成按钮以及主窗口的刷新、设置按钮的 hover 效果背景小一点」**，
        /// 于是改成「底色比盒子小一圈」。**用户偏好优先于设计稿字面**，
        /// 依据记在 `DESIGN-SPEC.md` §8.19。
        ///
        /// ## 收小前后的实测（真机截图，2x）
        ///
        /// | 按钮 | 盒子 | 改前底色 | 改后底色 |
        /// |---|---|---|---|
        /// | 标题栏刷新 / 设置 | 28 × 28 | 28 × 28（整盒） | **22 × 22** |
        /// | 设置面板「完成」 | 44 × 25 | 44 × 25（整盒） | **38 × 19** |
        ///
        /// ## 只缩「底色」那一层
        ///
        /// ``ActionButton`` 的 `.background`（填色）与 `.overlay`（1px 描边）是**两层**。
        /// 设置面板的「完成」是 `.outline` 变体，**描边必须留在盒子边缘**，
        /// 只把填色内缩 —— 于是底色与描边之间留出一圈缝，这才是「底色小一点」的观感。
        /// 把描边一起缩掉，按钮就没有外框了。
        ///
        /// ## 调大调小
        ///
        /// 改这一个数即可（圆角 ``Radius/hoverBackground`` 会自动跟上）。
        /// 0 = 回到设计稿的整盒写法。真机对照图：
        /// `.build/probe/make_hover_candidates.py` 生成 `hover-size-candidates.png`。
        static let hoverBackgroundInset: CGFloat = 3

        /// 磁盘行图标容器（设计稿 40 × 40，圆角 10）。
        static let diskIconContainer: CGFloat = 40
        /// 菜单栏磁盘行图标容器（设计稿 32 × 32）。
        static let menuIconContainer: CGFloat = 32
        /// 菜单栏磁盘行图标容器**自己的**圆角与图标尺寸。
        ///
        /// **不能沿用 `Radius.md`（10）**：设计稿 `.mrow__icon` 写的是 `--r-sm` = 6，
        /// 而主窗口的 `.diskicon` 才是 `--r-md` = 10。两者是两条独立规则，
        /// 共用一档会让菜单面板里的图标容器比设计稿圆 4pt —— 32pt 的方块上
        /// 圆角从 6 变成 10，四角明显「胖」了一圈。
        ///
        /// 图标尺寸同理：`.mrow__icon svg { width: 17px }`（主窗口是 22）。
        static let menuIconRadius: CGFloat = 6
        static let menuIconSize: CGFloat = 17
        /// 菜单栏行内推出按钮的图标（设计稿 `.mbtn svg { width: 14px }`）。
        static let menuEjectIconSize: CGFloat = 14
        /// 菜单面板头部应用图标（设计稿 `.pop__appicon svg { width: 13px }`）。
        static let popoverAppIconSize: CGFloat = 13
        /// 面板外框描边宽度（设计稿 `.win { border: 0.5px solid var(--border-strong) }`）。
        ///
        /// **必须画**：设计稿的 `.win` 有一条 0.5px 描边，它是毛玻璃与桌面之间唯一的边界。
        /// 没有它时，浅色壁纸下窗口边缘完全溶进背景里，看起来像没画完。
        static let glassBorderWidth: CGFloat = 0.5
        /// 紧凑行图标容器（设计稿 30 × 30，圆角 8）。
        static let compactIconContainer: CGFloat = 30

        /// 菜单面板空状态的图标容器（设计稿 `.empty__art` 在面板里被覆盖为 56 × 56 圆角 14）。
        ///
        /// **与主窗口空状态的 76 × 76 不是同一个东西**：面板只有 360pt 宽，
        /// 76 的方块在空状态里显得比内容还重。设计稿为此单独覆盖了一档尺寸。
        static let menuEmptyArtSize: CGFloat = 56
        /// 菜单面板空状态图标（设计稿 `.empty__art svg` 36）。
        static let menuEmptyArtIcon: CGFloat = 36
        /// 菜单面板头部图标按钮（设计稿 `.iconbtn` 28 × 28）。
        static let popoverIconButton: CGFloat = 28

        /// 磁盘行（完整版）内边距（设计稿 `padding: var(--s-3)`）。
        static let rowPadding: CGFloat = 12
        /// 磁盘行内容列之间的纵向间距（设计稿 `.row__main { gap: 7px }`）。
        static let rowColumnGap: CGFloat = 7
        /// 名称行与 meta 行之间的间距（设计稿 `.row__id { gap: 3px }`）。
        static let rowIdGap: CGFloat = 3

        /// 完整行：被占用（含证据区）高度 —— 设计稿实测 169。
        static let diskRowBusyHeight: CGFloat = 169
        /// 完整行：可安全推出高度 —— 设计稿实测 127。
        static let diskRowSafeHeight: CGFloat = 127
        /// 完整行：占用情况未知高度 —— 设计稿实测 133。
        static let diskRowUnknownHeight: CGFloat = 133
        /// 紧凑行高度 —— 设计稿实测 46。
        static let compactRowHeight: CGFloat = 46
        /// 菜单面板磁盘行高度 —— 设计稿实测 69（32 图标 / 53 文本块 + 上下各 8 内边距）。
        static let menuRowHeight: CGFloat = 69
        /// 菜单面板动作行高度 —— 设计稿实测 **32.0000**（`getBoundingClientRect` 四位小数）。
        ///
        /// 算术是 `7（上内边距）+ 18（行盒）+ 7（下内边距）`，但那个 **18 不是设计的决定**：
        /// `.actionrow` 是 `<button>`，浏览器 UA 样式表给它 `line-height: normal`，
        /// **覆盖**了从 `.win { line-height: 1.45 }` 继承下来的 18.85 ——
        /// 同一份设计稿里 `.mrow__name`（`<div>`，18.85）与它并不一致。
        /// 实测：`computed.lineHeight = normal`、文本行盒 16、图标 15、键位 13，
        /// 而整行高度是**硬邦邦的 32**。
        ///
        /// 所以实现里**不复刻那个 18**（复刻浏览器怪癖没有意义），
        /// 直接把行高钉成 32（见 ``MenuActionRow``）。曾经按 1.45 算成 32.85，
        /// 四行累计多 3.4pt —— 面板整体因此比设计稿高。
        static let menuActionRowHeight: CGFloat = 32
        /// 启用紧凑行的磁盘块数阈值（设计稿 §3.3：≥ 4 块）。
        static let compactRowThreshold = 4

        /// 证据区内边距：上 8 / 左右 12 / 下 12（设计稿 `.evid`）。
        static let evidencePaddingTop: CGFloat = 8
        static let evidencePaddingH: CGFloat = 12
        static let evidencePaddingBottom: CGFloat = 12
        /// 证据区头部与芯片区之间的间距（设计稿 `.evid__chips { margin-top: 8px }`）。
        static let evidenceHeadGap: CGFloat = 8

        /// 被占用行左侧琥珀条 —— **三种行各有自己的规格**，不能共用一个常数。
        ///
        /// 设计稿里它们是三条独立的 `::before` 规则：
        /// - `.row--busy::before`（主窗口完整行）`width:3px; top/bottom:10px`
        /// - `.mrow--busy::before`（菜单面板行）`width:2.5px; top/bottom:7px`
        /// - `.crow--busy::before`（紧凑行）`width:3px; top/bottom:8px`
        ///
        /// 曾经三种都取 `busyBarWidth = 3`，菜单面板行因此宽了 0.5pt；
        /// 紧凑行更是漏了上下内缩，琥珀条顶到了行的上下边缘。
        /// 三处的圆角也**只圆右端**（`border-radius: 0 2px 2px 0`）——
        /// 左端贴着行的左边缘，圆角会在行的圆角外侧露出一小段弧，看起来像没对齐。
        static let rowBusyBarWidth: CGFloat = 3
        static let rowBusyBarInset: CGFloat = 10
        static let menuBusyBarWidth: CGFloat = 2.5
        static let menuBusyBarInset: CGFloat = 7
        static let compactBusyBarWidth: CGFloat = 3
        static let compactBusyBarInset: CGFloat = 8
        /// 琥珀条右端圆角（设计稿 `0 2px 2px 0`）。
        static let busyBarRadius: CGFloat = 2

        /// 紧凑行磁盘名的最大宽度（设计稿 `.crow__name { max-width: 190px }`）。
        ///
        /// **必须限宽**：紧凑行是单行横向排布，磁盘名过长会把 meta 与状态挤出去。
        /// 设计稿把名称截在 190pt，保证「容量 + 状态 + 按钮」三者的位置在多块盘之间**纵向对齐**。
        static let compactNameMaxWidth: CGFloat = 190

        /// 进程芯片高（设计稿 26）与芯片内图标（设计稿 20）。
        static let processChipHeight: CGFloat = 26
        static let processChipIcon: CGFloat = 20

        /// 容量条填充高（设计稿 5）。
        static let meterHeight: CGFloat = 5
        /// 百分比标签固定宽（设计稿 34）—— 固定宽才能让多行百分比纵向对齐。
        static let meterPercentWidth: CGFloat = 34

        /// 设置行里的**行内下载进度**（设计稿 `08-update.html` 的 `.progressline`）。
        ///
        /// **外层固定 16pt 高**，与说明行同高 —— 于是「后台下载中」那一行
        /// 不会被进度条撑高，整块面板在下载过程中不会跳一下。
        /// ⚠️ 这里的百分比**不是** `meterPercentWidth`：设计稿给 `.progressline` 里的
        /// `.meter__pct` 单独写了 `width: auto`（进度条占满剩余宽度），
        /// 与磁盘行那个固定 34 的口径不同。
        static let settingsProgressLineHeight: CGFloat = 16

        /// 按钮高度：sm 26（行内）/ md 30（弹窗）/ lg 34（主行动）。
        static let buttonSmallHeight: CGFloat = 26
        static let buttonMediumHeight: CGFloat = 30
        static let buttonLargeHeight: CGFloat = 34

        // 横幅**没有固定高度**：设计稿里未授权横幅 46 是被右侧 26pt 按钮撑出来的，
        // 授权成功横幅（无按钮）只有 37。曾经有一个 `bannerHeight = 46` 的
        // `minHeight` 兜在 `NoticeBanner` 上，让后者凭空高出 9pt —— 已删除。

        /// 空状态大图标容器（设计稿 76 × 76，圆角 18）。
        static let emptyArtSize: CGFloat = 76
        /// 设置面板「关于」行图标（设计稿 44 × 44）。
        static let aboutRowIcon: CGFloat = 44
        /// 设置面板「关于」行高度（设计稿实测 70）。
        static let aboutRowHeight: CGFloat = 70

        /// 开关：轨道 38 × 22，滑块 18，内缩 2（行程 16）。
        static let switchTrackWidth: CGFloat = 38
        static let switchTrackHeight: CGFloat = 22
        static let switchKnob: CGFloat = 18
        static let switchInset: CGFloat = 2

        /// 设置面板里的下拉（设计稿 `.popup`）：**28pt 高**、11pt chevron。
        ///
        /// **高度比开关（22）高、比按钮（28）相同** —— 与设计稿一致。
        /// 这个数同时决定「语言」那一行的高度：28 > 行内文字（13 + 11 + 2 = 26），
        /// 所以加了下拉之后该行仍落在 `lineMinHeight` 之内，**不会把行撑高**。
        static let popUpHeight: CGFloat = 28

        /// 强调色色板（设计稿 22 × 22 圆，选中态外描边偏移 4）。
        static let swatchSize: CGFloat = 22
        static let swatchRingOffset: CGFloat = 4

        // 兼容旧命名。
        /// 进程标签高（= 芯片高）。
        static let processTagHeight: CGFloat = processChipHeight
        /// 进程标签内图标（= 芯片图标）。
        static let processTagIcon: CGFloat = processChipIcon
        /// 主按钮高度（设计稿按钮统一 sm）。
        static let primaryButtonHeight: CGFloat = buttonSmallHeight
    }

    // MARK: 色彩

    /// 语义色与表面色。
    ///
    /// **硬规则**（设计稿 §2.1）：琥珀只表示「被占用」，红色只表示「破坏性」。
    /// 磁盘快写满等其他语义一律不复用这两种颜色，避免同色双义。
    enum Palette {

        // MARK: 明暗自适应工具

        /// 由明/暗两个具体色值构造自适应 `Color`。
        ///
        /// **为什么不接收 `colorScheme` 参数**：那样每个用到语义色的子视图都要把
        /// `@Environment(\.colorScheme)` 透传下来，漏一处就会在深色下显示浅色值。
        /// `NSColor` 的 dynamic provider 由 AppKit 在绘制时按当前外观解析，天然正确。
        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                })
        }

        /// `#RRGGBB` → `NSColor`（不透明）。
        private static func hex(_ value: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1)
        }

        /// 半透明灰（`rgba(60,60,67,α)` 浅色 / `rgba(235,235,245,α)` 深色）。
        private static func ink(_ alpha: CGFloat) -> Color { ink(light: alpha, dark: alpha) }

        /// 明暗**透明度不同**的半透明灰。
        ///
        /// **为什么需要这个重载**：设计稿有一处两边不一样 —— `--text-3` 浅色
        /// `rgba(60,60,67,.38)`、深色 `rgba(235,235,245,.36)`。用同一个 α 时
        /// 总有一边偏 0.02，单看无感，但它会让「本文件与 `ds.css` 逐值一致」
        /// 这句话不成立 —— 下次核对的人得重新判断一次哪个才是对的。
        private static func ink(light: CGFloat, dark: CGFloat) -> Color {
            adaptive(
                light: NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: light),
                dark: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: dark))
        }

        // MARK: 表面

        /// 窗口实体面（色调模式）。
        static var base: Color { adaptive(light: hex(0xFFFFFF), dark: hex(0x1C1C1E)) }
        /// 浮层、设置卡片、进程芯片。
        static var raised: Color { adaptive(light: hex(0xFFFFFF), dark: hex(0x2C2C2E)) }
        /// 悬停底、分段控件槽、徽标。
        static var subtle: Color {
            adaptive(
                light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.08),
                dark: NSColor(white: 1, alpha: 0.08))
        }
        /// 悬停加深（比 `subtle` 略重一档，用于按下态）。
        ///
        /// 设计稿 `--bg-subtle-hi`：浅色 `rgba(120,120,128,.14)`、深色 `rgba(255,255,255,.14)`
        /// —— **两套都是 .14**。深色曾写 .13，与「两套同值」这句话自相矛盾。
        /// 它是容量条空槽与开关轨道的底色，透明度差 0.01 单看无感，但会让人在下次核对时
        /// 重新判断一次哪个才是对的。
        static var subtleHighlight: Color {
            adaptive(
                light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.14),
                dark: NSColor(white: 1, alpha: 0.14))
        }
        /// 证据区、弹窗底栏。
        static var sunken: Color {
            adaptive(
                light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.055),
                dark: NSColor(white: 1, alpha: 0.05))
        }
        /// 毛玻璃面 —— 设计稿 `--bg-glass`。**主窗口、菜单面板、设置面板共用这一个**。
        ///
        /// `.win` 的三个变体（`--main` / `--popover` / `--settings`）在 `ds.css` 里
        /// 只差宽高与圆角，底色一律是 `--bg-glass`：
        /// 浅色 `rgba(255,255,255,.72)`、深色 `rgba(38,38,42,.74)`。
        ///
        /// **这不是「卡片底色」**：旧名字 `cardBackground` 让人以为它只用于卡片，
        /// 于是菜单面板一直没接上它（靠 `NSPopover` 的系统材质），
        /// 结果同一个设计稿里的两块玻璃色温不一样。
        static func windowGlass(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 38 / 255, green: 38 / 255, blue: 42 / 255).opacity(0.74)
                : Color.white.opacity(0.72)
        }

        /// 旧名，等价于 ``windowGlass(for:)``。保留以免调用点大改。
        static func cardBackground(for scheme: ColorScheme) -> Color { windowGlass(for: scheme) }

        /// **色调模式**的窗口实体面 —— 设计稿 `bg-base`（浅色 `#FFFFFF`、深色 `#1C1C1E`）。
        ///
        /// 规格出自 `05-settings.html` 里「视觉效果」那一行的说明：
        /// 「透明模式使用系统毛玻璃；**色调模式使用固定的浅色背景**」。
        /// 设计稿没有画色调模式的样例屏，但 `ds.css` 里 `bg-base` 的用途栏写的就是
        /// 「窗口实体面（色调模式）」—— 与 `bg-glass`（毛玻璃窗口）是**同一层的两个选项**。
        ///
        /// 与 ``windowGlass(for:)`` 的关键区别：它是**不透明**的（没有 `.opacity`），
        /// 铺上之后桌面透不出来，也就不再需要底下那层系统材质。
        static func windowBase(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
                : Color.white
        }

        /// 弹窗（更不透明）—— 设计稿 `--bg-glass-thick`。
        ///
        /// **只有 `.alert` 用它**：弹窗浮在窗口之上，需要更强的遮挡才读得清正文。
        /// 设置面板**不是**弹窗（它在 `ds.css` 里就是 `.win`，底色仍是 `--bg-glass`），
        /// 曾经误用它，导致设置面板比设计稿白一档。
        static func popoverBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 44 / 255, green: 44 / 255, blue: 48 / 255).opacity(0.86)
                : Color.white.opacity(0.86)
        }
        /// 卡片、分隔、芯片描边。
        static var border: Color { ink(0.10) }
        /// 略重的描边（outline 按钮、徽标、面板外框）。
        ///
        /// 设计稿 `--border-strong` 两套都是 **0.18**（浅色 `rgba(60,60,67,.18)`、
        /// 深色 `rgba(255,255,255,.18)`）。曾经写 0.16 —— 描边淡一档，
        /// 在毛玻璃上尤其看不出来（这也是「outline 按钮像没有边框」的原因）。
        static var borderStrong: Color { ink(0.18) }
        /// 分隔线（比 `border` 更淡）。
        static var hairline: Color { ink(0.08) }
        /// 悬停底色（兼容旧命名）。
        static var mutedBackground: Color { subtle }

        // MARK: 文字

        /// 主文字 —— 浅色 `#1D1D1F`，16.1:1。
        static var foreground: Color { adaptive(light: hex(0x1D1D1F), dark: hex(0xF5F5F7)) }
        /// 小号加粗标题（分组名、小节名）—— 6.3:1。
        ///
        /// **存在的理由**：旧实现这类文字用 `Color.secondary` 派生的 2.2:1 灰，
        /// 在 WCAG AA 下不达标。设计稿为它单独立了一个令牌。
        static var textStrong: Color { ink(0.74) }
        /// 说明、容量、次要标签 —— 4.6:1。
        static var mutedForeground: Color { ink(0.62) }
        /// **仅装饰**，不承载信息 —— 2.2:1。禁止用于任何用户需要读的内容。
        ///
        /// 设计稿 `--text-3`：浅色 `rgba(60,60,67,.38)`、深色 `rgba(235,235,245,.36)`
        /// —— 明暗两套**透明度不同**（这是全设计稿唯一一处）。曾经写成单值 `ink(0.38)`，
        /// 深色下比设计稿重 0.02。
        static var textDecorative: Color { ink(light: 0.38, dark: 0.36) }

        // MARK: 语义色

        /// 强调色兜底（真实强调色由 ``AccentColor`` 提供，随设置变化）。
        static var accentFallback: Color { adaptive(light: hex(0x0A84FF), dark: hex(0x409CFF)) }

        /// 被占用：琥珀。**唯一用途**是左侧色条、证据区、占用文字。
        static var warning: Color { adaptive(light: hex(0xFF9500), dark: hex(0xFF9F0A)) }
        /// 琥珀底上的文字（浅色需压暗才够对比度）。
        static var warningText: Color { adaptive(light: hex(0xB25000), dark: hex(0xFFB340)) }
        /// 琥珀浅底。
        static var warningSoft: Color {
            adaptive(
                light: NSColor(srgbRed: 255 / 255, green: 149 / 255, blue: 0, alpha: 0.12),
                dark: NSColor(srgbRed: 255 / 255, green: 159 / 255, blue: 10 / 255, alpha: 0.16))
        }
        /// 琥珀内描边。
        static var warningLine: Color {
            adaptive(
                light: NSColor(srgbRed: 255 / 255, green: 149 / 255, blue: 0, alpha: 0.30),
                dark: NSColor(srgbRed: 255 / 255, green: 159 / 255, blue: 10 / 255, alpha: 0.30))
        }

        /// 破坏性：红色。**唯一用途**是「关闭并推出」与失败弹窗。
        static var error: Color { adaptive(light: hex(0xFF3B30), dark: hex(0xFF453A)) }
        /// 红底上的文字。深色 `#ff8078`（设计稿 `--danger-text`）。
        static var errorText: Color { adaptive(light: hex(0xC1190F), dark: hex(0xFF8078)) }
        /// 红色浅底。
        static var errorSoft: Color {
            adaptive(
                light: NSColor(srgbRed: 255 / 255, green: 59 / 255, blue: 48 / 255, alpha: 0.10),
                dark: NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 0.16))
        }
        /// 红色内描边（设计稿 `--danger-line: rgba(255,59,48,0.26)`）。
        ///
        /// **为什么警示块必须有描边**：它只靠 10% 的红底与卡片区分，
        /// 在浅色毛玻璃上边界几乎不可见；0.5px 的红描边把「这是一个警告块」
        /// 从「一段红色文字」里立出来。琥珀有对应的 ``warningLine``。
        static var errorLine: Color {
            adaptive(
                light: NSColor(srgbRed: 255 / 255, green: 59 / 255, blue: 48 / 255, alpha: 0.26),
                dark: NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 0.30))
        }

        /// 可安全操作：绿色。**唯一用途**是 ✓ 结论行与授权成功横幅。
        static var success: Color { adaptive(light: hex(0x34C759), dark: hex(0x30D158)) }
        /// 绿底上的文字。深色 `#5cdb7c`（设计稿 `--ok-text`）。
        static var successText: Color { adaptive(light: hex(0x1E7A38), dark: hex(0x5CDB7C)) }
        /// 绿色浅底。
        static var successSoft: Color {
            adaptive(
                light: NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 0.12),
                dark: NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 0.16))
        }
        /// 绿色描边（设计稿 `--ok-line`）。授权成功横幅是一圈完整描边，
        /// 不像琥珀横幅那样只在上下各一条 —— 这是设计稿里两种横幅的区别之一。
        static var successLine: Color {
            adaptive(
                light: NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 0.26),
                dark: NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 0.30))
        }

        // MARK: 强调色的浅底

        /// 强调色 + **随明暗切换的透明度**。
        ///
        /// **不能用 `accent.swiftUIColor.opacity(α)`**：`.opacity` 只能给一个固定 α，
        /// 而设计稿给浅色/深色配了两个值。这里直接用带 alpha 的 `NSColor` 构造。
        private static func accentTint(_ accent: AccentColor, light: CGFloat, dark: CGFloat) -> Color {
            let base = accent.appKitColor
            return adaptive(
                light: base.withAlphaComponent(light),
                dark: base.withAlphaComponent(dark))
        }

        /// 强调色浅底（图标容器、hover）。设计稿 `--accent-soft`。
        ///
        /// **透明度分两档**（`ds.css` 的三处声明）：浅色 蓝 0.10 / 紫橙绿 0.12；
        /// 深色 蓝 0.16 / 紫橙绿 0.12。深色下蓝要更重 —— 0.10 的蓝铺在 `#1c1c1e`
        /// 上几乎看不出是「一块强调色底」，图标容器就退化成一个没有底的图标。
        static func accentSoft(_ accent: AccentColor) -> Color {
            let isBlue = accent == .blue
            return accentTint(accent, light: isBlue ? 0.10 : 0.12, dark: isBlue ? 0.16 : 0.12)
        }

        /// 强调色内描边（图标容器、信息提示块）。设计稿 `--accent-ring`：
        /// 浅色 **0.35**；深色 蓝 0.40 / 紫橙绿 0.35。
        ///
        /// 曾经写死 0.24 —— 描边比设计稿淡三成，图标容器与信息提示块的边界
        /// 在浅色毛玻璃上几乎看不见（而这条 0.5px 描边正是它们与背景唯一的界限）。
        static func accentRing(_ accent: AccentColor) -> Color {
            let isBlue = accent == .blue
            return accentTint(accent, light: 0.35, dark: isBlue ? 0.40 : 0.35)
        }
    }

    // MARK: 阴影

    /// 设计稿 §2.5。深色模式阴影几乎无效，层级靠表面亮度差与 0.5px 白描边建立。
    enum Elevation {
        /// 卡片、芯片、按钮。
        static let e1 = ShadowSpec(color: .black.opacity(0.06), radius: 2, y: 1)
        /// 悬停抬升、浮层。
        static let e2 = ShadowSpec(color: .black.opacity(0.10), radius: 8, y: 3)
        /// 窗口、弹窗。
        static let e3 = ShadowSpec(color: .black.opacity(0.18), radius: 24, y: 10)

        struct ShadowSpec {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }
    }

    // MARK: 动画

    /// 设计稿 §2.6。缓动统一 `cubic-bezier(.32,.72,0,1)`。
    ///
    /// **必须尊重 `prefers-reduced-motion`**：SwiftUI 侧由 `accessibilityReduceMotion`
    /// 环境值决定是否把时长降为 0，见 ``Motion/animation(_:reduceMotion:)``。
    enum Motion {
        /// 120ms —— 悬停、颜色过渡。
        static let fast: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.12)
        /// 180ms —— 开关、分段控件、展开收起。
        static let standard: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.18)
        /// 260ms —— 容量条填充。
        static let slow: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.26)

        /// 按「是否开启减弱动效」返回对应动画（开启时返回 `nil`，即瞬时切换）。
        static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : base
        }
    }
}

// MARK: - 辅助：NSColor 十六进制

extension NSColor {
    /// 16 进制字符串 → NSColor（公开给菜单栏 tint 等使用）。
    convenience init?(designHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
