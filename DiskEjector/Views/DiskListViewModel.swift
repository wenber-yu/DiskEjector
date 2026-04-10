import Foundation
import AppKit

@MainActor
class DiskListViewModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var selectedDisk: DiskInfo?
    @Published var processes: [String: [ProcessInfo]] = [:]
    @Published var isEjecting = false
    @Published var ejectingDiskId: String?
    @Published var statusMessage: String?
    @Published var showConfirmDialog = false
    @Published var confirmMessage = ""
    @Published var pendingDisk: DiskInfo?

    private var pendingProcesses: [ProcessInfo] = []
    private let autoRefresh: Bool

    init(autoRefresh: Bool = true) {
        self.autoRefresh = autoRefresh
        if autoRefresh {
            // 异步刷新，避免主线程阻塞
            Task {
                await refresh()
            }
        }
    }

    func refresh() async {
        // 在后台线程获取磁盘信息和进程
        let (fetchedDisks, fetchedProcesses) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let disks = DiskService.shared.fetchExternalDisks()
                var processes: [String: [ProcessInfo]] = [:]
                for disk in disks {
                    processes[disk.id] = ProcessService.shared.findProcessesAccessingDisk(mountPath: disk.mountPath)
                }
                continuation.resume(returning: (disks, processes))
            }
        }
        
        // 在主线程更新UI
        disks = fetchedDisks
        processes = fetchedProcesses
        if selectedDisk == nil {
            selectedDisk = disks.first
        }
    }

    func requestEject(disk: DiskInfo) {
        let procs = processes[disk.id] ?? []
        pendingDisk = disk
        pendingProcesses = procs

        if procs.isEmpty {
            confirmMessage = "即将推出磁盘「\(disk.displayName)」，确认继续吗？"
        } else {
            let procList = procs.map { "• \($0.name) (PID: \($0.pid))" }.joined(separator: "\n")
            confirmMessage = "以下程序正在访问此磁盘，推出前将被终止：\n\(procList)\n\n未保存的工作将被丢弃，是否继续？"
        }
        showConfirmDialog = true
    }

    func confirmEject() {
        guard let disk = pendingDisk else { return }
        let procs = pendingProcesses

        showConfirmDialog = false
        isEjecting = true
        ejectingDiskId = disk.id
        statusMessage = nil

        DiskService.shared.ejectDisk(disk, killProcesses: procs) { [weak self] result in
            Task { @MainActor in
                self?.isEjecting = false
                self?.ejectingDiskId = nil

                switch result {
                case .success:
                    self?.statusMessage = "「\(disk.displayName)」已成功推出"
                    await self?.refresh()
                case .failure(let error):
                    let msg = error.localizedDescription
                    self?.statusMessage = "「\(disk.displayName)」推出失败: \(msg)"
                    self?.showErrorAlert(disk: disk.displayName, error: msg)
                }
            }
        }
    }

    private func showErrorAlert(disk: String, error: String) {
        let alert = NSAlert()
        alert.messageText = "磁盘推出失败"
        alert.informativeText = "无法安全推出磁盘「\(disk)」：\n\(error)\n\n详细信息已记录到日志文件。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}