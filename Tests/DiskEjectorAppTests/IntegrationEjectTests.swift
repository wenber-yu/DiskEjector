import Foundation
import Testing

@testable import DiskEjectorApp

/// 真机集成测试：在真实被占用的磁盘上验证「关闭占用进程并推出」端到端链路。
///
/// **为什么保留在套件里而不是删掉**：这是核心价值（列出占用进程 + 一键关闭并推出）唯一
/// 的真实端到端验证，mock 单测覆盖不了「真实 lsof 列出进程 → SIGTERM/SIGKILL → 系统推出」这条链路。
///
/// **CI / 受限环境的处理**：挂载磁盘映像需要访问 `/Volumes` 与 `/dev`，在 CI 沙盒或
/// 无权限环境下 `hdiutil attach` 会失败。此时**跳过而非失败**（见 `canAttachDiskImage`），
/// 避免把环境限制误判成产品缺陷；本地开发机上有权限时会执行完整验证。
///
/// ## ⚠️ 为什么必须「等测试盘出现」，而不是 `hdiutil attach` 一返回就查（2026-09-21）
///
/// 这条测试**真红过一次**（全量日志 `.build/preflight/门槛8.log`）。那次失败输出里：
///
/// ```
/// guard …fetchExternalDisks().first(where: { $0.mountPath == vol })  →  没找到
/// ① 本次看到的外部盘：["/Volumes/wenbo-data", "/Volumes/DiskEjectorEjectTest"]
/// ```
///
/// 同一个函数、相隔几微秒，**两次调用的结果不一样** —— 而 `try "hi".write(toFile: "\(vol)/x.txt")`
/// 已经成功 ⇒ 卷在**文件系统层面确实已挂载**。
/// ⇒ 不是「没挂上」，是「挂上了，但 `fetchExternalDisks()` 那一刻还没把它算成外置卷」：
/// ``DiskClassifier`` 对磁盘映像走第 4 条（虚拟设备没有 `DADeviceInternal`），
/// 要求 `DAMediaEjectable == true`，而那个属性由 **DiskArbitration 异步补全**。
///
/// **为什么这不是「把测试改松」**：产品自己的「盘可见」判定时点是
/// ``DiskListStore`` 收到 `NSWorkspace.didMountNotification` 之后那次 `refresh()`，
/// 比 `hdiutil attach` 返回**更晚**。原测试假设的「attach 返回 ⇒ 立刻可见」
/// **比产品契约更严** —— 偶发正是这条更严的假设造成的，不是产品缺陷。
/// ⇒ 现在等的是**产品会看到的同一个东西**（盘出现在 `fetchExternalDisks()` 里），
/// 超时仍是硬失败，且失败信息里带上「求值几次、等了多久」（``WaitOutcome``）。
///
/// ⚠️ **本套件故意不标 `@MainActor`**（2026-09-20，§8.99）。
///
/// 它有两处 `task.waitUntilExit()`（`canAttachDiskImage` 的 `s(...)` 里、`shell(_:)` 里），
/// 以及它们调起的 `hdiutil create/attach/detach` —— 全是**同步阻塞、不让路**的等待。
/// 标了 `@MainActor` 就等于把这些等待压在**主 actor** 上，而
/// `OccupancyStoreTests.waitUntil`（`@MainActor`，靠 `await Task.sleep` 轮询）恰恰要
/// 主 actor 空闲才能推进（§8.97.3）—— 那正是 2026-09-17 CI 上
/// 「`磁盘列表一变就重测占用` 失败（`arrived` 为 false）」的候选根因。
///
/// 摘掉标注后这些等待跑在**协作线程池**上，主 actor 不再被占。
/// 逐处确认过：需要主 actor 的只有 `EjectFlowController`（`@MainActor`），
/// 而它两处都是 `await` 调用（跨 actor 边界本来就没问题）；
/// `DiskService` 是 `@unchecked Sendable`、非隔离 ⇒ **摘掉后没有一处需要补 `@MainActor`**。
struct IntegrationEjectTests {

