import Darwin
import Foundation

/// 推出操作的最终结果（菜单栏与主窗口共用同一套判定）。
///
/// **为什么不再直接用 `Result<Void, EjectFailure`**：弹窗需要区分「失败原因」与
/// 「当前是谁在占用」——`fBsyErr` 只告诉我们「忙」，但真正的体验价值在于把
/// 占用进程名陈列出来并给出「关闭并推出」。`.busy` 携带检测到的进程列表，
/// 空数组表示「系统判定忙、但本应用没能列出具体进程」（例如未授予完全磁盘访问）。
enum EjectOutcome: Sendable, Equatable {
    /// 推出成功。
    case ejected
    /// 卷正被占用。`occupying` 为检测到的进程；可能为空（无法列出具体程序）。
    case busy(occupying: [OccupyingProcess])
    /// 其他失败（权限不足、设备已消失、未归类等）。
    case failed(reason: EjectFailure)
}

/// 统一磁盘推出流程（菜单栏与主窗口共用唯一实现）。
///
/// 收敛理由：此前 AppDelegate（菜单栏）与 ContentView（主窗口）各自实现一套
/// 「检查占用 → 确认 → 推出」逻辑，导致行为分叉。
///
/// 本类只做编排，不含业务规则：
/// - 外置判定在 ``DiskClassifier``
/// - 推出执行在 ``EjectService``
/// - 占用检测在 ``OccupancyDetector``
/// 三处都可独立替换与单测。
@MainActor
final class EjectFlowController {

    static let shared = EjectFlowController()

    private let ejectService: EjectService
    private let occupancyDetector: OccupancyDetector

    /// 写「用户可见日志」的入口。生产默认落 ``LogService``（`~/Library/Logs/DiskEjector/error.log`）。
    ///
    /// **为什么做成可注入的闭包**：失败弹窗向用户承诺「已记入日志」，
    /// 这条承诺必须有测试兜住 —— 否则将来有人把 ``recordFailure(disk:failure:)`` 改回直接
    /// `return .failed(...)`，界面照旧显示「已记入日志」，而日志里其实什么都没有，
    /// 且没有任何测试会红。测试注入一个记录型替身即可断言「失败确实留痕」，
    /// 同时避免把测试造的假失败写进用户真实的日志文件。
    private let log: (String?, String) -> Void

    /// 可注入初始化（生产一律用 `shared`；测试传入 mock 子类）。
    init(
        ejectService: EjectService = .shared,
        occupancyDetector: OccupancyDetector = .shared,
        log: @escaping (String?, String) -> Void = { disk, message in
            LogService.shared.log(disk: disk, message: message)
        }
    ) {
        self.ejectService = ejectService
        self.occupancyDetector = occupancyDetector
        self.log = log
    }

    /// 检测访问该卷的进程。
    ///
    /// 沙盒环境下返回 ``OccupancyResult/unknown``，调用方必须显式处理该状态，
    /// 不能当作「无占用」。
    func checkOccupancy(mountPath: String) async -> OccupancyResult {
        await occupancyDetector.detect(mountPath: mountPath)
    }

    /// 执行推出。
    ///
    /// **检测只用于展示，不干预决策**：先 `lsof` 捕获占用进程名（让弹窗能列出是谁），
    /// 但真实推出仍交给系统的 `unmountAndEjectDevice`——系统返回 `fBsyErr` 才是
    /// 「忙」的权威信号，检测缺失也绝不会绕过它。这既兑现了「弹出时显示是谁占用」，
    /// 又保留了 Finder 式的安全兜底。
    ///
    /// - Returns: ``EjectOutcome``，调用方据此决定弹窗内容与「关闭并推出」可用性。
    func eject(disk: DiskInfo) async -> EjectOutcome {
        // 捕获占用进程用于弹窗展示；检测失败（沙盒/.needsFullDiskAccess）时为 []。
        let occupancy = await occupancyDetector.detect(mountPath: disk.mountPath)
        let processes = occupancy.processes

        let result = await ejectService.eject(disk: disk)
        let outcome: EjectOutcome =
            switch result {
            case .success: .ejected
            // 系统判定忙：把检测到的进程（可能为空）交给弹窗呈现。
            case .failure(.inUse): .busy(occupying: processes)
            case .failure(let failure): .failed(reason: failure)
            }
        return record(outcome, disk: disk)
    }

