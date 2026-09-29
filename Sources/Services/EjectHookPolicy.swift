import Foundation

// MARK: - 请求（CFType → 纯值）

/// 一次 DA approval 回调里**做判定所需的全部输入**。
///
/// **为什么要有它**：`handle(disk: DADisk)` 拿不到可测的入参 —— `DADisk` 是 CFType，
/// 测试里只能真挂一块盘才能构造。把「取描述字典 → 提取字段」这一步单独做成
/// `make(description:)`，判据就能喂一个 `[String: Any]` 字面量进去。
struct EjectHookRequest: Sendable, Equatable {

    /// 挂载路径，同时也是 ``DiskInfo/id`` 与去重键。
    let mountPath: String
    /// 卷名（`/Volumes` 下显示的那个）。取不到时为空串。
    let volumeName: String
    /// BSD 设备名，如 `disk9s1`。
    let bsdName: String
    /// 设备型号，如 `SanDisk Extreme 55AE`。虚拟设备可能没有。
    let deviceModel: String?
    /// 交给 ``DiskClassifier/isExternalVolume(_:)`` 的设备属性。
    let attributes: DiskClassifier.Attributes

    /// `DADiskCopyDescription` 返回字典里的键名。
    ///
    /// ## 为什么这里写的是字面量，而不是 `kDADiskDescription*Key`
    ///
    /// 本文件是「纯值世界」：**不 import DiskArbitration**。一旦允许 import 那个框架，
    /// `DADisk` 就随手可用，判定层迟早会被掺进 CFType —— 而「把 CFType 挡在判定层之外」
    /// 正是本次要把 `handle` 一分为三的全部理由（架构文档 §1.1）。
    ///
    /// **代价与兜底**：字面量写错不会编译报错，只会让字段解析不出来 ⇒ 一律放行 ⇒
    /// 症状与「功能没生效」逐字相同。因此由
    /// `EjectHookPolicyTests.描述字典键名与系统常量逐字相同` 反向钉住：
    /// 那条测试 import DiskArbitration，逐键与 `kDADiskDescription*Key` 比较。
    enum DescriptionKey {
        static let volumePath = "DAVolumePath"
        static let volumeName = "DAVolumeName"
        static let mediaBSDName = "DAMediaBSDName"
        static let deviceModel = "DADeviceModel"
        static let deviceInternal = "DADeviceInternal"
        static let deviceProtocol = "DADeviceProtocol"
        static let volumeNetwork = "DAVolumeNetwork"
        static let mediaEjectable = "DAMediaEjectable"
    }

    /// 从 `DADiskCopyDescription` 的字典解析。
    ///
    /// - Returns: **`nil` = 取不到描述、或没有挂载路径** ⇒ 调用方必须**立即放行**。
    ///
    /// ⚠️ **「没有挂载路径」不是边界情况，是常态**：实测（`.build/probe/da_approval_spike/log-approve.txt`）
    /// `NSWorkspace.unmountAndEjectDevice` 会触发**两个**回调：
    /// ```
    /// UNMOUNT-APPROVAL  vol=SpikeVol bsd=disk9s1 whole=false mount=/Volumes/SpikeVol
    /// EJECT-APPROVAL    vol=-        bsd=disk9   whole=true  mount=-
    /// ```
    /// 第二个是**整个盘**的 eject，它**没有卷名、没有挂载路径**。若这一步不判空，
    /// 它会被当成「一块盘」走进判定与去重 —— 而它正是访达自己推出的**第二阶段**，
    /// 把它拦下来（或去重命中后 dissent）会**直接把访达的推出打断**。
    static func make(description: [String: Any]) -> EjectHookRequest? {
        let mountPath = (description[DescriptionKey.volumePath] as? URL)?.path ?? ""
        guard !mountPath.isEmpty else { return nil }

        let attributes = DiskClassifier.Attributes(
            deviceInternal: description[DescriptionKey.deviceInternal] as? Bool,
            deviceProtocol: description[DescriptionKey.deviceProtocol] as? String,
            isNetworkVolume: description[DescriptionKey.volumeNetwork] as? Bool,
            isEjectable: description[DescriptionKey.mediaEjectable] as? Bool,
            mountPath: mountPath)

        return EjectHookRequest(
            mountPath: mountPath,
            // 空串而不是 `"-"`：``DiskInfo/displayName`` 对空卷名会回落到 `bsdName`，
            // 而 `"-"` 会被当成一个真实卷名原样显示给用户。
            volumeName: description[DescriptionKey.volumeName] as? String ?? "",
            bsdName: description[DescriptionKey.mediaBSDName] as? String ?? "",
            deviceModel: description[DescriptionKey.deviceModel] as? String,
            attributes: attributes)
    }
}

