import AppKit
import DiskArbitration
import Foundation
import OSLog

/// 接管访达（Finder）与其它进程的「推出」请求。
///
/// ## 链路（spike 已在 `.build/probe/da_approval_spike/` 实证）
///
/// 访达的推出按钮 → `NSWorkspace.unmountAndEjectDevice` 走 DiskArbitration →
/// ``DARegisterDiskUnmountApprovalCallback`` / ``DARegisterDiskEjectApprovalCallback``
/// **同步阻塞**到本类回话。因此本类在专用并发队列上挂信号量，主线程跑弹窗，不阻塞 UI。
///
/// 判定走 ``EjectHookPolicy``（纯值、可单测），本类只做「解析 → 判定 → 去重 → 弹窗 → 回话」的编排。
///
/// ## ⚠️ 四条关键约束（spike 实证后落字）
///
/// 1. **回调同步阻塞**：DA 协议要求同步回执。阻塞一块盘期间**其它盘的 unmount 请求被排队**
///    （跨盘冻结，实测 B 盘耗时从 <2s 变成 11s）—— 这是 DA 决定的，生产实现避免不了，
///    只能在设置项说明里如实告知用户。
/// 2. **必须自排除**：``EjectService/eject(disk:)`` 在 `unmountAndEjectDevice` 之前把
///    ``EjectService/isHookSelfInitiated`` 置 `true`；本类回调里读到即放行，
///    否则会自己拦自己 = 永久推不出。
/// 3. **不能碰 `@MainActor`**：本类的回调跑在 `com.diskejector.da.approval` 上
///    （**实测 `isMainThread == false`**）。在那里写 `MainActor.assumeIsolated` 会
///    **SIGTRAP 崩掉整个进程**（实测退出码 133）⇒ 占用结论一律读
///    ``OccupancySnapshotStore``（非隔离快照），弹窗走 `Task { @MainActor in … }` + 信号量。
/// 4. **崩溃安全**：spike 实测 kill 掉持有回调的进程后，DA 把「没有 approval 者」视作批准
///    ⇒ DiskEjector 崩了不会把用户的盘永久卡死。
///
/// ## 开关语义边界
///
/// ``AppSettings/takeOverFinderEject`` 只控制「**要不要弹窗拦这一块盘**」。
/// **自排除**与**无挂载路径放行**永远生效，与开关无关 —— 关掉开关也必须能推出自己的盘。
/// 开关**每次回调现读、不缓存**（改了即时生效，不用重启）；注册的回调本身
/// **保持注册、永不注销**（注销再注册要处理「注销期间到达的请求漏掉」这类时序问题）。
final class EjectHookService: @unchecked Sendable {

    static let shared = EjectHookService()

