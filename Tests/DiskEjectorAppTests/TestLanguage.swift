import Foundation

@testable import DiskEjectorApp

/// 把测试钉在**确定的语言**下运行。
///
/// ## 为什么必须钉
///
/// 设计稿的排版数字（面板 440×566、引导窗 503.3、按钮 50 / 102、路径小标 226 …）
/// **全部按中文实测**。而 `L10n.tr` 的默认语言是 `Locale.current` ——
/// 于是「排版与设计稿一致」这类断言的结果**由运行机器的系统语言决定**：
/// 中文机器上绿，英文机器上红。同一份代码，两种结论。
///
/// 2026-09-17 实测：CI 连续 6 次红（从 `dd3d2d6` 起），19 个 issue 里 **18 个**都是它，
/// 而本地一直绿 —— 只因为开发机是中文环境。**这就是「换台机器必红」的环境依赖**。
///
/// ## 与 2026-09-12 `ed091d6` 的关系
///
/// 那次修的是同一类病的一半：「**期望值不要写死成某个中文字符串**」，
/// 改为与产品同源的 `L10n.tr(key)`。这次补上另一半 ——
/// 「**要断言中文排版，就得先明确地在中文下渲染**」。
/// 只做前一半，布局数字依然无处安放（英文下这些数字本来就不成立）。
///
/// ## 为什么用 `@TaskLocal` 而不是全局变量
///
/// swift-testing **并行**跑用例。全局可变状态会串台：一个用例把语言改成英文，
/// 另一个正在渲染的用例会跟着变，于是失败变成随机出现 —— 比环境依赖更难查。
/// 任务局部只在 `withValue` 闭包内生效、随子任务传播，天然按用例隔离。
enum TestLanguage {

    /// 设计稿的语言。**断言设计稿数字的用例都用它**。
    static let design = "zh-Hans"

    /// 在指定语言下执行 `body`（同步）。
    static func with<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        try L10n.$forcedLocale.withValue(Locale(identifier: identifier), operation: body)
    }

    /// 在指定语言下执行 `body`（异步）。
    static func with<T>(_ identifier: String, _ body: () async throws -> T) async rethrows -> T {
        try await L10n.$forcedLocale.withValue(
            Locale(identifier: identifier), operation: body)
    }

    /// 取**设计稿语言**下的文案。
    ///
    /// 用途：断言「用了哪个 key」时，期望值应当与**渲染时同一语言**下解析出来的文本比对，
    /// 而不是写死一个中文字面量（那正是 `ed091d6` 修掉的写法）。
    static func designText(_ key: L10n.Key) -> String {
        L10n.tr(key, locale: Locale(identifier: design))
    }
}