// MARK: - 判定

/// 放行的**原因**。
///
/// **为什么要有原因码**：真机上「没弹窗」有两种解释（去重生效 / hook 根本没注册 / 开关是关的），
/// 它们的表现**逐字相同**。每次回话都打一条带原因码的日志，才能把「功能没生效」
/// 与「功能生效了但这次不该拦」分开。
enum EjectHookPassReason: String, Sendable, Equatable {
    /// 设置里的开关是关的。开关在**三关之前**读（关掉时本应用在链路上完全不存在）。
    case takeOverDisabled
    /// 这次推出是 DiskEjector 自己发起的（``EjectService/isHookSelfInitiated``）。
    case selfInitiated
    /// 取不到描述 / 没有挂载路径（含「整个盘」的 eject 回调）。
    case noVolumePath
    /// 不是外置可推出卷（``DiskClassifier/isExternalVolume(_:)`` 为假）。
    case notExternalVolume
    /// 占用缓存没有**明确列出**占用进程（`.none` / `.unknown` / `.needsFullDiskAccess` / `.occupied([])`）。
    case occupancyNotBlocking
    /// 去重窗口命中（同一块盘在窗口期内已弹过一次）。
    case dedupHit
    /// 同一块盘的弹窗还挂着（回调尚未返回），重复请求不重复弹。
    case inFlight
}

/// 判定结论。
enum EjectHookDecision: Sendable, Equatable {
    /// 立即回话 `nil`（放行），**不阻塞**。
    case passThrough(EjectHookPassReason)
    /// 弹占用窗 + 同步等用户决定。
    case intercept(disk: DiskInfo, processes: [OccupyingProcess])
}

/// 用户的选择 → 回调该怎么回话。
enum EjectHookResolution: Sendable, Equatable {
    /// 清场后放行（用户点了「关闭并推出」）：先终止占用进程，再 `return nil` 让访达完成推出。
    case allow
    /// 放行、不清场（用户点了「取消」）：直接 `return nil`，让访达自己 unmount ——
    /// 盘还占着 ⇒ unmount 失败 ⇒ 访达弹一次「磁盘被占用」框就停（**不重试**）。
    case passThrough
}

/// 判定层。**纯值、无单例、无 `@MainActor`、无 `DADisk`** —— 全部 P0 判据落在这里。
///
/// **为什么不抽成协议 + 注入 mock**：判据本身是纯函数，不需要替身对象；
/// 协议只会多一层「替身是否保真」的风险（本仓库 §8.30 记过这个坑）。
enum EjectHookPolicy {

    /// 系统对一次 unmount 的等待上限（秒）—— **实测值，不是猜的**。
    ///
    /// 两条**互相独立**的证据给出一致的量级：
    /// - §8.146.3：卷被占用时 `NSWorkspace.unmountAndEjectDevice` **12.5s** 才返回 `fBsyErr`；
    /// - 2026-09-28 端到端实测（`Scripts/e2e_click_takeover.sh`）：
    ///   放行时刻 12.07s ⇒ 盘推出成功；14.45s / 14.78s ⇒ **盘推不出去**（失败复现两次）。
    ///
    /// 超过它之后**访达不再等**：它既不报错、也不再重试，只是把这次推出放掉了 ——
    /// 所以「清场干净」并不足以让盘被推出，**必须有人接着推**（见 ``userDecisionTimeout``）。
    static let systemUnmountPatience: TimeInterval = 12.5

