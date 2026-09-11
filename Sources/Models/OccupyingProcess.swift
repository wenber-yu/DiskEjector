import AppKit
import Foundation

/// 一个正在访问外置卷的进程。
///
/// **关于命名**：此前该类型叫 `ProcessInfo`，与 Foundation 的 `ProcessInfo` 同名，
/// 导致测试文件里不得不写 `private typealias AppProcessInfo = DiskEjectorApp.ProcessInfo`
/// 来消除歧义——命名冲突的成本已经外溢到调用方，这本身就是该改名的信号。
struct OccupyingProcess: Identifiable, Sendable, Equatable {

    /// 进程标识符，同时作为 `Identifiable` 的 id。
    ///
    /// 此前是 `let id = UUID()`，与基于 pid 的 `==` / `hash` 语义冲突：两个 pid 相同的实例
    /// 被判为相等，id 却不同。SwiftUI 的 diff 依赖 `Identifiable`，这类不一致会在列表刷新时
    /// 表现为「整行被重建」的闪烁。
    var id: Int32 { pid }

    let pid: Int32
    let name: String
    let path: String

    /// 匹配运行中的应用图标，无匹配时返回系统通用应用图标。
    ///
    /// 需要 `@MainActor`：`NSWorkspace` 是主 actor 隔离类型。
    @MainActor
    func appIcon() -> NSImage? {
        let workspace = NSWorkspace.shared
        let lowerName = name.lowercased()
        for app in workspace.runningApplications {
            guard let appName = app.localizedName?.lowercased() else { continue }
            if appName == lowerName || lowerName.contains(appName) || appName.contains(lowerName) {
                return app.icon
            }
        }
        return workspace.icon(for: .application)
    }
}
