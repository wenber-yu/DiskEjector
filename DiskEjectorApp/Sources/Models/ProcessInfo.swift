import Foundation
import AppKit
import UniformTypeIdentifiers

struct ProcessInfo: Identifiable, Hashable {
    let id = UUID()
    let pid: Int32
    let name: String
    let path: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: ProcessInfo, rhs: ProcessInfo) -> Bool {
        lhs.pid == rhs.pid
    }
    
    // 获取应用图标
    func getAppIcon() -> NSImage? {
        let workspace = NSWorkspace.shared

        print("Getting icon for process: \(name) (PID: \(pid))")

        let apps = workspace.runningApplications
        print("Found \(apps.count) running applications")

        for app in apps {
            if let appName = app.localizedName?.lowercased() {
                print("Checking app: \(app.localizedName ?? "Unknown")")
                if appName == name.lowercased() || name.lowercased().contains(appName) || appName.contains(name.lowercased()) {
                    print("Found matching app: \(app.localizedName ?? "Unknown")")
                    return app.icon
                }
            }
        }

        let icon = workspace.icon(for: .application)
        print("Got generic app icon")
        return icon
    }
}
