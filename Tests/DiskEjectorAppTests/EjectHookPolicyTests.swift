import DiskArbitration
import Foundation
import Testing

@testable import DiskEjectorApp

// MARK: - 夹具

/// 造一个占用进程（只有 pid 与名字参与判定）。
private func makeProcess(pid: Int32, name: String = "tail") -> OccupyingProcess {
    OccupyingProcess(pid: pid, processName: name, path: "/Volumes/SpikeVol/keep.txt")
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

/// 造一份 `DADiskCopyDescription` 形状的描述字典。
///
/// 默认是**外置 USB 盘**（`deviceInternal = false` 是唯一可靠的「外置」信号，
/// 见 ``DiskClassifier`` 的实测注释）。
private func makeDescription(
    mountPath: String = "/Volumes/SpikeVol",
    volumeName: String = "SpikeVol",
    bsdName: String = "disk9s1",
    deviceModel: String? = "SanDisk Extreme 55AE",
    deviceInternal: Bool? = false
) -> [String: Any] {
    var d: [String: Any] = [
        EjectHookRequest.DescriptionKey.volumePath: URL(fileURLWithPath: mountPath),
        EjectHookRequest.DescriptionKey.volumeName: volumeName,
        EjectHookRequest.DescriptionKey.mediaBSDName: bsdName,
        EjectHookRequest.DescriptionKey.deviceProtocol: "USB",
        EjectHookRequest.DescriptionKey.volumeNetwork: false,
        EjectHookRequest.DescriptionKey.mediaEjectable: false,
    ]
    if let deviceModel { d[EjectHookRequest.DescriptionKey.deviceModel] = deviceModel }
    if let deviceInternal { d[EjectHookRequest.DescriptionKey.deviceInternal] = deviceInternal }
    return d
}

private func makeRequest(mountPath: String = "/Volumes/SpikeVol") throws -> EjectHookRequest {
    try #require(EjectHookRequest.make(description: makeDescription(mountPath: mountPath)))
}

/// 记录「谁在第几步收到了哪个信号」的替身 —— 让 ``ProcessTerminator`` 能**完全离线**测。
///
/// `failureErrno` 里登记过的 pid，其 `kill` 会返回 -1 并**真的把 `errno` 设成那个值**
/// （被测代码靠 `errno` 区分 `ESRCH` 与 `EPERM`，替身不设就等于没测）。
private final class KillRecorder: @unchecked Sendable {
    private(set) var calls: [(pid: Int32, sig: Int32)] = []
    var failureErrno: [Int32: Int32] = [:]

    func kill(_ pid: Int32, _ sig: Int32) -> Int32 {
        calls.append((pid, sig))
        if let e = failureErrno[pid] {
            errno = e
            return -1
        }
        return 0
    }

    func signals(to pid: Int32) -> [Int32] { calls.filter { $0.pid == pid }.map(\.sig) }
}

// MARK: - 判定层

/// 「接管访达的推出」判定层的判据。
///
/// **为什么这些判据落在这里而不是真机**：`handle(disk: DADisk)` 是 `@convention(c)`、
/// 不能 await、依赖 CFType 与 `@MainActor` 单例 —— 它**一条都测不了**。
/// 所以判定被抽成纯函数（``EjectHookPolicy``），本文件喂普通 Swift 值就能断言。
@Suite("接管访达推出的判定层")
struct EjectHookPolicyTests {

    // MARK: 描述字典的键名（反向锚）

    /// ``EjectHookRequest/DescriptionKey`` 里的字面量必须与系统常量**逐字相同**。
    ///
    /// **为什么需要这条**：`EjectHookPolicy.swift` 为了保持「纯值世界」**不 import
    /// DiskArbitration**（一旦允许 import，`DADisk` 就随手可用，判定层迟早被掺进 CFType），
    /// 所以键名只能是字面量。而字面量写错**不会编译报错**，只会让字段解析不出来 ⇒
    /// 一律放行 ⇒ 症状与「功能没生效」逐字相同。
    /// 这条测试 import DiskArbitration，把那份字面量钉回 Apple 的头文件。
    @Test func 描述字典键名与系统常量逐字相同() {
        let pairs: [(String, CFString)] = [
            (EjectHookRequest.DescriptionKey.volumePath, kDADiskDescriptionVolumePathKey),
            (EjectHookRequest.DescriptionKey.volumeName, kDADiskDescriptionVolumeNameKey),
            (EjectHookRequest.DescriptionKey.mediaBSDName, kDADiskDescriptionMediaBSDNameKey),
            (EjectHookRequest.DescriptionKey.deviceModel, kDADiskDescriptionDeviceModelKey),
            (EjectHookRequest.DescriptionKey.deviceInternal, kDADiskDescriptionDeviceInternalKey),
            (EjectHookRequest.DescriptionKey.deviceProtocol, kDADiskDescriptionDeviceProtocolKey),
            (EjectHookRequest.DescriptionKey.volumeNetwork, kDADiskDescriptionVolumeNetworkKey),
            (EjectHookRequest.DescriptionKey.mediaEjectable, kDADiskDescriptionMediaEjectableKey),
        ]
        for (ours, system) in pairs {
            #expect(
                ours == (system as String),
                "键名对不上：我们写「\(ours)」，系统常量是「\(system as String)」—— 写错会让该字段永远解析不出来（静默失效）"
            )
        }
    }

    // MARK: 开关（第 1 关）

    @Test func 开关关时一律放行即使盘被占用() throws {
        let req = try makeRequest()
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: false, isTakeOverEnabled: false,
            occupancy: .occupied([makeProcess(pid: 42)]))
        #expect(decision == .passThrough(.takeOverDisabled))
    }

    /// 开关在**三关之前**读：两个条件同时为真时，原因码必须是 `takeOverDisabled`。
    ///
    /// **为什么顺序可断言**：关掉开关时本应用在链路上应当**完全不存在**（连日志噪音都不该有）。
    /// 若先判自排除，日志里会出现 `reason=selfInitiated` —— 而那是「我们在链路上」的证据。
    @Test func 开关关优先于自排除() throws {
        let req = try makeRequest()
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: true, isTakeOverEnabled: false,
            occupancy: .occupied([makeProcess(pid: 42)]))
        #expect(decision == .passThrough(.takeOverDisabled))
    }

    // MARK: 自排除（第 2 关）

    /// 自排除为真 ⇒ 放行，**且不看占用缓存**。
    ///
    /// 用「即使传 `.occupied([p])` 也放行」来证明后半句：漏了自排除 = 自己拦自己
    /// = 永久推不出（spike 实证）。
    @Test func 自排除时放行且不读占用缓存() throws {
        let req = try makeRequest()
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: true, isTakeOverEnabled: true,
            occupancy: .occupied([makeProcess(pid: 42)]))
        #expect(decision == .passThrough(.selfInitiated))
    }

    // MARK: 外置盘（第 3 关）

    @Test func 内置盘放行() throws {
        let req = try #require(
            EjectHookRequest.make(description: makeDescription(deviceInternal: true)))
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: false, isTakeOverEnabled: true,
            occupancy: .occupied([makeProcess(pid: 42)]))
        #expect(decision == .passThrough(.notExternalVolume))
    }

    @Test func 网络卷放行() throws {
        var d = makeDescription()
        d[EjectHookRequest.DescriptionKey.volumeNetwork] = true
        d[EjectHookRequest.DescriptionKey.deviceProtocol] = "SMB"
        let req = try #require(EjectHookRequest.make(description: d))
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: false, isTakeOverEnabled: true,
            occupancy: .occupied([makeProcess(pid: 42)]))
        #expect(decision == .passThrough(.notExternalVolume))
    }

    // MARK: 占用缓存（第 4 关）

    /// 四种「不明确」的占用结论**都必须放行**，各一条。
    ///
    /// **为什么拆成参数化而不是写在 `decide` 的 `guard case` 里**：写在一起时
    /// 只有「都放行」这一个整体行为可断言 —— 其中任何一种被误判成「要拦」，
    /// 都会表现为同一个失败。分开之后每种各有一条判据。
    ///
    /// ⚠️ `.occupied([])` 也在内：系统说忙但列不出具体程序（未授权完全磁盘访问时常见），
    /// 弹一个**空列表窗**对用户没有任何信息量。
    @Test(arguments: [OccupancyResult.none, .unknown, .needsFullDiskAccess, .occupied([])])
    func 占用不明确时放行(_ occupancy: OccupancyResult) throws {
        let req = try makeRequest()
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: false, isTakeOverEnabled: true, occupancy: occupancy)
        #expect(decision == .passThrough(.occupancyNotBlocking))
    }

    @Test func 明确列出占用进程时拦截并带上挂载路径() throws {
        let req = try makeRequest()
        let process = makeProcess(pid: 42, name: "IMVIDEO")
        let decision = EjectHookPolicy.decide(
            req, isSelfInitiated: false, isTakeOverEnabled: true, occupancy: .occupied([process]))
        guard case .intercept(let disk, let processes) = decision else {
            Issue.record("应当拦截，实际是 \(decision)")
            return
        }
        // 去重键就是 `DiskInfo.id` —— 它必须是**挂载路径**（不是卷名、不是 bsdName）。
        #expect(disk.id == req.mountPath)
        #expect(disk.mountPath == req.mountPath)
        #expect(disk.volumeName == "SpikeVol")
        #expect(processes == [process])
    }

    // MARK: 解析（CFType → 纯值）

    /// 没有 `VolumePath` ⇒ `nil`（调用方必须立即放行）。
    ///
    /// ⚠️ **这不是边界情况，是常态**：实测 `unmountAndEjectDevice` 会触发**两个**回调，
    /// 第二个是**整个盘**的 eject（没有卷名、没有挂载路径）。若这里不返回 nil，
    /// 访达自己推出的**第二阶段**会被我们拦下来或去重掉 ⇒ 推出失败 + 访达报错框。
    ///
    /// ⚠️ **造「空路径 URL」必须用 `URL(string: "file://")`，不能用
    /// `URL(fileURLWithPath: "")`** —— 后者实测（`.build/probe/t01t02/urlprobe.swift`）
    /// 的 `path` 是**当前工作目录**，不是空串。用它来写这条断言，
    /// 测的就变成了「cwd 是不是合法挂载点」（答案是真），断言必红而原因看不出来。
    @Test func 没有挂载路径一律解析失败() throws {
        var d = makeDescription()
        d[EjectHookRequest.DescriptionKey.volumePath] = nil
        #expect(EjectHookRequest.make(description: d) == nil)

        let emptyPathURL = try #require(URL(string: "file://"))
        #expect(emptyPathURL.path.isEmpty, "夹具本身就不成立 —— 它不再是「空路径 URL」了")
        d[EjectHookRequest.DescriptionKey.volumePath] = emptyPathURL
        #expect(EjectHookRequest.make(description: d) == nil)

        // 值不是 URL（DA 理论上不会这样给，但类型不对时必须走同一条放行路径，
        // 而不是崩掉或把 nil 当成一块盘）。
        d[EjectHookRequest.DescriptionKey.volumePath] = "/Volumes/SpikeVol"
        #expect(EjectHookRequest.make(description: d) == nil)
    }

    @Test func 有挂载路径时五个字段逐个正确() throws {
        let req = try #require(
            EjectHookRequest.make(
                description: makeDescription(
                    mountPath: "/Volumes/T7", volumeName: "T7", bsdName: "disk4s2",
                    deviceModel: "Samsung T7", deviceInternal: false)))
        #expect(req.mountPath == "/Volumes/T7")
        #expect(req.volumeName == "T7")
        #expect(req.bsdName == "disk4s2")
        #expect(req.deviceModel == "Samsung T7")
        #expect(req.attributes.deviceInternal == false)
        #expect(req.attributes.deviceProtocol == "USB")
        #expect(req.attributes.isNetworkVolume == false)
        #expect(req.attributes.mountPath == "/Volumes/T7")
    }

    /// 卷名缺失时是**空串**，不是 `"-"` —— ``DiskInfo/displayName`` 对空卷名会回落到
    /// `bsdName`，而 `"-"` 会被当成一个真实卷名原样显示给用户。
    @Test func 卷名缺失时回落为空串而不是破折号() throws {
        var d = makeDescription()
        d[EjectHookRequest.DescriptionKey.volumeName] = nil
        let req = try #require(EjectHookRequest.make(description: d))
        #expect(req.volumeName.isEmpty)
        let disk = makeDisk("/Volumes/SpikeVol")
        #expect(disk.displayName == "SpikeVol")  // 证明 displayName 的回落路径确实存在
    }

    // MARK: 用户选择 → 回话

    @Test func 只有关闭并推出才放行() {
        #expect(EjectHookPolicy.resolve(.closeAndEject) == .allow)
        for choice: EjectAlertChoice in [.cancel, .dismiss, .viewLog, .skipVersion, .installAndRestart] {
            #expect(
                EjectHookPolicy.resolve(choice) == .dissentBusy,
                "「\(choice)」不是「我要推出」的意思 —— 放行等于**替用户做了推出这个破坏性决定**")
        }
    }
}