    /// 用户决策硬超时（秒）。
    ///
    /// ## 为什么是 8（2026-09-28 复核 §6-Q3 后从 60 下调）
    ///
    /// 放行时刻 = **用户决策 + 清场宽限**（`ProcessTerminator.termGrace + killGrace` = 2.3s），
    /// 而它必须落在 ``systemUnmountPatience`` 之内：产品在 `.allow` 里是
    /// 「清场 → `return nil`，让**访达**去 unmount」——
    /// 一旦超过系统的等待上限，**访达已经不等了**，清场再干净也没人接着推
    /// ⇒ 用户点的是「关闭并推出」，结果是**盘纹丝不动**（表现就是「点了没反应」）。
    ///
    /// 实测（同一台机器、同一块盘，只改「弹窗出现后多久点下去」）：
    ///
    /// | 阻塞 | 放行时刻 | 结果 |
    /// |---|---|---|
    /// | 3.1s | ~5.4s | ✅ 推出成功 |
    /// | 9.8s | 12.07s | ✅ 推出成功 |
    /// | 12.2s | 14.45s | ❌ 盘还在 |
    /// | 12.5s | 14.78s | ❌ 盘还在（**可复现**） |
    ///
    /// ⇒ 上限 `12.5 − 2.3 = 10.2`，取 **8**（留 2.2s 余量）。
    /// ⚠️ 有守卫测试盯着这条不等式（`用户决策超时必须留在系统等待上限之内`）——
    /// 改大这个值会让「点了没反应」重新出现。
    ///
    /// ⚠️ 架构文档 §6-Q3 原判据是「访达自己放弃**并弹框**」⇒ 下调到 `T_patience − 5`；
    /// 复核结果是**不弹框**、但**放弃 unmount** —— 同样触发下调（`12.5 − 5 = 7.5 ≈ 8`）。
    ///
    /// ⚠️ 超时的收场是**返回 `.cancel`**（→ 放行，访达 unmount 失败后弹它自己的「占用中」框），
    /// 盘保持挂载 —— 这是自洽的：用户没确认强推，就该像没接管一样。
    static let userDecisionTimeout: TimeInterval = 8

    /// 同盘去重窗口（秒）。
    ///
    /// **依据**（真实日志 + spike，2026-09-29 复测）：调用方（Finder / osascript）
    /// 在收到回话后重试的间隔稳定在 ~2.16s，一轮重试跨度 ≥ 12.5s；且用户点系统框
    /// 「取消」才会让调用方停止。取 30s 覆盖一整轮重试并留余量。
    static let dedupWindow: TimeInterval = 30

    /// 三关 + 开关 → 结论。**顺序即优先级，不可交换**。
    ///
    /// 顺序与理由：
    /// 1. `isTakeOverEnabled` —— 开关在三关之前读；关掉时本应用在链路上**完全不存在**，
    ///    连日志噪音都不该有；
    /// 2. `isSelfInitiated` —— 自排除。**必须早于任何查缓存/弹窗**：漏了它 = 自己拦自己
    ///    = 永久推不出（spike 实证）；
    /// 3. `isExternalVolume` —— 判错会把系统盘/网络卷交给用户（``DiskClassifier`` 的注释）；
    /// 4. `occupancy` —— **只有明确列出占用进程才拦**（`.occupied([])` 也放行）。
    static func decide(
        _ request: EjectHookRequest,
        isSelfInitiated: Bool,
        isTakeOverEnabled: Bool,
        occupancy: OccupancyResult
    ) -> EjectHookDecision {
        guard isTakeOverEnabled else { return .passThrough(.takeOverDisabled) }
        guard !isSelfInitiated else { return .passThrough(.selfInitiated) }
        guard DiskClassifier.isExternalVolume(request.attributes) else {
            return .passThrough(.notExternalVolume)
        }
        guard let processes = shouldBlock(occupancy) else {
            return .passThrough(.occupancyNotBlocking)
        }

        // 弹窗只需要盘名与图标，容量等字段不参与 —— 给 0 而不是去读磁盘列表
        // （读列表要跨 actor，而这里在 DA 回调线程上）。
        let disk = DiskInfo(
            id: request.mountPath,
            bsdName: request.bsdName,
            volumeName: request.volumeName,
            mountPath: request.mountPath,
            totalBytes: 0,
            usedBytes: 0,
            freeBytes: 0,
            deviceProtocol: request.attributes.deviceProtocol,
            deviceModel: request.deviceModel)
        return .intercept(disk: disk, processes: processes)
    }

