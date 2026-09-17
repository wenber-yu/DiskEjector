import Foundation
import Testing

@testable import DiskEjectorApp

// MARK: - 替身与夹具

/// 线程安全的调用计数器（`detect` 闭包是 `@Sendable`，不能用裸 `var`）。
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// 把 `AsyncStream` 的 continuation 装进一个盒子。
///
/// **为什么需要**：`detect` 闭包是 `@Sendable`，直接捕获 `AsyncStream.Continuation?`
/// 那个 `var` 会被编译器拒绝（`reference to captured var in concurrently-executing code`）。
/// 盒子的写入只发生在建流那一刻、且早于任何一次 `detect` 调用，因此 `@unchecked` 是安全的。
private final class SignalBox: @unchecked Sendable {
    var continuation: AsyncStream<Void>.Continuation?
}

/// 造一块测试用磁盘。`id` 就是挂载路径（与生产一致：同路径即同一卷）。
private func makeDisk(_ path: String) -> DiskInfo {
    DiskInfo(
        id: path,
        bsdName: "disk9s1",
        volumeName: (path as NSString).lastPathComponent,
        mountPath: path,
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        deviceProtocol: "USB",
        deviceModel: nil
    )
}

/// 轮询等待条件成立。**不用固定 `sleep`**：那要么白等、要么在慢机器上假红。
///
/// 超时给到 10s：单独跑时通常 10ms 内就成立，但全量测试里主 actor 被别的用例占着，
/// 3s 会偶发假红（实测过一次）。
@MainActor
private func waitUntil(
    timeout: TimeInterval = 10,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// 造一个不跑真实 lsof 的 store。`pollInterval` 默认给足，避免轮询干扰断言。
@MainActor
private func makeStore(
    diskStore: DiskListStore,
    pollInterval: TimeInterval = 3600,
    autoStart: Bool = false,
    detect: @escaping @Sendable (String) async -> OccupancyResult
) -> OccupancyStore {
    OccupancyStore(
        diskStore: diskStore, pollInterval: pollInterval, detect: detect, autoStart: autoStart)
}

// MARK: - 测试
//
// 这一组测试守的是 2026-09-15 用户报告的那个 bug：
// 「主窗口显示有程序在占用，菜单栏面板显示没有占用，这用的不是同一套逻辑吗？」
//
// 检测逻辑本来就是同一套；**分叉的是状态**——两个界面各持一个私有 `@State`，
// 各按各的节奏刷新（主窗口有 15s 轮询，面板没有）。所以这里钉的不是「检测函数对不对」，
// 而是「状态只有一份、节奏只有一条、读法只有一种」。

@Suite("占用结论的单一事实来源")
@MainActor
struct OccupancyStoreTests {

    @Test("结果按卷的挂载路径归档")
    func 结果按卷的挂载路径归档() async {
        let diskStore = DiskListStore(monitoring: false)
        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        let store = makeStore(diskStore: diskStore) { path in
            path.hasSuffix("/A") ? .none : .unknown
        }

        await store.refresh(disks: [a, b])

        #expect(store.results.count == 2)
        #expect(store.result(for: a) == .none)
        #expect(store.result(for: b) == .unknown)
    }

    /// **本文件最重要的一条**：读不到结论时的兜底必须是 `.unknown`。
    ///
    /// 兜成 `.none` 会让「还没测出来」显示成绿色的「可以安全推出」——
    /// 而 `.none` 与 `.unknown` 在类型上都是合法的 `OccupancyResult`，编译器不会拦。
    @Test("读不到结论的卷兜底为 unknown，绝不兜成 none")
    func 读不到结论的卷兜底为unknown() async {
        let diskStore = DiskListStore(monitoring: false)
        let store = makeStore(diskStore: diskStore) { _ in .none }
        let never = makeDisk("/Volumes/NEVER-MEASURED")

        #expect(
            store.result(for: never) == .unknown,
            "没测过的卷必须读成「占用情况未知」。读成 .none 就是「可以安全推出」——本应用最不能犯的错误")
    }

    @Test("磁盘拔出后它的旧结论必须消失")
    func 磁盘拔出后旧结论消失() async {
        let diskStore = DiskListStore(monitoring: false)
        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        let store = makeStore(diskStore: diskStore) { _ in .none }

        await store.refresh(disks: [a, b])
        #expect(store.results.count == 2)

        await store.refresh(disks: [a])

        #expect(
            store.results.count == 1,
            "整体替换而不是逐个合并——否则拔掉的盘会把旧结论永远留在字典里")
        #expect(store.results[b.id] == nil)
        #expect(store.result(for: a) == .none)
    }

    @Test("空磁盘列表清空全部结论")
    func 空磁盘列表清空全部结论() async {
        let diskStore = DiskListStore(monitoring: false)
        let store = makeStore(diskStore: diskStore) { _ in .none }
        await store.refresh(disks: [makeDisk("/Volumes/A")])
        #expect(!store.results.isEmpty)

        await store.refresh(disks: [])

        #expect(store.results.isEmpty)
    }

    @Test("检测结果原样透传，unknown 不会被降级成 none")
    func unknown不会被降级() async {
        let diskStore = DiskListStore(monitoring: false)
        let disk = makeDisk("/Volumes/A")
        let store = makeStore(diskStore: diskStore) { _ in .unknown }

        await store.refresh(disks: [disk])

        #expect(store.result(for: disk) == .unknown)
    }

    /// **并发刷新必须被「合并」，不能被「丢弃」**。
    ///
    /// 主窗口原来用的是「单飞 + 直接 return」：上一轮 lsof 没跑完时，新的请求被丢掉。
    /// 用户点「刷新」正好撞上后台轮询，那一次点击就静默失效 —— 界面停在旧值上，
    /// 看起来就是「点了没反应」。现在改成登记 `pending`，循环处理完上一批立刻接着处理。
    @Test("并发刷新会被合并，最后一次的磁盘列表一定生效")
    func 并发刷新被合并() async {
        let diskStore = DiskListStore(monitoring: false)
        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        let counter = CallCounter()

        // 用 AsyncStream 当「第一轮已开始」的信号，替代固定 sleep。
        let box = SignalBox()
        let started = AsyncStream<Void> { box.continuation = $0 }

        let store = makeStore(diskStore: diskStore) { _ in
            await counter.increment()
            box.continuation?.yield(())
            try? await Task.sleep(nanoseconds: 60_000_000)
            return .none
        }

        let first = Task { @MainActor in await store.refresh(disks: [a]) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()  // 等第一轮真的跑起来
        let second = Task { @MainActor in await store.refresh(disks: [a, b]) }
        await first.value
        await second.value
        box.continuation?.finish()

        #expect(
            store.results.count == 2,
            "第二次请求带上了 B，最终结果必须包含 B —— 被丢掉就说明「刷新」会静默失效")
        let calls = await counter.count
        #expect(calls >= 3, "A 测两次（两轮）+ B 测一次 = 3；只有 1 次说明第二次请求被丢了，实际 \(calls)")
    }

    /// **本文件第二条关键断言**：磁盘列表一变就必须重测。
    ///
    /// 面板上的「刷新磁盘列表」走的是 `DiskListStore.refresh()` —— 它每次都把新数组
    /// 赋给 `disks`。视图里原先用 `.onChange(of: store.disks)` 监听，而
    /// `.onChange` **只在值不相等时触发**：重新枚举了一遍但内容没变时，
    /// 它安静地什么都不做。`OccupancyStore` 改用 Combine `sink`，每次赋值都投递。
    @Test("磁盘列表一变就重测占用（刷新按钮真的会刷新占用结论）")
    func 磁盘列表一变就重测占用() async {
        let diskStore = DiskListStore(monitoring: false)
        let disk = makeDisk("/Volumes/NEW")

        let store = makeStore(diskStore: diskStore, autoStart: true) { _ in .none }
        defer { store.stop() }
        #expect(store.results.isEmpty)

        diskStore.replaceDisksForTesting([disk])
        let arrived = await waitUntil { store.result(for: disk) == .none }
        #expect(
            arrived,
            "DiskListStore.disks 一变，占用结论必须重测；否则「刷新磁盘列表」只刷新容量数字、刷不动占用结论")

        // 同一份列表再发一次（内容完全相同）：`.onChange` 会漏掉，`sink` 不会。
        let counter = CallCounter()
        let store2 = makeStore(diskStore: diskStore, autoStart: true) { _ in
            await counter.increment()
            return .none
        }
        defer { store2.stop() }
        _ = await waitUntil { await counter.count >= 1 }
        let afterFirst = await counter.count

        diskStore.replaceDisksForTesting([disk])  // 内容一模一样

        let retested = await waitUntil { await counter.count > afterFirst }
        #expect(retested, "内容相同的一次重新枚举也必须重测——这正是 `.onChange` 漏掉的那种情况")
    }

    @Test("stop 之后不再响应磁盘列表变化")
    func stop之后不再响应() async {
        let diskStore = DiskListStore(monitoring: false)
        let counter = CallCounter()
        let store = makeStore(diskStore: diskStore, autoStart: true) { _ in
            await counter.increment()
            return .none
        }

        // 初始列表为空 → 首轮不会调用 detect（`performDetect` 对空列表直接返回），
        // 所以 baseline 一定是 0。等一会儿让首轮彻底排空，避免把「首轮还在跑」
        // 误当成「stop 之后仍在响应」。
        try? await Task.sleep(nanoseconds: 150_000_000)
        store.stop()
        let baseline = await counter.count

        diskStore.replaceDisksForTesting([makeDisk("/Volumes/AFTER-STOP")])

        // 给足时间让「本不该发生」的检测有机会发生。
        try? await Task.sleep(nanoseconds: 250_000_000)
        let afterStop = await counter.count
        #expect(
            afterStop == baseline,
            "stop() 之后订阅已解除，不该再有检测（实际多了 \(afterStop - baseline) 次）")
    }
}