// MARK: - 同盘去重

@Suite("接管访达推出的同盘去重")
struct EjectHookThrottleTests {

    private let key = "/Volumes/SpikeVol"

    /// ⚠️ `claim` / `release` 是 `mutating`，而 `#expect` 会把表达式包进一个
    /// **参数不可变**的闭包 ⇒ 不能直接写在 `#expect(...)` 里（会报
    /// `cannot use mutating member on immutable value`）。先调、再断言。

    @Test func 弹窗期间同一块盘的第二个请求被挡下() {
        var throttle = EjectHookThrottle()
        let first = throttle.claim(key: key)
        let second = throttle.claim(key: key)
        let third = throttle.claim(key: key)
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    /// 弹窗结束（`release`）后**立即**可以再弹 —— 去重不设时间窗口。
    ///
    /// 这条是本 bug 的**核心守卫**：早期版本的 `dedupWindow`（30s 时间窗口）会
    /// 在 `release` 之后继续抑制同一块盘，导致「用户取消后再点推出」被静默吞掉
    /// （直接 dissent → 访达弹系统框）。删掉时间窗口后，`release` 一解除就恢复可弹。
    @Test func 弹窗结束后立即可再弹不去重() {
        var throttle = EjectHookThrottle()
        let first = throttle.claim(key: key)
        #expect(first)
        throttle.release(key: key)

        let again = throttle.claim(key: key)
        #expect(again)
    }

    /// 去重键必须是**挂载路径** —— 一块盘弹过窗，不该影响另一块盘。
    ///
    /// 用 `volumeName` 会让两块同名的盘互相去重；用 `bsdName` 会在拔插后复用。
    @Test func 去重按挂载路径互相隔离() {
        var throttle = EjectHookThrottle()
        let a = throttle.claim(key: "/Volumes/A")
        #expect(a)
        let b = throttle.claim(key: "/Volumes/B")
        #expect(b)
    }

    /// 同一块盘弹窗挂起期间，其它盘**不受影响**（inFlight 是按盘隔离的）。
    @Test func 一块盘弹窗期间另一块盘仍可弹() {
        var throttle = EjectHookThrottle()
        let a = throttle.claim(key: "/Volumes/A")
        #expect(a)
        let b = throttle.claim(key: "/Volumes/B")
        #expect(b)
        let aAgain = throttle.claim(key: "/Volumes/A")
        #expect(!aAgain)
    }

    @Test func 线程安全外壳与值类型口径一致() {
        let store = EjectHookThrottleStore()
        let first = store.claim(key: "/Volumes/A")
        #expect(first)
        let second = store.claim(key: "/Volumes/A")
        #expect(!second)
        store.release(key: "/Volumes/A")
        let third = store.claim(key: "/Volumes/A")
        #expect(third)
    }
}

// MARK: - 同步清场器

@Suite("同步清场器")
struct ProcessTerminatorTests {

