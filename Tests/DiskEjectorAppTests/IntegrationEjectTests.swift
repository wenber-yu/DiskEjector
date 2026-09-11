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
@MainActor
struct IntegrationEjectTests {

    @Test func 真实占用时关闭进程并推出() async throws {
        // 环境不支持挂载磁盘映像时优雅跳过（CI 沙盒等），不判失败。
        guard Self.canAttachDiskImage() else { return }

        let dmg = "/tmp/DiskEjectorEjectTest.dmg"
        let vol = "/Volumes/DiskEjectorEjectTest"
        try? shell("hdiutil detach \(vol) 2>/dev/null")
        try? FileManager.default.removeItem(atPath: dmg)
        try shell("hdiutil create -size 5m -fs HFS+ -volname DiskEjectorEjectTest \(dmg)")
        try shell("hdiutil attach \(dmg) -nobrowse")
        try "hi".write(toFile: "\(vol)/x.txt", atomically: true, encoding: .utf8)

        // 制造一个真实占用进程（tail -f 持续打开文件）。
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", "\(vol)/x.txt"]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()

        defer {
            tail.terminate()
            try? shell("hdiutil detach \(vol) 2>/dev/null")
            try? FileManager.default.removeItem(atPath: dmg)
        }

        guard let disk = DiskService.shared.fetchExternalDisks().first(where: { $0.mountPath == vol }) else {
            Issue.record("未找到测试盘 \(vol)")
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

    /// 探测当前环境能否挂载磁盘映像：尝试挂载并立即卸载一个最小 dmg。
    /// 成功返回 true（顺带清理），失败返回 false（测试将跳过）。
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
        _ = s("hdiutil detach \(vol)")
        _ = s("rm -f \(dmg)")
        return true
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
            throw NSError(domain: "shell", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: command])
        }
    }
}
