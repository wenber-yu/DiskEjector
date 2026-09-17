import AppKit
import Combine
import Foundation

/// 外置可推出卷的单一事实来源（菜单栏与主窗口共用）。
///
/// **为什么需要它**：此前 `AppDelegate`（`currentDisks`）与 `ContentView`（`disks`）各持一份列表、
/// 各自监听挂载通知，导致「插拔后是否自动刷新」「看到哪些盘」两处可能分叉。
/// 本 store 集中持有列表与监听，所有 UI 只读取 ``disks``，保证看到的磁盘集合永远一致。
///
/// 监听只投递到 `NSWorkspace.shared.notificationCenter`（本机实测：默认 `NotificationCenter.default`
/// 收不到挂载事件），且只在未来事件生效，因此 `init` 里先同步填一次初始列表。
@MainActor
final class DiskListStore: ObservableObject {

    static let shared = DiskListStore()

    @Published private(set) var disks: [DiskInfo] = []

    private var observers: [NSObjectProtocol] = []

    private init() {
        setupMonitoring()
        // 监听只对未来事件生效，先同步填一次初始列表。
        disks = DiskService.shared.fetchExternalDisks()
    }

    #if DEBUG
        /// **测试专用**：造一个不挂系统监听、磁盘列表可手动灌入的实例。
        ///
        /// **为什么需要这个口子**：`disks` 是 `private(set)`，唯一写入路径 `refresh()`
        /// 会真的去枚举本机磁盘 —— 单测既没法用它构造「刚插上一块盘」，
        /// 也会因为测试机上真实的插拔而随机变红。
        /// 生产构建里不存在这个初始化器（`#if DEBUG`），`shared` 也不受影响。
        init(monitoring: Bool) {
            if monitoring { setupMonitoring() }
            disks = []
        }

        /// **测试专用**：替换磁盘列表并像 `refresh()` 那样发布一次。
        ///
        /// 刻意**不做去重**：`@Published` 每次赋值都会投递，这正是
        /// ``OccupancyStore`` 用 `sink` 而不是视图里 `.onChange(of:)` 的原因 ——
        /// 后者在「新数组内容相等」时静默不触发，导致「刷新」按钮刷不动占用结论。
        func replaceDisksForTesting(_ newDisks: [DiskInfo]) {
            disks = newDisks
        }
    #endif

    /// 重新枚举外置卷。涉及磁盘 I/O，放到后台线程执行后回到主线程更新。
    func refresh() async {
        let fetched = await Task.detached(priority: .userInitiated) {
            DiskService.shared.fetchExternalDisks()
        }.value
        disks = fetched
    }

    private func setupMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: NSWorkspace.shared, queue: .main) { [weak self] _ in
                // 通知在 .main 队列投递，但 Swift 并发语境下仍需显式切回主 actor 再刷新。
                Task { @MainActor in await self?.refresh() }
            }
            observers.append(token)
        }
    }
}