    /// 全部 `SIGTERM` 送达、且复检已退出 ⇒ **不发** `SIGKILL`。
    ///
    /// **为什么这条要单独钉**：无条件补一发 `SIGKILL` 也能「让盘推出来」，
    /// 但它会让**已经正常退出的**应用也吃一发不可捕获的信号 —— 那正是
    /// 「先 SIGTERM 让它存盘」这个设计要避免的事。
    @Test func 全部正常退出时不补发SIGKILL() {
        let recorder = KillRecorder()
        let p1 = makeProcess(pid: 101)
        let p2 = makeProcess(pid: 102)
        let remaining = ProcessTerminator.clear(
            [p1, p2], termGrace: 0, killGrace: 0,
            kill: recorder.kill, isAlive: { _ in false }, sleep: { _ in })
        #expect(remaining.isEmpty)
        #expect(recorder.calls.map(\.sig) == [SIGTERM, SIGTERM])
    }

    /// `EPERM`（无权终止）⇒ 计入返回，**且仍要升级 `SIGKILL`**。
    @Test func 无权终止时计入并升级SIGKILL() {
        let recorder = KillRecorder()
        recorder.failureErrno = [101: EPERM]
        let p1 = makeProcess(pid: 101)
        let remaining = ProcessTerminator.clear(
            [p1], termGrace: 0, killGrace: 0,
            kill: recorder.kill, isAlive: { _ in false }, sleep: { _ in })
        #expect(remaining == [p1])
        #expect(recorder.signals(to: 101) == [SIGTERM, SIGKILL])
    }