    /// 占用结论里**该拦的进程列表**；`nil` = 不拦。
    ///
    /// 与 `EjectUI.preemptivelyOccupied` 同款判定：`.none` = 确认无占用；
    /// `.unknown` = 还没测出来（让系统自己判）；`.needsFullDiskAccess` = 用户没授权；
    /// `.occupied([])` = 系统说忙但列不出具体程序（弹空列表窗无意义）。
    ///
    /// **抽成独立函数**是为了让「四种放行」各自能被一条单测钉住 —— 写在 `decide` 的
    /// `guard case` 里时，只有「都放行」这一个整体行为可断言。
    static func shouldBlock(_ occupancy: OccupancyResult) -> [OccupyingProcess]? {
        guard case .occupied(let processes) = occupancy, !processes.isEmpty else { return nil }
        return processes
    }

    /// 用户的选择 → 回调该怎么回话。
    ///
    /// `.closeAndEject` ⇒ `.allow`（清场后放行，由访达完成推出）。
    /// 其余（`cancel` / `dismiss` / `viewLog` / …）⇒ `.passThrough`（放行、不清场）。
    ///
    /// ## 为什么「取消」是放行、不是 dissent（2026-09-29 实测修正）
    ///
    /// 早期实现让「取消」走 `.dissentBusy`（`kDAReturnBusy`）。实测（真实日志 +
    /// spike）证明：**dissent 会让调用方（Finder / osascript）重试并弹「未能推出」框**，
    /// 于是「取消」之后应用弹窗反复弹出、系统框反复出现。
    ///
    /// 放行（`return nil`）让调用方 unmount 失败后弹**「磁盘被占用」框**（带「取消」/
    /// 「强制推出」）—— 这才是 macOS 原生、用户熟悉的「取消推出」闭环：用户点系统框的
    /// 「取消」即静默结束。放行**也会**触发调用方重试（真实日志已证），但那一层由
    /// ``EjectHookThrottle`` 的去重窗口挡住 —— 窗口内重复回调直接放行、不再弹应用窗。
    ///
    /// ⚠️ **`.dismiss` 等值不可能从 busy 弹窗出来**，兜底走放行而不是 dissent：
    /// dissent 会退回「弹系统框 + 反复弹应用窗」的坑；放行不清场则退化成「系统自己判」，
    /// 与「用户没说要推出」自洽（放行 ≠ 替用户推出，只是不再拦）。
    static func resolve(_ choice: EjectAlertChoice) -> EjectHookResolution {
        choice == .closeAndEject ? .allow : .passThrough
    }
}

// MARK: - 去重

