import SwiftUI

/// 全局字号规范（对齐 ProxyGenerator 项目的 UI 风格，单一事实来源）。
///
/// **为什么需要它**：macOS 的系统语义字号本就偏小——`.caption` / `.caption2` 只有 10pt、
/// `.subheadline` 11pt、`.body` / `.headline` 13pt。本应用是宽窗口工具，大量状态与说明文字
/// 用 `.caption` 承载，实测阅读吃力。
///
/// **做法**：把界面用到的字号收敛成一组语义常量，整体上调一档；视图层只引用语义
/// （`cardTitle` / `label` / `minor` …），不再直接写 `.caption`、`.system(size:)` 之类的裸值。
/// 需要整体再放大或缩小时，只改 ``scale`` 一处，不必逐处翻源码——避免口径漂移。
enum AppFont {
    /// 全局缩放系数：1.0 = 下方基准字号。想整体调节字号只改这一处。
    static let scale: CGFloat = 1.0

    private static func sized(_ pt: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: (pt * scale).rounded(), weight: weight)
    }

    /// 卡片主标题。
    static var cardTitle: Font { sized(17, .semibold) }

    /// 卡片内小节标题。
    static var sectionTitle: Font { sized(14, .semibold) }

    /// 列表主行文字：磁盘名。
    static var rowTitle: Font { sized(15) }

    /// 常规正文与系统控件：Toggle / Picker / 单选项标签。
    static var control: Font { sized(14) }

    /// 说明性文字与状态标签，界面上用量最大的一档。
    static var label: Font { sized(13) }

    /// 需要强调的状态标签。
    static var labelBold: Font { sized(13, .semibold) }

    /// 次级小字：错误详情、角标。
    static var minor: Font { sized(12) }

    /// 等宽字。
    static var mono: Font { .system(size: (12.5 * scale).rounded(), design: .monospaced) }

    /// 空态大图示。
    static var emptyGlyph: Font { .system(size: 40 * scale, weight: .light) }

    /// 行内操作图标，如推出按钮。
    static var rowGlyph: Font { sized(16) }
}