    /// `ESRCH`（进程已不存在）⇒ **不计入**「关不掉」。
    @Test func 进程已消失时不计入关不掉() {
        let recorder = KillRecorder()
        recorder.failureErrno = [101: ESRCH]
        let p1 = makeProcess(pid: 101)
        let remaining = ProcessTerminator.clear(
            [p1], termGrace: 0, killGrace: 0,
            kill: recorder.kill, isAlive: { _ in false }, sleep: { _ in })
        #expect(remaining.isEmpty)
        #expect(recorder.signals(to: 101) == [SIGTERM])
    }

    /// 收到 `SIGTERM` 却**忽略**它的进程（导出中的播放器等）必须被升级 `SIGKILL`。
    ///
    /// **为什么这条是本文件最重要的一条**：调用方（``EjectHookService``）清场之后会
    /// **放行**访达自己的 unmount。此时若还有进程活着，访达会拿到 `fBsyErr` 并
    /// **弹它自己的报错框** —— 而「访达不弹报错框」正是本功能最大的价值点。
    /// 只对「`SIGTERM` 都没送达」的进程升级是不够的：忽略 `SIGTERM` 的那类恰恰最常见。
    @Test func 忽略SIGTERM的进程被升级SIGKILL() {
        let recorder = KillRecorder()
        let p1 = makeProcess(pid: 101)
        let remaining = ProcessTerminator.clear(
            [p1], termGrace: 0, killGrace: 0,
            kill: recorder.kill, isAlive: { _ in true }, sleep: { _ in })
        #expect(recorder.signals(to: 101) == [SIGTERM, SIGKILL])
        #expect(remaining == [p1])
    }

