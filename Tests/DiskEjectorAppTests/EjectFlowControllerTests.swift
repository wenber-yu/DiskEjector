import Foundation
import Testing

@testable import DiskEjectorApp

// MARK: - Mock 服务

/// 拦截 eject 调用的 mock，不触发真实推出。
private final class MockEjectService: EjectService, @unchecked Sendable {
    var ejectResult: Result<Void, EjectFailure> = .success(())
    var capturedDisk: DiskInfo?
    var ejectCalled = false

    override func eject(disk: DiskInfo) async -> Result<Void, EjectFailure> {
        ejectCalled = true
        capturedDisk = disk
        return ejectResult
    }
}

/// 拦截占用检测的 mock，不跑真实 lsof。
private final class MockOccupancyDetector: OccupancyDetector, @unchecked Sendable {
    var result: OccupancyResult = .none
    var capturedMountPath: String?
    var detectCalled = false

    override func detect(mountPath: String) async -> OccupancyResult {
        detectCalled = true
        capturedMountPath = mountPath
        return result
    }
}

// MARK: - Fixtures

private func makeDisk(name: String = "测试盘") -> DiskInfo {
    DiskInfo(
        id: "/Volumes/TEST",
        bsdName: "disk4s2",
        volumeName: name,
        mountPath: "/Volumes/TEST",
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        deviceProtocol: "USB",
        deviceModel: nil
    )
}

private let zhHans = Locale(identifier: "zh-Hans")

// MARK: - 测试

@MainActor
struct EjectFlowControllerTests {

    // MARK: checkOccupancy

    @Test func checkOccupancy透传检测结果与挂载路径() async {
        let mock = MockOccupancyDetector()
        let expected = [OccupyingProcess(pid: 42, name: "IINA", path: "/Applications/IINA.app")]
        mock.result = .occupied(expected)
        let controller = EjectFlowController(occupancyDetector: mock)

        let result = await controller.checkOccupancy(mountPath: "/Volumes/TEST")

        #expect(mock.detectCalled)
        #expect(mock.capturedMountPath == "/Volumes/TEST")
        #expect(result == .occupied(expected))
    }

    /// 沙盒下检测能力缺失必须显式表现为 `.unknown`，
    /// 不能被折叠成「无占用」——否则上层会据此直接推出。
    @Test func checkOccupancy沙盒下返回unknown而非空列表() async {
        let mock = MockOccupancyDetector()
        mock.result = .unknown
        let controller = EjectFlowController(occupancyDetector: mock)

        let result = await controller.checkOccupancy(mountPath: "/Volumes/TEST")

        #expect(result == .unknown)
        #expect(result.processes.isEmpty)
        #expect(result != .none, "unknown 与 none 必须是可区分的状态")
    }

    // MARK: eject

    @Test func eject成功时返回ejected() async {
        let disk = makeDisk()
        let mock = MockEjectService()
        mock.ejectResult = .success(())
        let controller = EjectFlowController(ejectService: mock)

        let result = await controller.eject(disk: disk)

        #expect(mock.ejectCalled)
        #expect(mock.capturedDisk == disk)
        guard case .ejected = result else {
            Issue.record("期望 ejected，实际 \(result)")
            return
        }
    }

    /// 占用（fBsyErr）必须映射为 `.busy` 且携带检测到的进程，供弹窗列出「是谁」。
    @Test func eject占用时返回busy并携带进程() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.inUse)
        let mockDetect = MockOccupancyDetector()
        let expected = [OccupyingProcess(pid: 42, name: "IINA", path: "/x.mp4")]
        mockDetect.result = .occupied(expected)
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let result = await controller.eject(disk: disk)

        guard case .busy(let occupying) = result else {
            Issue.record("期望 busy，实际 \(result)")
            return
        }
        #expect(occupying == expected)
    }

    /// 非占用类的失败（如设备已消失）仍映射为 `.failed`，不应被误判为占用。
    @Test func eject非占用类失败映射为failed() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.notFound)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let result = await controller.eject(disk: disk)

        guard case .failed(let reason) = result else {
            Issue.record("期望 failed，实际 \(result)")
            return
        }
        #expect(reason == .notFound)
    }

    /// 终止占用进程后推出成功，应返回 `.ejected`。
    /// 用不存在的 PID（kill 返回 ESRCH，被视为已退出）避免真实杀进程。
    @Test func terminateAndEject关闭进程后成功推出() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .success(())
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none  // 复检认为已无占用
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let processes = [OccupyingProcess(pid: 9_999_999, name: "Ghost", path: "")]
        let result = await controller.terminateAndEject(disk: disk, processes: processes)

        guard case .ejected = result else {
            Issue.record("期望 ejected，实际 \(result)")
            return
        }
        #expect(mockEject.ejectCalled)
    }

    // MARK: busyMessage

    @Test func busyMessage带进程时返回引导句不含进程列表() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let processes = [OccupyingProcess(pid: 42, name: "IINA", path: "")]
        let message = controller.busyMessage(disk: disk, occupying: processes)
        // 引导句是设计稿"推出确认对话框"的固定文案（不带磁盘名——磁盘名已放在弹窗标题里）。
        let expected = L10n.tr(.ejectBusyMessageFormat, locale: zhHans)
        #expect(message == expected)
        #expect(!message.contains("PID"), "弹窗正文不应再拼 PID（进程列表改由 accessoryView 渲染图标+名称）")
    }

    @Test func busyMessage无进程时提示授权() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let message = controller.busyMessage(disk: disk, occupying: [])
        let expected = String(format: L10n.tr(.ejectBusyNoProcessInfo, locale: zhHans), "测试盘")
        #expect(message == expected)
    }

    // MARK: failureMessage

    @Test func failureMessage卷名为空时回退到bsdName() {
        let controller = EjectFlowController()
        let disk = DiskInfo(
            id: "/Volumes/TEST", bsdName: "disk4s2", volumeName: "",
            mountPath: "/Volumes/TEST", totalBytes: 0, usedBytes: 0, freeBytes: 0,
            deviceProtocol: "USB", deviceModel: nil
        )

        let message = controller.failureMessage(disk: disk, failure: .inUse)
        let expected = String(format: L10n.tr(.ejectFailedInUseReason, locale: zhHans), "disk4s2")
        #expect(message == expected)
    }

    @Test func failureMessage按失败原因给出不同文案() {
        let controller = EjectFlowController()
        let disk = makeDisk()

        let busy = controller.failureMessage(disk: disk, failure: .inUse)
        let gone = controller.failureMessage(disk: disk, failure: .notFound)

        #expect(busy != gone, "不同失败原因必须给出不同引导，不能都显示同一句")
        #expect(busy == String(format: L10n.tr(.ejectFailedInUseReason, locale: zhHans), "测试盘"))
    }

    // MARK: EjectUI.processListView

    /// `processListView` 必须返回有足够宽度的 view，否则 NSAlert 会把裸 NSStackView 压缩
    /// 到最小区域、漂到按钮右上角（图 + 文被排成单行贴按钮）。
    /// 之前回归过一次：用户截图显示图标在弹窗右下角按钮上方，就是这个原因。
    @MainActor
    @Test func processListView容器有足够宽度避免被alert挤压() {
        let view = EjectUI.processListView([OccupyingProcess(pid: 42, name: "IINA", path: "")])
        #expect(view.frame.width >= 200, "accessoryView 容器必须有明确宽度，NSAlert 才能正确摆放")
    }
}
