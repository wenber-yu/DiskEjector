import Foundation

@MainActor
final class LogService {
    static let shared = LogService()

    private let logURL: URL

    private init() {
        let libPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logDir = libPath.appendingPathComponent("Logs/DiskEjector", isDirectory: true)

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logURL = logDir.appendingPathComponent("error.log")
    }

    func log(disk: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(disk)] \(message)\n"

        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try? FileHandle(forWritingTo: logURL)
            handle?.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle?.write(data)
            }
            handle?.closeFile()
        } else {
            try? entry.data(using: .utf8)?.write(to: logURL)
        }
    }
}