    /// **不自杀**：自身 PID 不发任何信号，且计入「关不掉」交回调用方。
    @Test func 自身PID不发信号但计入关不掉() {
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        let myself = makeProcess(pid: me, name: "DiskEjector")
        let recorder = KillRecorder()
        let remaining = ProcessTerminator.clear(
            [myself], termGrace: 0, killGrace: 0,
            kill: recorder.kill, isAlive: { _ in true }, sleep: { _ in })
        #expect(remaining == [myself])
        #expect(recorder.calls.isEmpty, "对自身 PID 发了信号 —— 会出现「本应用把自己杀掉」")
    }

    @Test func 空列表不阻塞也不发信号() {
        let recorder = KillRecorder()
        let remaining = ProcessTerminator.clear(
            [], termGrace: 0, killGrace: 0,
            kill: recorder.kill, isAlive: { _ in true }, sleep: { _ in })
        #expect(remaining.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    /// 单相位原语的口径：`ESRCH` 不计入、`EPERM` 计入、自身 PID 不发信号。
    ///
    /// 这条同时是 ``EjectFlowController`` 那条路的**行为契约**（它现在也走这个函数）——
    /// 两条路共用一份实现，所以这里的口径就是两处的口径。
    @Test func 单相位信号的口径() {
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        let recorder = KillRecorder()
        recorder.failureErrno = [201: ESRCH, 202: EPERM]
        let gone = makeProcess(pid: 201)
        let denied = makeProcess(pid: 202)
        let ok = makeProcess(pid: 203)
        let myself = makeProcess(pid: me)
        let unkillable = ProcessTerminator.signal(
            [gone, denied, ok, myself], signal: SIGTERM, selfPid: me, kill: recorder.kill)
        #expect(unkillable == [denied, myself])
        #expect(recorder.calls.map(\.pid) == [201, 202, 203])
    }
}

// MARK: - 跨线程只读快照

@Suite("占用结论的跨线程只读快照")
struct OccupancySnapshotStoreTests {

    /// **读不到 ⇒ `.unknown`，绝不是 `.none`。**
    ///
    /// `.none` 是「已确认没有占用」—— 兜成它会把「还没测出来」变成放行，
    /// 那是本应用最不能犯的错误（``DiskRowState`` 的注释）。
    /// 而这两种失败在真机上**逐字相同**（都是「没弹窗」）。
    @Test func 读不到时兜unknown而不是none() {
        OccupancySnapshotStore.update([:])
        #expect(OccupancySnapshotStore.occupancy(for: "/Volumes/NeverSeen") == .unknown)
        #expect(OccupancySnapshotStore.occupancy(for: "/Volumes/NeverSeen") != .none)
    }

    @Test func 写入之后能按挂载路径读到() {
        let process = makeProcess(pid: 9)
        OccupancySnapshotStore.update(["/Volumes/A": .occupied([process])])
        #expect(OccupancySnapshotStore.occupancy(for: "/Volumes/A") == .occupied([process]))
        #expect(OccupancySnapshotStore.occupancy(for: "/Volumes/B") == .unknown)
    }

