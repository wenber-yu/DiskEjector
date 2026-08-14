import Foundation

/// 统一磁盘推出流程（菜单栏与主窗口共用唯一实现）。
///
/// 收敛理由：此前 AppDelegate（菜单栏）与 ContentView（主窗口）各自实现一套
/// 「检查占用 → 确认 → 推出」逻辑，导致行为分叉：
/// - 主窗口用列表刷新时的缓存判断占用（时序隐患：刷新后新开的占用会被跳过确认）
/// - 主窗口推出失败无任何用户提示
/// - 菜单栏实时检查、结果弹窗，与主窗口不一致
///
/// 现在「实时占用检查」与「底层执行 + 结果处理」只保留这一份，两处 UI 只负责
/// 各自的确认/提示呈现，编排与执行完全一致。
final class EjectFlowController: @unchecked Sendable {
    static let shared = EjectFlowController()

    private let diskService: DiskService
    private let processService: ProcessService

    /// 可注入初始化（生产一律用 `shared`；测试传入 mock 子类）。
    init(diskService: DiskService = .shared, processService: ProcessService = .shared) {
        self.diskService = diskService
        self.processService = processService
    }

    /// 实时检查磁盘占用进程（lsof/ps 最多约 2 秒，后台执行，不阻塞主线程）。
    /// completion 保证在主线程回调。
    func checkOccupiedProcesses(mountPath: String, completion: @escaping @Sendable ([ProcessInfo]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let processes = self.processService.findProcessesAccessingDisk(mountPath: mountPath)
            DispatchQueue.main.async {
                completion(processes)
            }
        }
    }

    /// 执行推出：先终止占用进程（如有），再卸载磁盘。
    /// completion 保证在主线程回调（DiskService.ejectDisk 内部已切回主线程）。
    func eject(disk: DiskInfo, processes: [ProcessInfo], completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        diskService.ejectDisk(disk, killProcesses: processes, completion: completion)
    }

    /// 推出失败的统一提示文案（两处 UI 复用，避免文案分叉）。
    func failureMessage(disk: DiskInfo, error: Error) -> String {
        "无法推出磁盘 \"\(disk.displayName)\": \(error.localizedDescription)"
    }
}