/// 同盘去重：**窗口期内同一块盘至多弹一次窗**。
///
/// ## 为什么必须用「时间窗口」，而不是只靠「inFlight」（2026-09-29 实测修正）
///
/// 真实日志（用户真机操作 `wenbo-data`）铁证：点「取消」或「超时」后，调用方
/// （Finder / osascript）会**持续重试** —— 间隔 ~2.2s，直到用户点系统框的「取消」
/// 让调用方停止这次推出请求。若不去重，「取消」一次会换来**反复弹应用窗 + 反复系统框**
/// 的无限循环（这正是 2026-09-29 用户报的 bug）。
///
/// 而「inFlight」只覆盖「弹窗还挂着的极短时间」，弹窗一收掉（`release`）就失效，
/// 挡不住调用方随后 ~30s 的重试风暴。所以必须有一个**跨「弹窗结束」的窗口**：
/// 窗口起点 = 上一次弹窗结束的时刻，长度覆盖调用方一轮完整重试。
///
/// ## 为什么「命中窗口」要放行而不是 dissent
///
/// dissent（`kDAReturnBusy`）会让调用方弹「未能推出」框**并继续重试**；放行
/// （`return nil`）让调用方 unmount 失败后弹「磁盘被占用」框，用户点该框的「取消」
/// 即静默结束。放行才是「取消 = 放弃推出」的正确落点（见 ``EjectHookPolicy/resolve``）。
///
/// ## 为什么是值类型 + 显式 `now`
///
/// 时间必须**从外面传**，否则「窗口边界」永远只能靠 `sleep` 测（既慢又不确定）。
struct EjectHookThrottle: Sendable, Equatable {

    /// 窗口长度（秒）。
    var window: TimeInterval

    /// 键 = **挂载路径**（= ``DiskInfo/id``），值 = 上一次弹窗**结束**的时刻。
    ///
    /// **为什么用挂载路径**：``DiskInfo/id`` 就是它，``OccupancyStore/results`` 的键也是它。
    /// 用 `volumeName` 会让两块同名的盘互相去重；用 `bsdName` 会在拔插后复用。
    var lastPromptEnd: [String: Date] = [:]

    /// 正在弹窗（回调尚未返回）的盘。防御「同一块盘的第二个请求在我们还没返回时到达」。
    var inFlight: Set<String> = []

    /// 尝试占用「这块盘的弹窗名额」。
    /// - Returns: `true` = 可以弹（**同时登记 `inFlight`**）；`false` = 命中去重。
    mutating func claim(key: String, now: Date) -> Bool {
        guard !inFlight.contains(key) else { return false }
        guard !isSuppressed(key: key, now: now) else { return false }
        inFlight.insert(key)
        return true
    }

    /// 弹窗结束（无论用户点了什么）：解除 `inFlight`，并把窗口起点钉在 `now`。
    mutating func release(key: String, at now: Date) {
        inFlight.remove(key)
        lastPromptEnd[key] = now
    }

    /// 纯查询（不写状态），供日志与单测读。
    func isSuppressed(key: String, now: Date) -> Bool {
        guard let end = lastPromptEnd[key] else { return false }
        return now.timeIntervalSince(end) < window
    }
}

/// ``EjectHookThrottle`` 的线程安全外壳。
///
/// **为什么需要锁**：`DASessionSetDispatchQueue` 用的是 `.concurrent` 队列，
/// 两个 approval 回调**理论上可以并发**进入（``EjectService/isHookSelfInitiated``
/// 用 `NSLock` 是同一个理由）。值类型本身没有并发保护。
///
/// **为什么 `now` 可注入**：单测要能把「窗口边界」钉在确定的时刻上。
final class EjectHookThrottleStore: @unchecked Sendable {

    private let lock = NSLock()
    private var value: EjectHookThrottle
    private let now: () -> Date

    init(window: TimeInterval = EjectHookPolicy.dedupWindow, now: @escaping () -> Date = { Date() }) {
        self.value = EjectHookThrottle(window: window)
        self.now = now
    }

    /// - Returns: `true` = 可以弹窗；`false` = 命中去重（调用方**立即**回话，不阻塞）。
    func claim(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.claim(key: key, now: now())
    }

    /// 弹窗结束：窗口从此刻起算。
    func release(key: String) {
        lock.lock()
        defer { lock.unlock() }
        value.release(key: key, at: now())
    }
}