    /// `update` 是**整体替换**：上一轮有、这一轮没有的键必须消失。
    ///
    /// 与 ``OccupancyStore/results`` 同口径 —— 若只做逐键合并，
    /// 拔掉的盘会留着旧结论，下次同名卷再插上来会先显示一段别人的旧结论。
    @Test func 更新是整体替换而不是合并() {
        OccupancySnapshotStore.update([
            "/Volumes/A": .occupied([makeProcess(pid: 1)]),
            "/Volumes/B": .none,
        ])
        OccupancySnapshotStore.update(["/Volumes/B": .none])
        #expect(
            OccupancySnapshotStore.occupancy(for: "/Volumes/A") == .unknown,
            "上一轮的 A 还在 —— 说明 update 是合并而不是整体替换")
    }
}

// MARK: - 单一写入点（UI 与快照不许分叉）

@MainActor
@Suite("占用结论的单一写入点")
struct OccupancyStoreSnapshotParityTests {

    /// `OccupancyStore` 每轮结论变化之后，**快照与 `results` 必须逐键相同**。
    ///
    /// **为什么必须钉**：快照是给 DA 回调线程（非主线程）读的那份，
    /// `results` 是给界面读的那份。两处各写一遍必然分叉 ——
    /// 而「两个界面看到两个结论」正是 ``OccupancyStore`` 诞生时要修的病。
    /// 这条判据把「单一写入点」这件事变成可测的。
    @Test func 每轮之后快照与UI逐键相同() async {
        let process = makeProcess(pid: 7)
        let store = OccupancyStore(
            diskStore: .shared,
            pollInterval: 3_600,
            detect: { path in path == "/Volumes/A" ? .occupied([process]) : .none },
            autoStart: false)

        let a = makeDisk("/Volumes/A")
        let b = makeDisk("/Volumes/B")
        await store.refresh(disks: [a, b])

        // 自证：这一轮真的产出了两条结论（否则下面的循环是空转的「假绿」）。
        #expect(store.results.count == 2)
        for (key, value) in store.results {
            #expect(
                OccupancySnapshotStore.occupancy(for: key) == value,
                "「\(key)」在 UI 里是 \(value)，快照里却是 \(OccupancySnapshotStore.occupancy(for: key))"
            )
        }
        #expect(OccupancySnapshotStore.occupancy(for: "/Volumes/A") == .occupied([process]))

        // 拔掉 B：UI 与快照必须**一起**丢掉它。
        await store.refresh(disks: [a])
        #expect(store.results["/Volumes/B"] == nil)
        #expect(
            OccupancySnapshotStore.occupancy(for: "/Volumes/B") == .unknown,
            "B 已经从 UI 里消失了，快照里却还留着它的旧结论")
    }

    /// 磁盘列表变空时，UI 与快照也必须一起清空。
    @Test func 列表清空时UI与快照一起清空() async {
        let store = OccupancyStore(
            diskStore: .shared,
            pollInterval: 3_600,
            detect: { _ in .none },
            autoStart: false)
        await store.refresh(disks: [makeDisk("/Volumes/A")])
        #expect(store.results.count == 1)
        await store.refresh(disks: [])
        #expect(store.results.isEmpty)
        #expect(OccupancySnapshotStore.occupancy(for: "/Volumes/A") == .unknown)
    }
}

// MARK: - 开关偏好

@Suite("接管访达推出的开关偏好")
struct TakeOverFinderEjectPreferenceTests {

    /// 键不存在 ⇒ `false`（**默认关**）。
    ///
    /// **为什么默认关**：接管是系统级改动 —— 它拦截所有走
    /// `NSWorkspace.unmountAndEjectDevice` 的推出请求。一次性推给老用户风险太高：
    /// 万一出 bug，用户会以为「盘推不出来了」。
    @Test func 键不存在时默认关() {
        let defaults = UserDefaults.standard
        let key = AppSettings.Key.takeOverFinderEject
        let saved = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        #expect(AppSettings.takeOverFinderEject == false)
        AppSettings.takeOverFinderEject = true
        #expect(AppSettings.takeOverFinderEject == true)
    }

    /// 偏好键的字符串是持久化契约：改它会静默重置所有老用户的开关。
    @Test func 偏好键保持稳定() {
        #expect(AppSettings.Key.takeOverFinderEject == "takeOverFinderEject")
    }
}

// MARK: - 可用性闸门