    @Test func 真实占用时关闭进程并推出() async throws {
        // 环境不支持挂载磁盘映像时优雅跳过（CI 沙盒等），不判失败。
        guard Self.canAttachDiskImage() else { return }

        let dmg = "/tmp/DiskEjectorEjectTest.dmg"
        let vol = "/Volumes/DiskEjectorEjectTest"
        var tail: Process?

        // 清理必须**在任何可能失败的步骤之前**登记。
        // 原先 defer 写在 `tail.run()` 之后，而上面第 27 行的写入也在它之前 ——
        // 一旦写入抛错，defer 还没注册，挂载点与临时 dmg 就一起泄漏了。
        // 2026-09-15 实际踩过：写入被沙箱拦截 → `/Volumes/DiskEjectorEjectTest`
        // 一直挂着、`/tmp` 里留了 5 MB 映像，只能手工 hdiutil detach。
        defer {
            tail?.terminate()
            try? shell("hdiutil detach \(vol) 2>/dev/null")
            try? FileManager.default.removeItem(atPath: dmg)
        }

        try? shell("hdiutil detach \(vol) 2>/dev/null")
        try? FileManager.default.removeItem(atPath: dmg)
        try shell("hdiutil create -size 5m -fs HFS+ -volname DiskEjectorEjectTest \(dmg)")
        try shell("hdiutil attach \(dmg) -nobrowse")
        try "hi".write(toFile: "\(vol)/x.txt", atomically: true, encoding: .utf8)

        // 制造一个真实占用进程（tail -f 持续打开文件）。
        let tailProcess = Process()
        tailProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tailProcess.arguments = ["-f", "\(vol)/x.txt"]
        tailProcess.standardOutput = FileHandle.nullDevice
        try tailProcess.run()
        tail = tailProcess

        // ⚠️ **等到它出现在 `fetchExternalDisks()` 里**，而不是 `hdiutil attach` 一返回就查 ——
        // 两者的差别见文件头「为什么必须等」。超时 15s：实测传播延迟在亚秒级，
        // 15s 足够；真的 15s 都不出现，那是**环境或产品**的问题，必须硬失败。
        let waited = await Self.waitForDisk(timeout: 15) { await Self.liveTestDisk(at: vol) }
        guard let disk = waited.disk else {
            // ⚠️ 2026-09-21 真红过一次（全量日志 `.build/preflight/门槛8.log`）。
            // 只写「未找到测试盘」等于没说：至少三种可能，而它们的修法完全不同 ——
            //   ① `hdiutil attach` 其实没挂上（沙箱 / 权限）；
            //   ② 挂成了 `DiskEjectorEjectTest 1`（上一轮的挂载点还占着名字）；
            //   ③ 挂上了，但那一刻 `fetchExternalDisks()` 还没把它算成外置卷。
            // 原诊断只打「本次看到的外部盘」，而那是一次**重新查询** —— 它拿到的是
            // 「现在的状态」，说明不了「失败那一刻为什么没看到」。
            // ⇒ 这里把能分开这三件事的证据**逐条**打出来（② 用的是既有的注入点，
            //    不需要为诊断在生产代码里加任何东西）。
            // ⚠️ 走 `"\(…)"` 而不是直接传 `String`：`Issue.record` 的重载里有 `Error` 那一支，
            // 直接传 `String` 会被解析成 `Error`（编译错）。插值造出的是 `Comment`。
            let message = Self.notFoundDiagnostic(vol: vol, outcome: waited.outcome)
            Issue.record("\(message)")
            return
        }

        // 1) 直接推出：应失败并返回 busy，且携带占用进程。
        let first = await EjectFlowController.shared.eject(disk: disk)
        guard case .busy(let occupying) = first else {
            Issue.record("期望 busy，实际 \(first)")
            return
        }
        #expect(!occupying.isEmpty, "busy 应携带占用进程（列出是谁）")

        // 2) 关闭并推出：终止占用进程后应成功。
        let second = await EjectFlowController.shared.terminateAndEject(disk: disk, processes: occupying)
        guard case .ejected = second else {
            Issue.record("期望 ejected，实际 \(second)")
            return
        }

        // 3) 验证卷确实已被推出（不再出现在外置卷列表中）。
        let stillThere = DiskService.shared.fetchExternalDisks().contains { $0.mountPath == vol }
        #expect(!stillThere, "推出后卷应已消失")
    }

