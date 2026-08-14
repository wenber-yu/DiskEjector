import SwiftUI

/// 设置面板（对齐 ProxyGenerator 项目的 UI 风格）：
/// NavigationStack + Form + grouped，设置项即时生效（@AppStorage 直接绑定）。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visualStyle") private var visualStyle = "transparent"
    @AppStorage("accentColor") private var accentColor = "blue"
    @AppStorage("showDockIcon") private var showDockIcon = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 视觉效果
                Section {
                    Picker("视觉效果", selection: $visualStyle) {
                        Text("透明模式（Liquid Glass 毛玻璃）").tag("transparent")
                        Text("色调模式（系统背景色）").tag("tinted")
                    }
                    .pickerStyle(.menu)
                    Text("透明模式使用 macOS Liquid Glass 毛玻璃效果（需 macOS 13+）")
                        .font(AppFont.minor)
                        .foregroundStyle(.secondary)
                }

                // MARK: 强调色
                Section("强调色") {
                    Picker("强调色", selection: $accentColor) {
                        Text("蓝色").tag("blue")
                        Text("绿色").tag("green")
                        Text("红色").tag("red")
                        Text("紫色").tag("purple")
                        Text("橙色").tag("orange")
                        Text("黄色").tag("yellow")
                    }
                    .pickerStyle(.menu)
                }

                // MARK: Dock 图标
                Section {
                    Toggle("显示 Dock 图标", isOn: $showDockIcon)
                }

                // MARK: 关于
                Section("关于") {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DiskEjector")
                                .font(AppFont.labelBold)
                            Text("版本 1.0.0")
                                .font(AppFont.minor)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .font(AppFont.control)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 460)
    }
}
