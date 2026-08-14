import Testing
import Foundation
@testable import DiskEjectorApp

/// 项目模型 ProcessInfo 与 Foundation 的 ProcessInfo 同名，这里显式区分。
private typealias AppProcessInfo = DiskEjectorApp.ProcessInfo

// MARK: - Mock 服务

/// 拦截 ejectDisk 调用的 mock，不透传真实 diskutil。
private final class MockDiskService: DiskService {
    var ejectResult: Result<Void, Error> = .success(())
    var capturedDisk: DiskInfo?
    var capturedProcesses: [AppProcessInfo] = []
    var ejectCalled = false

    override func ejectDisk(
        _ disk: DiskInfo,
        killProcesses: [AppProcessInfo],
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        ejectCalled = true
        capturedDisk = disk
        capturedProcesses = killProcesses
        completion(ejectResult)
    }
}

/// 拦截 findProcessesAccessingDisk 的 mock，不跑真实 lsof/ps。
private final class MockProcessService: ProcessService {
    var processes: [AppProcessInfo] = []
    var capturedMountPath: String?
    var findCalled = false

    override func findProcessesAccessingDisk(mountPath: String) -> [AppProcessInfo] {
        findCalled = true
        capturedMountPath = mountPath
        return processes
    }
}

// MARK: - Fixtures

private func makeDisk() -> DiskInfo {
    DiskInfo(
        id: "/Volumes/TEST",
        bsdName: "TEST",
        volumeName: "测试盘",
        mountPath: "/Volumes/TEST",
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        isEjectable: true
    )
}

// MARK: - 测试

struct EjectFlowControllerTests {

    // MARK: failureMessage

    @Test func failureMessage包含磁盘名与错误描述() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let error = NSError(domain: "DiskService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Resource busy"])

        let message = controller.failureMessage(disk: disk, error: error)

        #expect(message == "无法推出磁盘 \"测试盘\": Resource busy")
    }

    @Test func failureMessage在卷名为空时回退到bsdName() {
        let controller = EjectFlowController()
        let disk = DiskInfo(
            id: "/Volumes/TEST", bsdName: "TEST", volumeName: "",
            mountPath: "/Volumes/TEST", totalBytes: 0, usedBytes: 0, freeBytes: 0, isEjectable: true
        )
        let error = NSError(domain: "DiskService", code: 1, userInfo: [NSLocalizedDescriptionKey: "err"])

        #expect(controller.failureMessage(disk: disk, error: error) == "无法推出磁盘 \"TEST\": err")
    }

    // MARK: checkOccupiedProcesses

    @Test func checkOccupiedProcesses透传占用进程并在主线程回调() async {
        let mockProcess = MockProcessService()
        let expected = [AppProcessInfo(pid: 42, name: "IINA", path: "/Applications/IINA.app")]
        mockProcess.processes = expected
        let controller = EjectFlowController(processService: mockProcess)

        let (processes, isMainThread) = await withCheckedContinuation { continuation in
            controller.checkOccupiedProcesses(mountPath: "/Volumes/TEST") { procs in
                continuation.resume(returning: (procs, Thread.isMainThread))
            }
        }

        #expect(mockProcess.findCalled)
        #expect(mockProcess.capturedMountPath == "/Volumes/TEST")
        #expect(processes == expected)
        #expect(isMainThread, "completion 必须保证在主线程回调")
    }

    @Test func checkOccupiedProcesses无占用时返回空数组() async {
        let mockProcess = MockProcessService()
        mockProcess.processes = []
        let controller = EjectFlowController(processService: mockProcess)

        let processes = await withCheckedContinuation { continuation in
            controller.checkOccupiedProcesses(mountPath: "/Volumes/EMPTY") { procs in
                continuation.resume(returning: procs)
            }
        }

        #expect(processes.isEmpty)
    }

    // MARK: eject

    @Test func eject成功时透传成功结果与参数() async {
        let disk = makeDisk()
        let toKill = [AppProcessInfo(pid: 7, name: "Finder", path: "/System/Library/CoreServices/Finder.app")]
        let mockDisk = MockDiskService()
        mockDisk.ejectResult = .success(())
        let controller = EjectFlowController(diskService: mockDisk)

        let result = await withCheckedContinuation { continuation in
            controller.eject(disk: disk, processes: toKill) { r in
                continuation.resume(returning: r)
            }
        }

        #expect(mockDisk.ejectCalled)
        #expect(mockDisk.capturedDisk == disk)
        #expect(mockDisk.capturedProcesses == toKill)
        guard case .success = result else {
            Issue.record("期望成功，实际失败：\(result)")
            return
        }
    }

    @Test func eject失败时透传错误() async {
        let disk = makeDisk()
        let mockDisk = MockDiskService()
        let error = NSError(domain: "DiskService", code: 2, userInfo: [NSLocalizedDescriptionKey: "unmount failed"])
        mockDisk.ejectResult = .failure(error)
        let controller = EjectFlowController(diskService: mockDisk)

        let result = await withCheckedContinuation { continuation in
            controller.eject(disk: disk, processes: []) { r in
                continuation.resume(returning: r)
            }
        }

        guard case .failure(let e) = result else {
            Issue.record("期望失败，实际成功")
            return
        }
        #expect((e as NSError).code == 2)
    }

    @Test func eject无占用进程时透传空数组() async {
        let disk = makeDisk()
        let mockDisk = MockDiskService()
        let controller = EjectFlowController(diskService: mockDisk)

        _ = await withCheckedContinuation { continuation in
            controller.eject(disk: disk, processes: []) { r in
                continuation.resume(returning: r)
            }
        }

        #expect(mockDisk.capturedProcesses.isEmpty)
    }
}