    private init() {}

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "EjectHook")

    /// 单例 session；同一进程只注册一次（重复注册会重复触发回调）。
    private var session: DASession?

    /// 同盘去重（进程内内存，不落 `UserDefaults`）。
    ///
    /// **为什么不落盘**：跨启动的去重会把「刚重启后点推出」静默吞掉 ——
    /// 而重启后本来就该重新问一次。
    private static let throttle = EjectHookThrottleStore()

    /// 注册两个 approval callback。**只在 app 启动时调一次**。
    func register() {
        guard session == nil else {
            Self.logger.notice("EjectHookService 已注册，跳过")
            return
        }
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            Self.logger.error("DASessionCreate 失败，hook 不生效")
            return
        }
        // 派发到专用并发队列 —— 阻塞回调只会卡这条队列，不影响 UI。
        let queue = DispatchQueue(
            label: "com.diskejector.da.approval", attributes: .concurrent)
        DASessionSetDispatchQueue(s, queue)

        DARegisterDiskUnmountApprovalCallback(s, nil, Self.unmountApproval, nil)
        DARegisterDiskEjectApprovalCallback(s, nil, Self.ejectApproval, nil)
        session = s
        Self.logger.notice("已注册 unmount/eject approval")
    }

    /// 开关为真时**显式启动**占用轮询。
    ///
    /// ## 为什么必须有这个动作
    ///
    /// ``OccupancyStore`` 是**懒加载单例** —— 第一次有界面读它时才创建并启动轮询。
    /// 而全仓对它的触达点只有三处：`ContentView`（默认参数，**用户打开主窗口**时）、
    /// `DiskEjectorApp`（用户从**菜单栏自己**发起推出时）、以及本类回调。
    ///
    /// ⇒ 用户打开开关、然后**直接在访达里点推出**（正是本功能的目标场景！）时，
    /// `OccupancyStore` 可能**根本还没被创建** ⇒ 快照是空的 ⇒ 读到 `.unknown` ⇒
    /// 一律放行 ⇒ **功能静默不生效**，而且这条在日志上与「开关没打开」长得一样。
    ///
    /// **为什么不在启动时无条件创建**：那会给**所有**用户（包括从没开过这个开关的）
    /// 每 15s 一次 `lsof` + 一次磁盘列表刷新。开关默认关，就不该有后台代价。
    ///
    /// **调用点有两处**（缺一不可）：`applicationDidFinishLaunching` 末尾
    /// （上次开过开关 ⇒ 本次启动就绪，无需先开主窗口）、设置面板开关行 toggle 之后
    /// （刚打开开关 ⇒ 当场就绪，不必等下次启动）。
    @MainActor
    static func syncOccupancyPolling() {
        guard AppSettings.takeOverFinderEject else { return }
        _ = OccupancyStore.shared  // init 里就会 start()
    }

    // MARK: - Approval callbacks（C 函数指针，不能捕获 self）

    private static let unmountApproval: DADiskUnmountApprovalCallback = { disk, _ in
        handle(disk: disk)
    }
    private static let ejectApproval: DADiskEjectApprovalCallback = { disk, _ in
        handle(disk: disk)
    }

    /// 真正的判定 + 同步等待。**这里是 DA 同步阻塞点**：调
    /// `NSWorkspace.unmountAndEjectDevice` 的线程会等本函数返回（DA 协议）。
    ///
    /// 八段：自排除 → 解析 → 开关 → 读快照 → 判定 → 去重 → 弹窗同步等 → 回话。
    /// 顺序即优先级，**不可交换**（每一段的理由见 ``EjectHookPolicy/decide(_:isSelfInitiated:isTakeOverEnabled:occupancy:)``）。
    private static func handle(disk: DADisk) -> Unmanaged<DADissenter>? {
        // ① 自排除：发起者是我们自家（读静态标志，不碰 CFType）。
        let selfInitiated = EjectService.isHookSelfInitiated

        // ② 解析：CFType → 纯值。取不到描述 / 没有挂载路径 ⇒ 立即放行。
        //    「整个盘」的 eject 回调（访达推出的第二阶段）走的就是这一支。
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
            let request = EjectHookRequest.make(description: description)
        else {
            log(.noVolumePath, mountPath: nil)
            return nil
        }

        // ③ 开关：**在三关之前**读（关掉时本应用在链路上完全不存在）。
        let enabled = AppSettings.takeOverFinderEject

        // ④ 占用结论：读**非隔离快照**，不是 `OccupancyStore.shared`
        //    —— 后者是 `@MainActor`，在本线程上读会 SIGTRAP 崩掉整个进程。
        let occupancy = OccupancySnapshotStore.occupancy(for: request.mountPath)

        // ⑤ 判定。
        let decision = EjectHookPolicy.decide(
            request, isSelfInitiated: selfInitiated, isTakeOverEnabled: enabled,
            occupancy: occupancy)

        switch decision {
        case .passThrough(let reason):
            log(reason, mountPath: request.mountPath)
            return nil

        case .intercept(let diskInfo, let processes):
            // ⑥ 去重：**只在「决定要拦」之后**才查。
            //    顺序不可交换：`unmountAndEjectDevice` 会触发两个回调，第二个是
            //    **整个盘**的 eject（没有挂载路径）。先去重（或对无挂载路径的请求也去重）
            //    就会在访达自己推出的第二阶段把它放行掉 ⇒ 推出失败 + 访达报错框。
            //    `EjectHookRequest.make` 返回 nil 是第一道防线，「去重只在 intercept 之后」是第二道。
            //
            //    ⚠️ 去重命中（窗口内重复 / 弹窗还挂着）**一律放行、绝不再弹应用窗**：
            //    调用方（Finder）在「取消」后仍会重试 ~30s，去重窗口挡住它，避免「取消一次
            //    换来反复弹窗」。回 `kDAReturnBusy`（dissent）会让调用方弹系统框并继续重试。
            guard throttle.claim(key: diskInfo.id) else {
                log(.dedupHit, mountPath: diskInfo.id)
                return nil  // 瞬时放行，**不阻塞**、不弹窗
            }
            defer { throttle.release(key: diskInfo.id) }

            logger.notice(
                "拦截 mount=\(diskInfo.id, privacy: .public) 占用=\(processes.count, privacy: .public)")

            // ⑦ 弹窗 + 同步等用户决定（信号量；超时回退 cancel）。
            let promptStart = Date()
            let choice = waitForUserChoice(disk: diskInfo, processes: processes)
            let blocked = Date().timeIntervalSince(promptStart)
            logger.notice(
                "弹窗结束 choice=\(String(describing: choice), privacy: .public) 阻塞=\(String(format: "%.1f", blocked), privacy: .public)s mount=\(diskInfo.id, privacy: .public)"
            )

            // ⑧ 回话。
            switch EjectHookPolicy.resolve(choice) {
            case .passThrough:
                // 用户点了「取消」：**放行、不清场**。盘还占着 ⇒ 访达 unmount 失败 ⇒
                // 访达弹一次「磁盘被占用」框就停（不重试）。这是「取消 = 放弃推出」的正确落点，
                // 也是 macOS 原生的「取消推出」闭环（用户点系统框的「取消」即静默结束）。
                // 绝不能再回 `kDAReturnBusy`：dissent 会让调用方无限重试（实测）。
                return nil

            case .allow:
                // ⚠️ **先同步清场，再放行** —— 顺序不能反。
                //    若先 `return nil`，访达会立刻 unmount，而此时占用进程**还活着** ⇒
                //    `fBsyErr` ⇒ **访达弹它自己的报错框**，而「访达不弹报错框」
                //    正是本功能最大的价值点。
                //    清场之后进程已死，访达的 unmount 走完正常流程 ⇒ 无报错框。
                //    代价：用户点完之后访达还要多等 ~2.3s（清场宽限），**有界**。
                //
                //    这里**不再调** `EjectFlowController.terminateAndEject`：
                //    那会让两个推手抢同一个卷（本仓库 §8.146 记过这个坑 ——
                //    并发调 `unmountAndEjectDevice` 会把一次成功写成 `notFound`）。
                let unkillable = ProcessTerminator.clear(processes)
                logger.notice(
                    "清场 mount=\(diskInfo.id, privacy: .public) 关不掉=\(unkillable.count, privacy: .public)"
                )
                return nil
            }
        }
    }

    /// 在 DA 回调线程上**同步**等用户对弹窗做决定（最长 ``EjectHookPolicy/userDecisionTimeout`` 秒）。
    ///
    /// **为什么用 `DispatchSemaphore`**：DA approval 回调是 `@convention(c)`，
    /// 不能 `await`，且 DA 协议要求同步回话。信号量是 Apple 推荐的同步阻塞原语。
    private static func waitForUserChoice(
        disk: DiskInfo, processes: [OccupyingProcess]
    ) -> EjectAlertChoice {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ChoiceBox()

        Task { @MainActor in
            let choice = await EjectAlertPresenter.shared.present(
                .busy(disk: disk, occupying: processes))
            box.set(choice)
            semaphore.signal()
        }

        // ⚠️ `semaphore.wait` 会**阻塞当前 DA 队列线程**。这是 DA 协议要求的同步回话，
        // 没法避开 —— spike 已实证（`block_case.sh`）：阻塞期间访达静默等待、
        // **完全不弹错误框**。
        //
        // ⚠️ **但「放行之后推出会成功」只在窗口内成立**（2026-09-28 端到端实测修正）：
        // 放行时刻超过系统对 unmount 的等待上限（≈`EjectHookPolicy.systemUnmountPatience`）
        // 之后，访达**已经不等了**——清场再干净也没人接着推，盘纹丝不动。
        // 所以 `userDecisionTimeout` 必须留在那个窗口之内（见它的注释与守卫测试）。
        //
        // （这句话原写作「spike 已实证 … 放行后推出成功完成」。那个归因**没有证据**：
        //  spike 的 `block15` 只看了「访达有没有弹错框」，`out-block15.txt` 是**空的**，
        //  从没查过盘到底有没有被推出 —— 而 15s 恰好已经越过窗口。）
        let timeout = EjectHookPolicy.userDecisionTimeout
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            logger.warning("用户决策超时 \(Int(timeout))s，收掉弹窗 + 回退 cancel")
            // 收掉残留的弹窗（异步发到主 actor），回退到 cancel 路径（访达弹它自己的框）。
            Task { @MainActor in
                EjectAlertPresenter.shared.respond(.cancel)
            }
            return .cancel
        }
        return box.value ?? .cancel
    }

    /// 每次回话打**一条**带原因码的日志。
    ///
    /// **为什么必须打**：真机上「没弹窗」有三种解释（开关是关的 / 去重生效 / hook 根本没注册），
    /// 它们的表现**逐字相同**。没有原因码，排查时只能靠猜。
    private static func log(_ reason: EjectHookPassReason, mountPath: String?) {
        logger.notice(
            "放行 reason=\(reason.rawValue, privacy: .public) mount=\(mountPath ?? "-", privacy: .public)"
        )
    }
}

/// 跨闭包传值的容器（C 回调里的 `Task @MainActor` 改不到外层局部变量）。
///
/// ⚠️ `@unchecked Sendable`：写读两侧串行（写入 = 弹窗回调，读取 = DA 线程拿到结果时），
/// `NSLock` 兜底防御。
private final class ChoiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EjectAlertChoice?

    func set(_ choice: EjectAlertChoice) {
        lock.lock()
        defer { lock.unlock() }
        stored = choice
    }

    var value: EjectAlertChoice? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
