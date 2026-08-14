import AppKit
import ServiceManagement

/// 开机自启动（登录项）管理。
///
/// 基于 macOS 13+ 的 `SMAppService.mainApp` 将当前应用注册为登录项。
/// 持久化偏好存于 UserDefaults（键 `launchAtLogin`）；`syncAtLaunch()` 在应用启动时
/// 把「持久化偏好」与「系统登录项实际状态」对齐（处理用户在系统设置里手动变更的情况）。
@MainActor
enum LaunchAtLoginManager {

    /// 持久化键，与 SettingsView 的 Toggle 共用。
    static let defaultsKey = "launchAtLogin"

    /// 当前持久化的偏好值。
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// 应用启动时对齐登录项状态：偏好开启但系统未注册则补注册，偏好关闭但系统已注册则注销。
    static func syncAtLaunch() {
        let status = SMAppService.mainApp.status
        if isEnabled && status != .enabled {
            try? SMAppService.mainApp.register()
        } else if !isEnabled && status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
    }

    /// 切换登录项：成功才写回偏好；失败抛错，由 UI 保持开关原状并提示用户。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }
}
