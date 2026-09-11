import Foundation
import OSLog

/// 面向用户的错误日志（落盘），对应 SPEC F7。
///
/// **与 `os.Logger` 的分工**：本项目同时存在两套日志，职责不同，不要合并。
/// - `os.Logger`：开发诊断，写入系统日志，用户可在 Console 中按 subsystem 过滤；不落盘。
/// - ``LogService``：SPEC F7 要求的错误日志，写入 `~/Library/Logs/DiskEjector/error.log`，
///   供用户排查或反馈问题时提供。
///
/// 此前 ``LogService`` 已实现但从未被调用——SPEC 的 F7 实际未落地。现在由
/// ``EjectFlowController`` 在推出失败时调用。
final class LogService: @unchecked Sendable {

    static let shared = LogService()

    /// 单个日志文件上限；超过后轮转一份历史，避免长期运行后无限增长。
    private static let maxFileSize: UInt64 = 512 * 1024

    /// 时间格式化器。
    ///
    /// **为什么是实例属性而非 static**：`ISO8601DateFormatter` 不是 `Sendable`，
    /// Swift 6 严格并发下不允许作为可变的全局/静态状态。本类已是 `@unchecked Sendable`
    /// 且所有写入路径都持 ``lock``，实例属性因此是安全的，同时避免了每条日志重建格式化器。
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private let logURL: URL
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.diskejector.app", category: "LogService")

    private init() {
        // 拿不到 Library 目录时退回临时目录，而不是强解包导致启动崩溃。
        let libraryURL =
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let logDir = libraryURL.appendingPathComponent("Logs/DiskEjector", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            logger.error("创建日志目录失败: \(error.localizedDescription, privacy: .public)")
        }

        self.logURL = logDir.appendingPathComponent("error.log")
    }

    /// 日志文件路径，便于设置面板展示或用户手动取用。
    var fileURL: URL { logURL }

    /// 写入一条错误日志。线程安全，可从任意线程调用。
    ///
    /// - Parameter disk: 关联的磁盘名；与磁盘无关的日志（如登录项设置失败）传 `nil`。
    func log(disk: String?, message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = timestampFormatter.string(from: Date())
        let scope = disk.map { "[\($0)] " } ?? ""
        let entry = "[\(timestamp)] \(scope)\(message)\n"
        guard let data = entry.data(using: .utf8) else { return }

        rotateIfNeeded()

        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            logger.error("写入日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 超过体积上限时保留一份历史文件并重建当前日志。
    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: logURL.path),
            let size = attrs[.size] as? UInt64,
            size >= Self.maxFileSize
        else {
            return
        }

        let backupURL = logURL.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension("log")
        try? manager.removeItem(at: backupURL)
        try? manager.moveItem(at: logURL, to: backupURL)
    }
}
