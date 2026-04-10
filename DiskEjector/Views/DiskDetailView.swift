import SwiftUI

struct DiskDetailView: View {
    let disk: DiskInfo
    @ObservedObject var viewModel: DiskListViewModel
    @Binding var isPresented: Bool

    private var processes: [ProcessInfo] {
        viewModel.processes[disk.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            capacitySection
            Divider()
            processListSection
            Spacer()
            if let msg = viewModel.statusMessage {
                statusBar(message: msg)
            }
            bottomActionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(disk.displayName)
                            .font(.title2.bold())
                        Text("挂载路径: \(disk.mountPath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            // 添加关闭按钮
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .padding(.trailing, 10)
        }
        .padding()
    }

    // MARK: - Capacity

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("容量")
                .font(.headline)
            // Fixed-size bar, no GeometryReader
            HStack(spacing: 6) {
                CapacityBar(percent: disk.usagePercent)
                    .frame(height: 12)
                Text("\(Int(disk.usagePercent * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Label(disk.usedFormatted, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Spacer()
                Label(disk.freeFormatted + " 可用", systemImage: "circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(disk.totalFormatted)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Process List

    private var processListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("占用进程")
                    .font(.headline)
                Spacer()
                Text("\(processes.count) 个")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }

            if processes.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("无进程占用，可以安全推出")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(processes) { proc in
                            HStack(spacing: 8) {
                                Image(systemName: appIconName(for: proc.name))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 16)
                                Text(proc.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text("PID: \(proc.pid)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding()
    }

    // MARK: - Status & Action

    private func statusBar(message: String) -> some View {
        let isError = message.contains("失败") || message.contains("错误")
        return HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
            Text(message)
                .font(.caption)
                .foregroundColor(isError ? .red : .secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    private var bottomActionBar: some View {
        HStack {
            Button(action: { isPresented = false }) {
                Text("取消")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button {
                viewModel.requestEject(disk: disk)
            } label: {
                HStack {
                    if viewModel.isEjecting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "eject.fill")
                    }
                    Text(viewModel.isEjecting ? "推出中…" : "推出磁盘")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isEjecting)
        }
        .padding()
    }

    private func appIconName(for processName: String) -> String {
        switch processName.lowercased() {
        case "finder": return "folder.fill"
        case "photos", "photoimport", "photolibraryd": return "photo.fill"
        case "cp", "mv", "rsync": return "arrow.left.arrow.right"
        case "terminal", "bash", "zsh": return "terminal.fill"
        case "safari", "google chrome", "firefox": return "globe"
        default: return "app.fill"
        }
    }
}