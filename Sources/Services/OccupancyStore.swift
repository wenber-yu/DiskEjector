import Combine
import Foundation

/// 卷占用结论的**单一事实来源**（主窗口与菜单栏面板共用同一份）。
///
/// ## 为什么需要它
///
/// 2026-09-15 用户报：「主窗口显示有程序占用，菜单栏面板显示没有占用，这用的不是同一套逻辑吗？」
///
/// 检测逻辑确实是同一套 —— 两个界面都走 `EjectFlowController.checkOccupancy` →
/// `OccupancyDetector.detect`。**问题出在状态被抄了两份**：
/// `ContentView` 与 `MenuPopoverView` 各持一个 `@State var occupancy`，
/// 各自按各自的节奏去刷新：
///
/// | | 主窗口 | 菜单面板 |
/// |---|---|---|
/// | 首次加载 | `.task` | `.task`（每次点开都重建视图 → 每次都跑） |
/// | 定时刷新 | **15s 轮询** | **无** |
/// | 应用重新激活 | `didBecomeActiveNotification` | 无 |
/// | 磁盘列表变化 | `.onChange(of: store.disks)` | 同左 |
///
/// 于是「同一个时刻，两块盘，两个结论」在结构上就是可能的 —— 面板看到的是它自己被创建那一刻的快照，
/// 而主窗口看到的是最近一次 15s tick 的结果。中间任何一次插拔、任何一次进程开关文件，
/// 都会让两边分叉。
///
/// 更隐蔽的一条：`.onChange(of:)` 只在**值不相等**时触发。
/// `DiskListStore.refresh()` 每次都把新数组赋给 `disks`，内容一样时 `onChange` 静默不触发 ——
/// 面板上的「刷新磁盘列表」按钮因此**从来不会刷新占用结论**，只刷新容量数字。
///
/// ## 做法
///
/// 把「状态」与「节奏」都收进本类，两个界面退化成纯读取：
/// - 一份 `results`，两边读的是同一个字典、同一帧的值；
/// - 一个 15s 轮询循环，**只要本类被创建就在跑**，与「哪个窗口开着」无关；
/// - 监听 `DiskListStore.$disks`（`sink` 而非 `onChange`，每次赋值都触发）。
///
/// ## 生命周期
///
/// `shared` 是懒加载单例：第一次有界面读它时创建并启动轮询。
/// 两个界面都关掉后它仍在跑（每 15s 一次 `lsof`，代价可忽略），
/// 这样再次打开任何界面时看到的是**最新的**结论，而不是「刚打开那一刻重新测」。
@MainActor
final class OccupancyStore: ObservableObject {

    static let shared = OccupancyStore()

    /// 全部已挂载卷的占用结论，键是 ``DiskInfo/id``。
    ///
    /// **读不到时请用 `.unknown` 而不是 `.none`**：`.none` 是「已确认没有占用」，
    /// 把「还没测出来」渲染成它是本应用最不能犯的错误（见 ``DiskRowState``）。
    @Published private(set) var results: [String: OccupancyResult] = [:]

    /// 正在等待处理的磁盘列表。新的请求会**覆盖**旧的 —— 我们只关心最新状态。
    private var pending: [DiskInfo]?

    /// 是否已有一轮检测在跑。跑着的时候新请求只登记 `pending`，由那一轮顺带处理。
    private var isRunning = false

    /// 登记了请求、但被合并进当前这一轮的调用方。
    ///
    /// **为什么要有它**：被合并的调用方不能就这么返回 —— `ContentView` 的刷新按钮
    /// 是 `await refresh(...)` 之后才停转的，提前返回会让 spinner 撒谎
    /// （转完了，界面还是旧结论）。当前这一轮跑完时统一唤醒它们。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var pollingTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private let diskStore: DiskListStore
    private let pollInterval: TimeInterval
    private let detect: @Sendable (String) async -> OccupancyResult

    /// - Parameters:
    ///   - diskStore: 磁盘列表来源，默认全局单例。
    ///   - pollInterval: 轮询间隔（秒）。设计上取 15s —— 与主窗口原来的节奏一致。
    ///   - detect: 单卷检测入口。默认走生产链路；测试注入替身即可完全离线。
    ///   - autoStart: 是否立即开始监听与轮询。测试里传 `false` 手动驱动。
    init(
        diskStore: DiskListStore? = nil,
        pollInterval: TimeInterval = 15,
        detect: @escaping @Sendable (String) async -> OccupancyResult = { mountPath in
            await EjectFlowController.shared.checkOccupancy(mountPath: mountPath)
        },
        autoStart: Bool = true
    ) {
        self.diskStore = diskStore ?? .shared
        self.pollInterval = pollInterval
        self.detect = detect
        if autoStart { start() }
    }

