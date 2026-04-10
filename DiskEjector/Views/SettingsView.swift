import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visualStyle") private var visualStyle = "transparent"
    @AppStorage("accentColor") private var accentColor = "blue"
    
    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "gear")
                    .foregroundColor(.accentColor)
                Text("设置")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Visual Style
                    VStack(alignment: .leading, spacing: 12) {
                        Text("视觉效果")
                            .font(.headline)
                        
                        VStack(spacing: 8) {
                            styleOption(
                                title: "透明模式",
                                subtitle: "macOS Liquid Glass 毛玻璃效果（需 macOS 13+）",
                                value: "transparent",
                                icon: "rectangle.on.rectangle"
                            )
                            styleOption(
                                title: "色调模式",
                                subtitle: "系统背景色，兼容深色/浅色模式",
                                value: "tinted",
                                icon: "paintpalette"
                            )
                        }
                    }
                    
                    // Accent Color
                    VStack(alignment: .leading, spacing: 12) {
                        Text("强调色")
                            .font(.headline)
                        
                        HStack(spacing: 12) {
                            colorOption(value: "blue", color: .blue, name: "蓝色")
                            colorOption(value: "green", color: .green, name: "绿色")
                            colorOption(value: "red", color: .red, name: "红色")
                            colorOption(value: "purple", color: .purple, name: "紫色")
                            colorOption(value: "orange", color: .orange, name: "橙色")
                            colorOption(value: "yellow", color: .yellow, name: "黄色")
                        }
                        .padding(.horizontal, 4)
                    }
                    
                    Divider()
                    
                    // About
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关于")
                            .font(.headline)
                        
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DiskEjector")
                                    .font(.callout.bold())
                                Text("版本 1.0.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 400, height: 380)
    }
    
    @ViewBuilder
    private func styleOption(title: String, subtitle: String, value: String, icon: String) -> some View {
        Button {
            visualStyle = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if visualStyle == value {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                visualStyle == value
                    ? Color.accentColor.opacity(0.08)
                    : Color.secondary.opacity(0.05)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func colorOption(value: String, color: Color, name: String) -> some View {
        Button {
            accentColor = value
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if accentColor == value {
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .frame(width: 40, height: 40)
                        }
                    }
                Text(name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
        .buttonStyle(.plain)
    }
}