    /// 关闭占用进程并重新尝试推出。
    ///
    /// **安全性设计**（区别于已被否决的 `umount -f`）：
    /// 1. 先发 `SIGTERM` 礼貌请求退出，让应用有机会存盘；
    /// 2. 等约 1.5s 后复检，仍被占用的进程升级为 `SIGKILL` 强制终止；
    /// 3. 再等约 0.8s 后做**普通** `unmountAndEjectDevice` 重试——绝不强制卸载文件系统。
    /// 若杀掉进程后磁盘仍被 root 级进程/内核持有，推出会再次返回 `fBsyErr`，此时
    /// 返回 `.busy(remaining)` 把「关不掉」的进程交回 UI，而不是强行卸载。
    /// 自身 PID 会被跳过；`EPERM`（无权终止，如系统进程）算作「无法关闭」如实返回。
    ///
    /// - Parameters:
    ///   - disk: 目标卷。
    ///   - processes: 来自上次 `.busy` 的占用进程列表。
    func terminateAndEject(disk: DiskInfo, processes: [OccupyingProcess]) async -> EjectOutcome {
        // 第 1 步：SIGTERM 礼貌退出。
        let unkillableAfterTerm = terminate(processes, signal: SIGTERM)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 第 2 步：复检，仍占用则对残留升级 SIGKILL。
        let recheck = await occupancyDetector.detect(mountPath: disk.mountPath)
        var remaining = unkillableAfterTerm
        if case .occupied(let stillBusy) = recheck, !stillBusy.isEmpty {
            remaining = terminate(stillBusy, signal: SIGKILL)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        // 第 3 步：普通推出重试（非强制）。
        let result = await ejectService.eject(disk: disk)
        let outcome: EjectOutcome
        switch result {
        case .success:
            outcome = .ejected
        case .failure(.inUse):
            // 仍忙：把当前仍持锁的进程交回 UI（优先用复检结果，失败则退回无法终止的列表）。
            let finalCheck = await occupancyDetector.detect(mountPath: disk.mountPath)
            if case .occupied(let procs) = finalCheck, !procs.isEmpty {
                outcome = .busy(occupying: procs)
            } else {
                outcome = .busy(occupying: remaining)
            }
        case .failure(let failure):
            outcome = .failed(reason: failure)
        }
        return record(outcome, disk: disk)
    }

    /// 记录一次「没能推出」，并原样返回结果供 UI 使用。
    ///
    /// **为什么必须真的落盘**：失败弹窗会告诉用户「已记入日志，可在『设置 › 诊断』中查看」
    /// （设计稿 `03-eject-flow.html`），设置面板的诊断分组也写着
    /// 「记录每次推出失败的时间、磁盘与原因」。这两句话只有在日志确实写入时才成立 ——
    /// ``LogService`` 早就实现了、``EjectFailure/logText`` 也早就备好了，
    /// 但两边从未接上，用户可见的 `error.log` 里一条推出失败都没有。
    /// 若照抄设计稿文案却不接线，就是在骗用户。
    ///
    /// **为什么 `.busy` 也要记**：诊断文案承诺的是「每次」推出失败，而「被占用」
    /// 恰恰是最常见的推出失败 —— 用户报「磁盘推不出来」时，日志必须能回答
    /// 「当时是谁占着」。只记 `.failed` 会让最常见的那种情况在日志里查无此事。
    /// 写入量由用户操作次数决定，不会失控。
    ///
    /// **为什么记在这里而不是 UI 层**：菜单栏与主窗口共用本类，记一次就够；
    /// 将来多一个入口（快捷键、URL scheme）也不会漏记。
    private func record(_ outcome: EjectOutcome, disk: DiskInfo) -> EjectOutcome {
        switch outcome {
        case .ejected:
            break
        case .busy(let occupying):
            // 用应用显示名（`Bunny`）而不是进程可执行名（`IMVIDEO`），否则日志对用户无意义。
            let names = occupying.map(\.displayName).joined(separator: ", ")
            log(disk.displayName, names.isEmpty ? "推出被占用: 未能列出占用进程" : "推出被占用: \(names)")
        case .failed(let failure):
            log(disk.displayName, "推出失败: \(failure.logText)")
        }
        return outcome
    }

    /// 向给定进程发送信号，返回「无法终止」的进程（非 EPERM 之外的成功/已消失不计入）。
    private func terminate(_ processes: [OccupyingProcess], signal: Int32) -> [OccupyingProcess] {
        var unkillable: [OccupyingProcess] = []
        let selfPid = Int32(ProcessInfo.processInfo.processIdentifier)
        for process in processes {
            guard process.pid != selfPid else {
                // 不自杀：自身 PID 算作「无法关闭」，交回 UI 提示。
                unkillable.append(process)
                continue
            }
            errno = 0
            let rc = kill(process.pid, signal)
            if rc != 0 {
                if errno == ESRCH {
                    // 进程已不存在：视为成功，不计入无法关闭。
                    continue
                }
                // EPERM（无权）或其他：如实计入，UI 会告知用户哪些关不掉。
                unkillable.append(process)
            }
        }
        return unkillable
    }

    /// 占用弹窗的说明文案（两处 UI 复用，避免文案分叉）。
    ///
    /// 仅生成引导句：占用进程的「图标 + 名称」列表由 `EjectUI` 用 accessoryView 单独呈现，
    /// 不在此处拼接为文本（`NSAlert` 的纯文本既放不了图标，也没有必要把 PID 塞给用户）。
    /// 磁盘名已经放在弹窗的 messageText（设计稿"即将推出 Samsung T7"），此处不需要重复。
    /// `occupying` 为空表示系统判定忙但本应用无法列出具体进程（通常未授予完全磁盘访问）。
    nonisolated func busyMessage(disk: DiskInfo, occupying: [OccupyingProcess]) -> String {
        if occupying.isEmpty {
            return String(format: L10n.tr(.ejectBusyNoProcessInfo), disk.displayName)
        }
        return L10n.tr(.ejectBusyMessageFormat)
    }

    /// 推出失败的统一提示文案（两处 UI 复用，避免文案分叉）。
    nonisolated func failureMessage(disk: DiskInfo, failure: EjectFailure) -> String {
        failure.reasonText(diskName: disk.displayName)
    }
}
