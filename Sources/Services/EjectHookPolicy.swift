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
    /// 放行（由访达完成推出）。调用方**先**同步清场再放行。
    case allow
    /// 回 `kDAReturnBusy`（退回现状：访达弹它自己的报错框）。
    case dissentBusy
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
    /// ⚠️ 超时的收场是**返回 `.cancel`**（→ dissent，访达弹它自己的「占用中」框），
    /// 盘保持挂载 —— 这是自洽的：用户没确认强推，就该像没接管一样。
    static let userDecisionTimeout: TimeInterval = 8

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
    /// `.closeAndEject` ⇒ `.allow`（放行，由访达完成推出；调用方**先**同步清场）。
    /// 其余（`cancel` / `dismiss` / `viewLog` / …）⇒ `.dissentBusy`（退回现状）。
    ///
    /// ⚠️ **`.dismiss` 等值不可能从 busy 弹窗出来**，兜底走 dissent 是为了与
    /// 「用户没说要推出」这个语义一致 —— 放行等于**替用户做了推出这个破坏性决定**。
    static func resolve(_ choice: EjectAlertChoice) -> EjectHookResolution {
        choice == .closeAndEject ? .allow : .dissentBusy
    }
}

// MARK: - 去重

/// 同盘去重：**同一块盘的弹窗还挂着时，重复到达的请求不重复弹**。
///
/// ## 为什么只做「inFlight」去重，不做「时间窗口」去重
///
/// 早期版本有一个 `dedupWindow = 30s` 的时间窗口，理由是「dissent 之后访达会以
/// ~2.16s 间隔重试 7 次（实测 `log-finder-dissent-busy.txt`）」。**这条依据是错的**：
/// 那 7 次重试来自 `osascript -e 'eject'` 这个**脚本**——脚本收到 `fBsyErr` 后
/// 自己循环重试。而真实的推出请求（Finder 界面点推出、`NSWorkspace.unmountAndEjectDevice`）
/// 在 dissent 后**只报一次 `fBsyErr`（OSStatus -47）就退出，绝不自动重试**
/// （2026-09-28 实测：`ejecter.swift` 一次请求 → watcher 只收到 1 次回调）。
///
/// 时间窗口把「用户主动的第二次点击」误判成「重试风暴」吞掉，正是
/// 「取消后再点推出弹系统框」这个 bug 的根源。删掉它后，每次点击都重新弹窗。
///
/// 真正需要防的是**同一块盘弹窗还挂着时**重复到达的请求（`inFlight` 覆盖）：
/// `unmountAndEjectDevice` 会触发 unmount + eject 两个回调，其中第二个是「整个盘」、
/// 无挂载路径，已被 ``EjectHookRequest/make`` 判 nil 放行；`inFlight` 兜底的是
/// 并发/异常时序下同一块盘的回调重叠。
struct EjectHookThrottle: Sendable, Equatable {

    /// 正在弹窗（回调尚未返回）的盘。
    /// 防御「同一块盘的第二个请求在我们还没返回时到达」。
    var inFlight: Set<String> = []

    /// 尝试占用「这块盘的弹窗名额」。
    /// - Returns: `true` = 可以弹（**同时登记 `inFlight`**）；`false` = 弹窗已挂着。
    mutating func claim(key: String) -> Bool {
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        return true
    }

    /// 弹窗结束（无论用户点了什么）：解除 `inFlight`，立即可再弹。
    mutating func release(key: String) {
        inFlight.remove(key)
    }
}

/// ``EjectHookThrottle`` 的线程安全外壳。
///
/// **为什么需要锁**：`DASessionSetDispatchQueue` 用的是 `.concurrent` 队列，
/// 两个 approval 回调**理论上可以并发**进入（``EjectService/isHookSelfInitiated``
/// 用 `NSLock` 是同一个理由）。值类型本身没有并发保护。
final class EjectHookThrottleStore: @unchecked Sendable {

    private let lock = NSLock()
    private var value = EjectHookThrottle()

    /// - Returns: `true` = 可以弹窗；`false` = 弹窗已挂着（调用方**立即**回话，不阻塞）。
    func claim(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.claim(key: key)
    }

    /// 弹窗结束：解除 `inFlight`，立即可再弹。
    func release(key: String) {
        lock.lock()
        defer { lock.unlock() }
        value.release(key: key)
    }
}
