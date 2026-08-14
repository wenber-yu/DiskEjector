import SwiftUI

/// 设置面板（对齐 ProxyGenerator 项目的 UI 风格）：
/// NavigationStack + Form + grouped，设置项即时生效（@AppStorage 直接绑定）。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visualStyle") private var visualStyle = "transparent"
    @AppStorage("accentColor") private var accentColor = "blue"
    @AppStorage("showDockIcon") private var showDockIcon = false
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled
    @State private var showLaunchAtLoginError = false

    /// 从 Info.plist 读取版本号（打包时注入），缺失时回退 "1.0.0"。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 视觉效果
                Section {
                    Picker(L10n.tr(.visualEffects), selection: $visualStyle) {
                        Text(L10n.tr(.transparentMode)).tag("transparent")
                        Text(L10n.tr(.tintedMode)).tag("tinted")
                    }
                    .pickerStyle(.menu)
                    Text(L10n.tr(.transparentModeFootnote))
                        .font(AppFont.minor)
                        .foregroundStyle(.secondary)
                }

                // MARK: 强调色
                Section(L10n.tr(.accentColor)) {
                    Picker(L10n.tr(.accentColor), selection: $accentColor) {
                        Text(L10n.tr(.colorBlue)).tag("blue")
                        Text(L10n.tr(.colorGreen)).tag("green")
                        Text(L10n.tr(.colorRed)).tag("red")
                        Text(L10n.tr(.colorPurple)).tag("purple")
                        Text(L10n.tr(.colorOrange)).tag("orange")
                        Text(L10n.tr(.colorYellow)).tag("yellow")
                    }
                    .pickerStyle(.menu)
                }

                // MARK: Dock 图标
                Section {
                    Toggle(L10n.tr(.showDockIcon), isOn: $showDockIcon)
                }

                // MARK: 开机启动
                Section {
                    Toggle(L10n.tr(.launchAtLogin), isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                try LaunchAtLoginManager.setEnabled(newValue)
                                launchAtLogin = newValue
                            } catch {
                                showLaunchAtLoginError = true
                            }
                        }
                    ))
                    Text(L10n.tr(.launchAtLoginFootnote))
                        .font(AppFont.minor)
                        .foregroundStyle(.secondary)
                }

                // MARK: 关于
                Section(L10n.tr(.aboutSection)) {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DiskEjector")
                                .font(AppFont.labelBold)
                            Text(String(format: L10n.tr(.versionFormat), appVersion))
                                .font(AppFont.minor)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .font(AppFont.control)
            .navigationTitle(L10n.tr(.settings))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr(.done)) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 460)
        .alert(L10n.tr(.launchAtLoginErrorTitle), isPresented: $showLaunchAtLoginError) {
            Button(L10n.tr(.ok), role: .cancel) {}
        } message: {
            Text(L10n.tr(.launchAtLoginErrorMessage))
        }
    }
}