    // MARK: - 等测试盘出现（以及它为什么必须等）

    /// 等 `probe` 交出磁盘，最多 `timeout` 秒；返回「等到了吗」与**等到的那块盘**。
    ///
    /// ⚠️ 盘**从轮询里带出来**，不在外面再查一次 —— 再查一次正是 2026-09-21 那次失败诊断的
    /// 毛病：它**重新**查了一遍，于是拿到的是「现在的状态」，而不是「失败那一刻的状态」
    /// （同族：§8.113.12「报错必须指名真因」）。
    ///
    /// ⚠️ `probe` 由调用方注入 ⇒ 这条「等到可见为止」的策略**本身可以被确定性地验**：
    /// 喂一个「前两拍 nil、第三拍给盘」的探针必须成功且恰好 3 拍；喂一个「永远 nil」的
    /// 探针必须在超时后**放弃**（而不是挂住），且拍数 ≥ 2（证明是**轮询**，不是「查一次就睡」）。
    /// 见 `等待测试盘的装置必须真的轮询并且能超时`。
    ///
    /// 判超时用 `Date()`、报数用 ``WaitOutcome`` —— 与既有两个等待 helper
    /// （`OccupancyStoreTests.waitUntil` / `ProcessAppResolverTests.waitForExecutablePath`）
    /// 同一口径，别再造第三套。
    private static func waitForDisk(
        timeout: TimeInterval = 15,
        probe: @Sendable () async -> DiskInfo?
    ) async -> (outcome: WaitOutcome, disk: DiskInfo?) {
        let started = Date()
        var polls = 0
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            polls += 1
            if let disk = await probe() {
                return (
                    WaitOutcome(ok: true, polls: polls, elapsed: Date().timeIntervalSince(started)),
                    disk
                )
            }
            // `Task.sleep` 是**让路**（不是 `usleep` 那种同步阻塞）——
            // 本套件不标 `@MainActor`，但协作线程池上的同步阻塞同样会饿着别的用例（§8.99）。
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // 退出循环时可能刚好是最后一拍就绪 —— 再查一次，别把「刚好赶上」误报成超时。
        polls += 1
        let found = await probe()
        return (
            WaitOutcome(ok: found != nil, polls: polls, elapsed: Date().timeIntervalSince(started)),
            found
        )
    }

    /// 生产探针：**在协作线程池之外**枚举。
    ///
    /// `fetchExternalDisks()` 会做磁盘 I/O（逐卷问 DiskArbitration），与
    /// ``DiskListStore`` 的 `refresh()` 走同一条路 —— 不让它占住协作线程池的线程。
    private static func liveTestDisk(at vol: String) async -> DiskInfo? {
        await Task.detached(priority: .userInitiated) {
            DiskService.shared.fetchExternalDisks().first { $0.mountPath == vol }
        }.value
    }

    // MARK: - 失败诊断：把「三种可能」逐条分开

    /// 未找到测试盘时那段失败文本。
    ///
    /// 抽成纯函数是为了**可被断言** —— `Issue.record` 里的字符串在测试里取不到
    /// （同 ``WaitOutcome/failureNote(_:)`` 抽出来的理由）。
    /// 少了这层，「消息里有没有那四条证据」就退化成一条**约定**，没人守得住：
    /// 谁把 `①②③④` 删掉两条，不会有任何东西变红。
    /// 见 `未找到测试盘时的诊断必须带上四条证据与数字`。
    private static func notFoundDiagnostic(vol: String, outcome: WaitOutcome) -> String {
        """
        未找到测试盘 \(vol)
        \(outcome.failureNote("等它出现在 fetchExternalDisks() 里"))
        ① 系统挂载列表里有它吗：\(Self.mountListHas(vol))
        ② 只喂它一个 URL 给 fetchExternalDisks()：\(Self.enumerateOnly(vol))
           （空 = DiskArbitration 还描述不出它 / 判定为不可推出；非空 = 枚举本身能认它）
        ③ 现在看到的外部盘：\(Self.currentExternalPaths())
        ④ 系统挂载点：\(Self.systemMounts())
        """
    }