/// 「接管这个开关此刻能不能用」（FDA 闸门）的判据。
///
/// ## 为什么要单独守
///
/// 没授「完全磁盘访问」时，接管链路的**每一环都还是好的**，只是永远走不进弹窗
/// （占用检测返回 `.needsFullDiskAccess`，判定层依法放行）。
/// 于是「开关开着」与「开关在管事」是两件事 —— 而旧版把它们画成了同一个开关：
/// 用户打开它，然后**什么都不会发生**，界面上也没有一个字说得出原因。
///
/// 闸门就是这两者之间那一步。它决定四件事（开关画成什么 / 那一行能不能点 /
/// 说明写什么 / 要不要引导去系统设置），所以它必须**只在一处推导**、并且能被穷举断言
/// —— 四处各判一次必然漂移。
@Suite("接管访达推出的可用性闸门")
struct TakeOverAvailabilityTests {

    // MARK: 推导（纯函数）

    /// 四种组合穷举。**这是唯一的推导处**，所以四种都要钉住。
    @Test func 可用性只由沙盒与授权两个布尔决定() {
        #expect(
            AppSettings.TakeOverAvailability.resolve(
                isSandboxed: false, isFullDiskAccessAuthorized: false) == .needsFullDiskAccess,
            "没授权、又不在沙盒里 ⇒ 就是「缺完全磁盘访问」，没有第三种解释")
        #expect(
            AppSettings.TakeOverAvailability.resolve(
                isSandboxed: false, isFullDiskAccessAuthorized: true) == .usable)
        // 沙盒构建里没有 TCC 拦截（`OccupancyResult` 直接走 `.unknown`），
        // 也就不存在「用户去授权」这条路 ⇒ 一律算可用，不画那条引导。
        // 与 `ContentView.refreshFDAStatus()` 同一条判据（那边写的是
        // `isSandboxed || isFullDiskAccessAuthorized()`）。
        #expect(
            AppSettings.TakeOverAvailability.resolve(
                isSandboxed: true, isFullDiskAccessAuthorized: false) == .usable,
            "沙盒下不该引导用户去授权 —— 那里根本没有「授权」这条路")
        #expect(
            AppSettings.TakeOverAvailability.resolve(
                isSandboxed: true, isFullDiskAccessAuthorized: true) == .usable)
    }

    @Test func 只有可用才算可用() {
        #expect(AppSettings.TakeOverAvailability.usable.isUsable)
        #expect(!AppSettings.TakeOverAvailability.needsFullDiskAccess.isUsable)
    }

    // MARK: 画出来的值

    /// **不可用时一律画「关」** —— 这是这个闸门最容易被「优化」掉的一条。
    ///
    /// 画成「开」就是在撒谎：那个开关看起来生效了，而它什么都不会做。
    @Test func 不可用时不许画成开() {
        #expect(
            AppSettings.TakeOverAvailability.effectiveIsOn(
                userWants: true, availability: .needsFullDiskAccess) == false,
            "未授权时画成了「开」—— 用户会以为接管在管事，而它永远不会弹窗")
    }

    /// 可用时**就是用户的意愿值**，不多不少。
    @Test func 可用时等于用户意愿() {
        #expect(
            AppSettings.TakeOverAvailability.effectiveIsOn(userWants: true, availability: .usable))
        #expect(
            !AppSettings.TakeOverAvailability.effectiveIsOn(
                userWants: false, availability: .usable))
    }

    @Test func 不可用时意愿为假仍是假() {
        #expect(
            !AppSettings.TakeOverAvailability.effectiveIsOn(
                userWants: false, availability: .needsFullDiskAccess))
    }

    // MARK: 探测入口

    /// 探测入口必须**就是**喂那两个布尔给纯函数。
    ///
    /// **这条断言的分辨力边界**（写清楚，免得下次误以为它守住了更多）：
    /// 两边读的是同一对输入，所以「这台机器授权没授权」不影响成立与否；
    /// 它能抓住的是「`takeOverAvailability()` 换用了别的输入」
    /// （比如顺手读一下开关自己的值 —— 那会变成单向开关，§8.113.14）。
    @Test func 探测入口只喂那两个布尔() {
        let probed = AppSettings.takeOverAvailability()
        let recomputed = AppSettings.TakeOverAvailability.resolve(
            isSandboxed: OccupancyDetector.isSandboxed,
            isFullDiskAccessAuthorized: OccupancyDetector.isFullDiskAccessAuthorized())
        #expect(probed == recomputed)
    }

    // MARK: 接线守卫（扫源码 —— 纯函数守不住「视图有没有用它」）

    /// 「接管访达的推出」那一行必须**三处都过闸门**：点击动作、开关值、说明文字。
    ///
    /// **为什么只能扫源码**：``TakeOverAvailability`` 的单测守的是**推导**，
    /// 守不住「视图有没有真的用它」。把 `onTap: takeOverTapAction` 写回
    /// `onTap: toggleTakeOverFinderEject`，上面所有断言**仍然是绿的** ——
    /// 而用户又能点一个永远不会生效的开关了（「看着在守其实守不住」的典型，
    /// 本仓库记过好几例）。
    @Test func 接管行三处都过闸门() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Views/SettingsView.swift"),
            encoding: .utf8)

        #expect(
            source.contains("onTap: takeOverTapAction"),
            "接管那一行的 onTap 不再走闸门 —— 未授权时整行又变成可点的了")
        #expect(
            !source.contains("onTap: toggleTakeOverFinderEject"),
            "接管那一行把 `toggleTakeOverFinderEject` 直接传给了 line(...) —— 绕过了可用性闸门")
        #expect(
            source.contains("accessibilityValue: L10n.tr(takeOverOn ? .on : .off)"),
            "无障碍值读的是用户偏好而不是生效值 —— 看不见的用户会听到「开」，而它并没有生效")
        #expect(
            source.contains("description: takeOverDescription"),
            "说明文字不再随状态走 —— 未授权时用户只会看到一个拨不动、也不说为什么的开关")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

