import SwiftUI

struct ContentView: View {
    @State private var disks: [DiskInfo] = []
    @State private var isRefreshing = false
    @State private var ejectingDiskId: String? = nil
    @State private var showSettings = false
    @State private var showConfirmDialog = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var diskToEject: DiskInfo? = nil
    @State private var processesToKill: [ProcessInfo] = []
    @AppStorage("visualStyle") private var visualStyle = "transparent"
    @AppStorage("accentColor") private var accentColor = "blue"
    @State private var volumeSource: DispatchSourceFileSystemObject?
    
    private let diskService = DiskService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                if visualStyle == "transparent" {
                    // 透明模式：使用系统控制中心样式的材质
                    Color.clear
                        .background(.ultraThinMaterial)
                        .edgesIgnoringSafeArea(.all)
                } else {
                    // 色调模式：使用带透明度的系统背景色
                    backgroundColor
                }
                VStack(spacing: 0) {
                    if disks.isEmpty {
                        emptyStateView
                    } else {
                        List {
                            ForEach(disks, id: \.id) { disk in
                                diskRowView(disk)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets())
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden) // 隐藏 List 的滚动内容背景
                        .padding()
                        .background(Color.clear)
                    }
                }
                .background(Color.clear)
            }
            .frame(minWidth: 400, minHeight: 300)
            .toolbar {
                // 刷新按钮
                ToolbarItem(placement: .primaryAction) {
                    Button(action: manuallyRefreshDisks) {
                        if isRefreshing {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                    .foregroundColor(accentColorValue)
                                Text("刷新中...")
                                    .font(.caption)
                                    .padding(.leading, 4)
                                    .foregroundColor(accentColorValue)
                            }
                        } else {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(accentColorValue)
                                Text("刷新")
                                    .font(.caption)
                                    .padding(.leading, 4)
                                    .foregroundColor(accentColorValue)
                            }
                        }
                    }
                    .disabled(isRefreshing)
                    .animation(.easeInOut(duration: 0.3), value: isRefreshing)
                }
                
                // 设置按钮
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundColor(accentColorValue)
                            Text("设置")
                                .font(.caption)
                                .padding(.leading, 4)
                                .foregroundColor(accentColorValue)
                        }
                    }
                }
            }
            .onAppear {
                print("ContentView onAppear called")
                refreshDisks()
                setupVolumeObserver()
            }
            .onDisappear {
                volumeSource?.cancel()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert(isPresented: $showConfirmDialog) {
                createAlert()
            }
            .alert("推出失败", isPresented: $showErrorAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func diskRowView(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .font(.title)
                    .foregroundColor(accentColorValue)
                VStack(alignment: .leading) {
                    Text(disk.volumeName)
                        .font(.headline)
                    Text("可用空间: \(formatBytes(disk.freeBytes)) / \(formatBytes(disk.totalBytes))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { handleEject(disk) }) {
                    if ejectingDiskId == disk.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "eject.fill")
                            .foregroundColor(.red)
                    }
                }
                .disabled(ejectingDiskId != nil)
                .opacity(ejectingDiskId != nil ? 0.5 : 1)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(visualStyle == "transparent" ? Color(NSColor.windowBackgroundColor).opacity(0.7) : backgroundColor))
        .padding(.vertical, 4)
    }
    
    private func createAlert() -> Alert {
        if !processesToKill.isEmpty {
            return Alert(
                title: Text("确认推出磁盘"),
                message: Text("以下程序正在访问此磁盘，关闭它们可能导致数据丢失（未保存的工作将被丢弃）：\n\n" + processesToKill.map { "• \($0.name) (PID: \($0.pid))" }.joined(separator: "\n")),
                primaryButton: .destructive(Text("确认终止并推出")) {
                    if let disk = diskToEject {
                        eject(disk: disk, processes: processesToKill)
                    }
                },
                secondaryButton: .cancel(Text("取消")) {
                    ejectingDiskId = nil
                }
            )
        } else {
            return Alert(
                title: Text("确认推出磁盘"),
                message: Text("确定要推出此磁盘吗？"),
                primaryButton: .destructive(Text("确认")) {
                    if let disk = diskToEject {
                        eject(disk: disk, processes: processesToKill)
                    }
                },
                secondaryButton: .cancel(Text("取消")) {
                    ejectingDiskId = nil
                }
            )
        }
    }
    
    private var backgroundColor: Color {
        if visualStyle == "transparent" {
            // 透明模式：使用系统默认的窗口背景色
            return Color.clear
        } else {
            // 色调模式：使用带透明度的系统背景色
            return Color(NSColor.windowBackgroundColor).opacity(0.85)
        }
    }
    
    private var accentColorValue: Color {
        switch accentColor {
        case "blue": return .blue
        case "green": return .green
        case "red": return .red
        case "purple": return .purple
        case "orange": return .orange
        case "yellow": return .yellow
        default: return .blue
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("没有可移动磁盘")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("请插入移动硬盘或U盘")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
    

    
    private func setupVolumeObserver() {
        let volumesPath = "/Volumes"
        let fileDescriptor = open(volumesPath, O_EVTONLY)
        
        guard fileDescriptor != -1 else {
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.main
        )
        
        source.setEventHandler {
            scheduleRefresh()
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        volumeSource = source
    }
    
    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshDisks()
        }
    }
    
    private func refreshDisks() {
        print("refreshDisks called")
        isRefreshing = true
        
        DispatchQueue.global(qos: .userInitiated).async { 
            print("Fetching disks...")
            let fetchedDisks = self.diskService.fetchExternalDisks()
            print("Fetched \(fetchedDisks.count) disks")
            
            DispatchQueue.main.async {
                print("Updating disks")
                print("Disks count: \(fetchedDisks.count)")
                self.disks = fetchedDisks
                self.isRefreshing = false
                print("Refresh completed")
            }
        }
    }
    
    private func manuallyRefreshDisks() {
        refreshDisks()
    }
    
    /// 推出入口：实时检查占用进程（不依赖列表刷新时的缓存，避免时序隐患），
    /// 无占用直接推出，有占用弹确认框。与菜单栏共用 EjectFlowController。
    private func handleEject(_ disk: DiskInfo) {
        ejectingDiskId = disk.id
        
        EjectFlowController.shared.checkOccupiedProcesses(mountPath: disk.mountPath) { processes in
            // completion 保证在主线程回调，安全切回主 actor
            MainActor.assumeIsolated {
                if processes.isEmpty {
                    // 没有进程占用，直接推出
                    self.eject(disk: disk, processes: [])
                } else {
                    // 有进程占用，显示确认对话框
                    self.diskToEject = disk
                    self.processesToKill = processes
                    self.showConfirmDialog = true
                }
            }
        }
    }
    
    /// 统一执行推出（经由 EjectFlowController）：成功仅刷新列表，失败弹出错误提示。
    private func eject(disk: DiskInfo, processes: [ProcessInfo]) {
        EjectFlowController.shared.eject(disk: disk, processes: processes) { result in
            // completion 保证在主线程回调，安全切回主 actor
            MainActor.assumeIsolated {
                self.ejectingDiskId = nil
                
                switch result {
                case .success:
                    self.refreshDisks()
                case .failure(let error):
                    print("Failed to eject disk: \(error.localizedDescription)")
                    self.errorMessage = EjectFlowController.shared.failureMessage(disk: disk, error: error)
                    self.showErrorAlert = true
                    self.refreshDisks()
                }
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unitIndex = 0
        
        while size > 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        
        return String(format: "%.1f %@", size, units[unitIndex])
    }
}

// 用于实现毛玻璃效果的视图
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground // 使用系统控制中心样式的材质
        view.blendingMode = .behindWindow // 使用 behindWindow 模式以获得更好的通透感
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // 不需要更新
    }
}
