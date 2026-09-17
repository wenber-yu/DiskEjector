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
}
