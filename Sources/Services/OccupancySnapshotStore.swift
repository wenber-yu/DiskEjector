import Foundation

/// 占用结论的**跨线程只读快照**。
///
/// ## 为什么需要它（这是 PoC 里会让功能静默失效的两处 P0 缺陷之一）
///
/// ``OccupancyStore`` 是 `@MainActor` 单例，而 DA approval 回调跑在
/// `com.diskejector.da.approval` 队列上 —— **真机实测 `Thread.isMainThread == false`**
/// （`.build/probe/da_approval_spike/mainthread_probe.swift` 与同目录 `probe-out.txt`）。
///
/// 在那个线程上写 `MainActor.assumeIsolated { … }` 会 **SIGTRAP 崩掉整个进程**
/// （实测退出码 133，`-O` 与 `-Onone` **都崩**）。崩掉之后 DA 把「没有 approval 者」
/// 当作批准（spike 已实证崩溃安全性）⇒ **盘照样推出、功能一次都没生效、应用静默死掉**。
/// 而「没弹窗」的两种解释（功能没生效 / 应用已经死了）在用户看来**逐字相同**。
///
/// ## 被否决的替代方案
///
/// - **改成 `DASessionSetDispatchQueue(s, .main)`**：回调落到主线程上，而回调是
///   **同步阻塞**的（最长 60s 等用户）⇒ **主线程冻 60s**，界面全卡死。不可行。
/// - **在 DA 回调线程上套一层信号量往主 actor 要值**：那会在回调线程上再引入一次
///   「跨线程同步等待」，而它等的正是主线程 —— 与「主线程在等 DA 回调返回」形成
///   互等的死锁面。（``EjectHookService/waitForUserChoice`` 那条路不存在这个环，
///   因为主线程在等的是**用户**。）
///
/// ## 口径
///
/// ``OccupancyStore`` 是**唯一写入方**（在 `@MainActor` 上），本类只做「原样存、按需读」。
/// 若两个写入点各写一遍，快照必然与 UI 分叉 —— 而「两个界面看到两个结论」
/// 正是 ``OccupancyStore`` 诞生时要修的病。
enum OccupancySnapshotStore {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [String: OccupancyResult] = [:]

    /// 由 ``OccupancyStore`` 在**主 actor 上**调用（每次结论变化时）。
    ///
    /// **整体替换**（不是逐键合并）—— 与 ``OccupancyStore/results`` 同口径：
    /// 拔掉的盘必须连旧结论一起消失，否则下次同名卷再插上来会先显示一段别人的旧结论。
    static func update(_ next: [String: OccupancyResult]) {
        lock.lock()
        defer { lock.unlock() }
        values = next
    }

    /// 由 DA 回调线程调用。
    ///
    /// ⚠️ **读不到 ⇒ `.unknown`**（绝不能兜成 `.none`）：`.none` 是「已确认没有占用」，
    /// 那会把「还没测出来」变成放行 —— 本应用最不能犯的错误（``DiskRowState`` 的注释）。
    static func occupancy(for mountPath: String) -> OccupancyResult {
        lock.lock()
        defer { lock.unlock() }
        return values[mountPath] ?? .unknown
    }
}