    /// ① 系统挂载列表里有它吗 —— 分开「根本没挂上」与「挂上了」。
    private static func mountListHas(_ vol: String) -> Bool {
        DiskService.liveMountedVolumeURLs().contains { $0.path == vol }
    }

    /// ② **只喂它一个 URL** 给 `fetchExternalDisks()`。
    ///
    /// 空 = DiskArbitration 那一刻还描述不出它（或判定为不可推出）；
    /// 非空 = 枚举本身能认它 ⇒ 失败是**时点**问题。
    ///
    /// 走的是 `fetchExternalDisks(mountedVolumeURLs:)` 这个**既有的注入点** ——
    /// 诊断不需要在生产代码里加任何东西。
    private static func enumerateOnly(_ vol: String) -> [String] {
        DiskService.shared.fetchExternalDisks(
            mountedVolumeURLs: { [URL(fileURLWithPath: vol)] }
        ).map(\.mountPath)
    }

    /// ③ 现在看到的外部盘。
    private static func currentExternalPaths() -> [String] {
        DiskService.shared.fetchExternalDisks().map(\.mountPath)
    }

    /// ④ 系统挂载点。
    private static func systemMounts() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            .map(\.path)
    }

    /// 探测当前环境能否挂载磁盘映像**并往卷里写文件**：尝试挂载、写入、再立即卸载一个最小 dmg。
    /// 成功返回 true（顺带清理），失败返回 false（测试将跳过）。
    ///
    /// **为什么探针必须连「可写」一起探**：受管 / 嵌套沙箱会**放行 `hdiutil attach`，却拦下
    /// 对挂载点的写入**（`atomically: true` 要在同卷建临时目录，那一步被拒）。只探「能挂载」
    /// 会把这类环境误判成可用，随后在真正写文件时抛错 —— 既误报成产品缺陷，又因为当时
    /// `defer` 尚未注册而留下挂载残留。所以这里用与测试**完全相同**的写法探一次可写性。
    private static func canAttachDiskImage() -> Bool {
        let dmg = "/tmp/DiskEjectorCanary.dmg"
        let vol = "/Volumes/DiskEjectorCanary"
        let s = { (cmd: String) -> Bool in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", cmd]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return false }
            task.waitUntilExit()
            return task.terminationStatus == 0
        }

        guard s("hdiutil create -size 1m -fs HFS+ -volname DiskEjectorCanary \(dmg)") else { return false }
        guard s("hdiutil attach \(dmg) -nobrowse") else {
            _ = s("rm -f \(dmg)")
            return false
        }

        let writable = (try? "probe".write(toFile: "\(vol)/.write-probe", atomically: true, encoding: .utf8)) != nil

        _ = s("hdiutil detach \(vol)")
        _ = s("rm -f \(dmg)")
        return writable
    }

    private func shell(_ command: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(
                domain: "shell", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: command])
        }
    }

    // MARK: - 装置自己的守卫

    /// **等待装置自己的守卫**（与 `OccupancyStoreTests.等待超时时必须报出轮询次数与耗时`
    /// 同一口径、同一个 ``WaitOutcome``）。
    ///
    /// 没有它，「`waitForDisk` 等到了」与「`waitForDisk` 只查了一次」在输出上**逐字相同** ——
    /// 而后者会让这条测试重新变成 2026-09-21 那次偶发（那次的病根正是「只查一次」）。
    /// 探针可注入，所以这条守卫**不碰任何真磁盘**、恒可运行。
    @Test func 等待测试盘的装置必须真的轮询并且能超时() async {
        let probePath = "/Volumes/DiskEjectorWaitProbe"
        let disk = DiskInfo(
            id: probePath,
            bsdName: "disk9s1",
            volumeName: "DiskEjectorWaitProbe",
            mountPath: probePath,
            totalBytes: 1_000,
            usedBytes: 400,
            freeBytes: 600,
            deviceProtocol: "USB",
            deviceModel: nil
        )

        // ① 第三拍才出现 —— 必须等到。这条**同时**证明它是轮询（不是查一次就返回）。
        let late = ScriptedProbe([nil, nil, disk])
        let waited = await Self.waitForDisk(timeout: 5) { await late.next() }
        #expect(waited.outcome.ok, "第三拍才出现的盘没被等到：\(waited.outcome.diagnostic)")
        #expect(
            waited.disk == disk,
            "等到的那块盘必须从轮询里带出来（不是外面再查一次），实得 \(String(describing: waited.disk))")
        #expect(waited.outcome.polls == 3, "前两拍为 nil ⇒ 恰好 3 次求值，实得 \(waited.outcome.polls)")

        // ② 恒不出现：必须**放弃**（不挂住），且拍数 ≥ 2。
        let never = ScriptedProbe([])
        let timedOut = await Self.waitForDisk(timeout: 0.1) { await never.next() }
        #expect(timedOut.disk == nil, "恒不出现却拿到了盘：\(String(describing: timedOut.disk))")
        #expect(!timedOut.outcome.ok, "恒不出现 ⇒ `ok` 必须是 false")
        #expect(
            timedOut.outcome.polls >= 2,
            "至少要有「循环里那次」与「超时后那次补查」两次求值，实得 \(timedOut.outcome.polls)")

        // ③ 第一拍就出现 ⇒ 恰好 1 拍。**反向对照**：证明 ① 的 `polls == 3` 不是恒真。
        let immediate = ScriptedProbe([disk])
        let fast = await Self.waitForDisk(timeout: 5) { await immediate.next() }
        #expect(fast.outcome.polls == 1, "第一拍就出现 ⇒ 恰好 1 拍，实得 \(fast.outcome.polls)")
        #expect(fast.disk != nil, "第一拍就出现的盘必须被带出来")
    }

    /// **失败诊断的守卫**：那段文本必须带上「在找哪个卷」、求值次数，以及**四条证据**。
    ///
    /// 上面那条覆盖不到这里 —— `notFoundDiagnostic` 只在**真失败**时才被调用，
    /// 而「四条证据少了两条」不会有任何东西变红（同 ``WaitOutcome`` 文件头说的那个病）。
    @Test func 未找到测试盘时的诊断必须带上四条证据与数字() {
        let vol = "/Volumes/DiskEjectorNotThere"
        let message = Self.notFoundDiagnostic(
            vol: vol, outcome: WaitOutcome(ok: false, polls: 7, elapsed: 1.25))

        #expect(message.contains(vol), "诊断里没有「在找哪个卷」：\(message)")
        #expect(message.contains("7"), "诊断里没有求值次数（``WaitOutcome`` 的口径）：\(message)")
        for label in ["①", "②", "③", "④"] {
            #expect(message.contains(label), "诊断少了 \(label) 那条证据 —— 三种可能就分不开了：\(message)")
        }

        // 装置自证：`systemMounts()` 恒应看到 `/`。看不到 ⇒「④ 系统挂载点：[]」与
        // 「诊断装置瞎了」**逐字相同**（§8.96.4），那段输出就不可信。
        #expect(
            Self.systemMounts().contains("/"),
            "诊断拿不到系统挂载点（连 `/` 都没有）⇒ 那条输出不可信")
        // 反向对照：`mountListHas` 不能恒为 true，否则 ① 那条证据没有信息量。
        #expect(
            !Self.mountListHas("/Volumes/__DiskEjectorNoSuchVolume__"),
            "不存在的卷被判成「已挂载」⇒ `mountListHas` 恒为 true，① 等于没打")
    }
}

/// 按脚本逐拍给出答案的探针。
///
/// 用 `actor` 而不是裸 `var`：`probe` 是 `@Sendable`，捕获可变状态会被编译器拒绝
/// （与 `OccupancyStoreTests.CallCounter` 同一处理）。
private actor ScriptedProbe {
    private var answers: [DiskInfo?]
    init(_ answers: [DiskInfo?]) { self.answers = answers }
    func next() -> DiskInfo? { answers.isEmpty ? nil : answers.removeFirst() }
}
