import Foundation
import Testing

/// 一次「轮询等待」的结果。
///
/// ## 为什么不是 `Bool`（2026-09-21）
///
/// 两个测试 helper（`OccupancyStoreTests.waitUntil`、
/// `ProcessAppResolverTests.waitForExecutablePath`）原来只返回 `Bool`，
/// 失败信息分别是「`arrived` 为 false」「`ready` 为 false」。
///
/// 2026-09-17 CI 上真红过一次，而那句话**什么都没说明** —— 它把两件修法完全不同的事
/// **渲染成同一句话**：
///
/// - **主 actor 被别的用例占住**，等待链根本没被轮到（并发争抢，改法在测试侧）；还是
/// - **条件确实很久不成立**（被测逻辑有问题，改法在生产代码）。
///
/// ⇒ 与 §8.113.12「门槛红了却拿到一个假名字」同一条轴：**报错必须指名真因**。
///
/// ## ⚠️ 两个数字的口径完全不同，别混用
///
/// - ``polls``：**条件被求值的次数**。它是唯一**与机器负载无关**的量 ——
///   条件成立得快，拍数就少，哪怕墙钟被调度拖得很长。实测正常时 1–3 拍。
///   ⇒ **判「是不是并发争抢」看这个**。
/// - ``elapsed``：墙钟耗时。⚠️ **它包含「主 actor 被别的用例占住」的时间**，
///   所以 `elapsed` 大**不**代表这条测试自己有问题
///   （同病：§8.113.18 查清的 `passed after` 也是「完成时刻」而非该测试自身耗时）。
///   ⇒ 它只用来**报告**，不用来下结论。
///
/// ⚠️ **两个数字都不能单独用来断言「性能是否正常」**：`elapsed` 会被调度污染，
/// `polls` 只对「等一条会被主 actor 推进的链路」有意义。它们的作用是**在失败时
/// 把人指向正确的方向**，不是当门槛。
struct WaitOutcome: Sendable {

    /// 条件最终是否成立。
    let ok: Bool

    /// 条件被求值的次数（含超时后那一次补查）。
    let polls: Int

    /// 从开始等待到结束的墙钟耗时（含被调度拖走的时间）。
    let elapsed: TimeInterval

    /// 失败信息里带上数字 —— 下次 CI 红时**不用再猜**。
    var diagnostic: String {
        String(
            format: "等了 %.2fs、求值 %d 次，条件%@",
            elapsed, polls, ok ? "最终成立" : "始终不成立")
    }

    /// 失败信息：**调用处只补一句「在等什么」，数字一律从这里来**。
    ///
    /// 抽成纯函数是为了**可被断言**：``expectArrived`` 里那句 `#expect` 的消息
    /// 没法在测试里取到，而这里的返回值可以（见两个套件里的「等待 helper 自己的守卫」）。
    /// ⇒ 少了这层，「消息里到底有没有数字」就退化成一条**约定**，没人守得住。
    func failureNote(_ what: String) -> String {
        "\(what)\n\(diagnostic)"
    }
}

/// 断言「等到了」，失败信息里**一定**带 ``WaitOutcome/diagnostic``。
///
/// **为什么必须走这个函数，而不是各处手写 `#expect(x.ok, "…\(x.diagnostic)")`**：
/// 手写时「把 `diagnostic` 写进消息」只是**约定** —— 谁少写一次都不会有任何东西变红，
/// 而失败信息退化成「`arrived` 为 false」正是这次要修的病。
/// 走函数则**结构上**不可能漏：消息由 ``WaitOutcome/failureNote(_:)`` 唯一决定。
/// （同 §8.113.13「能派生就别用手动开关」。）
///
/// ⚠️ `sourceLocation` 的默认值让失败报在**调用处**而不是本函数里 ——
/// 少了它，CI 红的时候指向的是这个文件，等于又绕远路。
func expectArrived(
    _ outcome: WaitOutcome,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(outcome.ok, "\(outcome.failureNote(what))", sourceLocation: sourceLocation)
}
