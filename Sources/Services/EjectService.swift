import AppKit
import Foundation
import OSLog

/// 推出失败的原因分类。
///
/// **为什么不用裸 `Error`**：调用方需要根据失败原因给出完全不同的引导——「磁盘正被使用」应当
/// 提示用户关闭程序后重试，而「权限不足」或「设备已消失」提示重试毫无意义。若只在 UI 层
/// 用 `localizedDescription` 做字符串匹配，一旦系统改动文案就会全部失配。
enum EjectFailure: Error, Sendable, Equatable {

    /// 卷上有进程正在读写（系统返回 `fBsyErr` / `EBUSY`）。
    case inUse

    /// 系统拒绝该操作（例如目标并非可推出设备）。
    case notPermitted

    /// 设备已不在（可能在操作完成前被拔掉或已卸载）。
    case notFound

    /// 未归类的失败，保留原始错误以便诊断。
    case other(String)

    /// 把系统抛出的错误归类。
    ///
    /// 实测（macOS，App Sandbox 内）：对正被进程占用的卷调用
    /// `NSWorkspace.unmountAndEjectDevice(at:)` 会抛出
    /// `NSOSStatusErrorDomain code = -47`，即 `fBsyErr`。
    static func classify(_ error: Error) -> EjectFailure {
        let ns = error as NSError

        // POSIX 层：EBUSY = 16，ENOENT = 2，EPERM / EACCES
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case 16: return .inUse
            case 2: return .notFound
            case 1, 13: return .notPermitted
            default: break
            }
        }

        // OSStatus 层：fBsyErr = -47，fnfErr = -43，permErr = -54，notPermitted = -5000
        if ns.domain == NSOSStatusErrorDomain {
            switch ns.code {
            case -47: return .inUse
            case -43: return .notFound
            case -54, -5000: return .notPermitted
            default: break
            }
        }

        // 兜底：系统未提供结构化错误码时，退而求其次匹配描述文本。
        let text = ns.localizedDescription.lowercased()
        if text.contains("in use") || text.contains("busy") { return .inUse }

        return .other(ns.localizedDescription)
    }

    /// 面向用户的原因说明（本地化）。
    func reasonText(diskName: String) -> String {
        switch self {
        case .inUse:
            return String(format: L10n.tr(.ejectFailedInUseReason), diskName)
        case .notPermitted:
            return String(format: L10n.tr(.ejectFailedNotPermittedReason), diskName)
        case .notFound:
            return String(format: L10n.tr(.ejectFailedNotFoundReason), diskName)
        case .other(let detail):
            return String(format: L10n.tr(.ejectFailedOtherReason), diskName, detail)
        }
    }

    /// 写入日志文件的诊断信息。
    var logText: String {
        switch self {
        case .inUse: return "inUse(fBsyErr)"
        case .notPermitted: return "notPermitted"
        case .notFound: return "notFound"
        case .other(let detail): return "other(\(detail))"
        }
    }
}

/// 磁盘推出执行器。
///
/// **为什么不再用 `diskutil unmount force`**：
/// 1. `force` 会绕过「有进程占用就失败」这层系统保护，在磁盘正被写入时强行卸载，
///    是数据损坏的直接来源；
/// 2. 它是外部命令行工具，在 App Sandbox 下依赖 fork/exec 系统二进制，不是上架版本
///    应该依赖的路径（实测沙盒内 `lsof` 已完全失效，同类依赖随时可能失效）。
///
/// 现改用 `NSWorkspace.unmountAndEjectDevice(at:)`：这是 AppKit 公开 API，等价于 Finder 的
/// 「推出」，实测在 App Sandbox 内可正常工作，且占用时会返回结构化错误而非强行卸载。
class EjectService: @unchecked Sendable {
    static let shared = EjectService()

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init() {}

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "EjectService")

    /// 推出指定卷。
    ///
    /// 内部在后台线程执行，不会阻塞调用方；`unmountAndEjectDevice` 本身线程安全。
    /// - Returns: 成功或已归类的失败原因。
    func eject(disk: DiskInfo) async -> Result<Void, EjectFailure> {
        let url = URL(fileURLWithPath: disk.mountPath)
        Self.logger.notice("请求推出卷: \(disk.mountPath, privacy: .public)")

        return await Task.detached(priority: .userInitiated) { [url] in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return .success(())
            } catch {
                let failure = EjectFailure.classify(error)
                Self.logger.error("推出失败: \(failure.logText, privacy: .public)")
                return .failure(failure)
            }
        }.value
    }
}