// MARK: - 用户决策窗口

/// 「用户决策最多等多久」这一组常量之间的**契约**。
///
/// **为什么值得一组独立守卫**：这几个数**互相耦合**，而 `userDecisionTimeout` 曾经是 60
/// —— 把它改大（或改回去）**不会让任何现有断言变红**，只会让用户看清占用者之后
/// 点下「关闭并推出」时**盘纹丝不动**。
///
/// 实测（2026-09-28，`Scripts/e2e_click_takeover.sh`，同一台机器/同一块盘，
/// 只改「弹窗出现后多久点下去」）：
///
/// | 阻塞 | 放行时刻 | 结果 |
/// |---|---|---|
/// | 3.1s | ~5.4s | ✅ 推出成功 |
/// | 9.8s | 12.07s | ✅ 推出成功 |
/// | 12.2s | 14.45s | ❌ 盘还在 |
/// | 12.5s | 14.78s | ❌ 盘还在（可复现） |
///
/// ⇒ 「用户决策 + 清场宽限」必须**留出余量地**落在系统等待上限之内。
@Suite("接管访达推出的用户决策窗口")
struct TakeOverDecisionWindowTests {

    /// 放行时刻 = 用户决策 + 清场宽限（清场是同步阻塞的，要算进去）。
    private static var releaseDeadline: TimeInterval {
        EjectHookPolicy.userDecisionTimeout
            + ProcessTerminator.termGrace + ProcessTerminator.killGrace
    }

    @Test func 系统等待上限是实测值不是旋钮() {
        // ⚠️ 防的是**假绿**：如果有人把 `userDecisionTimeout` 超限，最省事的「修法」
        // 是把上限也一起改大 —— 那样下面那条不等式照样成立，而 bug 原封不动。
        // 12.5 有两条互相独立的实测支撑（§8.146.3 的 12.5s 返回；2026-09-28 的
        // 12.07s 成功 / 14.45s 失败）。要改它，先拿出新的实测。
        #expect(abs(EjectHookPolicy.systemUnmountPatience - 12.5) < 0.001)
    }

    @Test func 用户决策超时必须留在系统等待上限之内() {
        // ⚠️ `#expect` 的说明参数是 `Comment`（**不接受运行时拼出来的字符串**）——
        // 要带具体数值就用 `print`，别把它拼进 message。
        #expect(
            Self.releaseDeadline < EjectHookPolicy.systemUnmountPatience,
            "放行时刻越过系统等待上限：访达那时已经不等了，用户点了「关闭并推出」盘也推不出去")
    }

    @Test func 决策窗口要留出余量不能贴边() {
        // 只判「小于」不够：2026-09-28 成功的那一次放行时刻是 12.07s，
        // 距上限只剩 0.43s —— 真机上一点调度抖动就会翻面。
        let margin = EjectHookPolicy.systemUnmountPatience - Self.releaseDeadline
        #expect(margin >= 1.5, "余量太小，贴边会在真机上偶发失败")
    }

    @Test func 决策窗口不能短到看不清占用者() {
        // 反向也守一条：压得太小（比如 1s）同样是 bug —— 用户还在读占用列表，
        // 弹窗就自己收掉了，等于把「接管」变成「弹一下就没了」。
        #expect(EjectHookPolicy.userDecisionTimeout >= 5, "决策窗口太短，用户来不及看清占用者")
    }
}