    /// 开始监听磁盘列表变化并启动轮询。重复调用无副作用。
    func start() {
        guard pollingTask == nil else { return }

        // **用 `sink` 而不是视图里的 `.onChange(of:)`**：`@Published` 每次赋值都会投递，
        // 哪怕新旧数组内容相等。用户点「刷新磁盘列表」时我们**必须**重新测一次占用 ——
        // `.onChange` 会因为「值没变」而安静地什么都不做。
        //
        // 这里**不再单独发一次初始刷新**：`@Published` 的订阅会**立即投递当前值**，
        // 那次投递就是首帧刷新。再补一次会让首帧连测两轮（实测 counter 从 1 变 2），
        // 白跑一遍 `lsof`。
        diskStore.$disks
            .sink { [weak self] disks in
                Task { @MainActor in await self?.refresh(disks: disks) }
            }
            .store(in: &cancellables)

        let interval = pollInterval
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // `Task.sleep` 被取消时会立刻抛出，若不在循环里再判一次就会变成忙等。
                guard !Task.isCancelled, let self else { return }
                await self.refresh(disks: self.diskStore.disks)
            }
        }
    }

    /// 停止轮询与监听（测试收尾用；生产不需要）。
    ///
    /// 顺带唤醒还挂着的等待者：`stop()` 之后当前这一轮仍会跑完，
    /// 但万一调用方是在 `stop()` 之后才登记进来的，不让它永远挂着。
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        cancellables.removeAll()
        pending = nil
        let resuming = waiters
        waiters = []
        for continuation in resuming { continuation.resume() }
    }

    /// 取某块盘的判定结论。**主窗口与菜单面板都必须走这里**。
    ///
    /// **为什么不让调用方各写一遍 `results[disk.id] ?? .unknown`**：
    /// 兜底值写错一次就是灾难 —— 兜成 `.none` 会让「还没测出来」显示成
    /// 「可以安全推出」，而 `.none` 与 `.unknown` 在类型上都是合法的 `OccupancyResult`，
    /// 编译器不会拦。收成一个方法后，「读不到时兜什么」只有一处定义，也能被单测钉住。
    func result(for disk: DiskInfo) -> OccupancyResult {
        results[disk.id] ?? .unknown
    }

    /// 按给定磁盘列表刷新占用结论。
    ///
    /// **并发调用会被合并，但不会被丢弃**：若已有一轮检测在跑，本次请求覆盖 `pending`
    /// 并等待那一轮结束 —— 循环会在处理完手头这批之后**立刻**再处理最新的一批，
    /// 然后才唤醒所有等待者。
    ///
    /// **这里踩过一个坑**（值得记下来）：第一版写的是「有 worker 就 `await worker.value`
    /// 然后 return」。问题是 worker 可能在「检查 `pending`」与「退出循环」之间那一瞬间
    /// 已经决定退出 —— 此时新请求登记进去就**永远不会被处理**，
    /// 而调用方却正常返回了。表现为「点了刷新，偶尔没反应」。
    /// 现在改成：登记 + 等待「本轮全部排空」，不存在这个窗口。
    func refresh(disks: [DiskInfo]) async {
        pending = disks
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        while let next = pending {
            pending = nil
            await performDetect(disks: next)
        }
        isRunning = false
        // `isRunning = false` 与唤醒之间**不能有 `await`**：否则这个窗口里进来的新请求
        // 会看到 `isRunning == false`、自己起一轮，同时又把自己登记进了 `waiters`，
        // 而那一批 `waiters` 已经被我们取走 —— 唤醒就丢了。
        let resuming = waiters
        waiters = []
        for continuation in resuming { continuation.resume() }
    }

    /// 真正跑一轮检测：并发测每一块盘，**整体替换** `results`。
    ///
    /// **整体替换而不是逐个合并**：磁盘拔出后它的旧结论必须消失。
    /// 若只更新测到的键，拔掉的那块盘的结论会永远留在字典里，
    /// 下次同名卷再插上来会先显示一段别人的旧结论。
    private func performDetect(disks: [DiskInfo]) async {
        guard !disks.isEmpty else {
            if !results.isEmpty { results = [:] }
            return
        }
        let detect = self.detect
        var next: [String: OccupancyResult] = [:]
        await withTaskGroup(of: (String, OccupancyResult).self) { group in
            for disk in disks {
                // 只捕获字符串：闭包要跨 actor 边界，别把整个 DiskInfo 拖过去。
                let id = disk.id
                let path = disk.mountPath
                group.addTask { (id, await detect(path)) }
            }
            for await (id, result) in group { next[id] = result }
        }
        results = next
    }
}
