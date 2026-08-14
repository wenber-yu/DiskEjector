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
                    // 透明模式：系统液态玻璃背景（对齐 ProxyGenerator）
                    VisualEffectBackground()
                        .ignoresSafeArea()
                } else {
                    // 色调模式：使用带透明度的系统背景色
                    backgroundColor
                        .ignoresSafeArea()
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if disks.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(disks, id: \.id) { disk in
                                diskRowView(disk)
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 400, minHeight: 300)
            .toolbar {
                // 刷新按钮
                ToolbarItem(placement: .primaryAction) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .animation(.easeInOut(duration: 0.3), value: isRefreshing)
                    } else {
                        Button(action: manuallyRefreshDisks) {
                            Label(L10n.tr(.refresh), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .animation(.easeInOut(duration: 0.3), value: isRefreshing)
                    }
                }
                
                // 设置按钮
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showSettings = true }) {
                        Label(L10n.tr(.settings), systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(AppFont.control)
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
            .alert(L10n.tr(.ejectFailedTitle), isPresented: $showErrorAlert) {
                Button(L10n.tr(.ok), role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .background(WindowAccessor { window in
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        })
    }
    
    private func diskRowView(_ disk: DiskInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(AppFont.rowGlyph)
                .foregroundColor(accentColorValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(disk.volumeName)
                    .font(AppFont.rowTitle)
                Text(String(format: L10n.tr(.freeSpaceFormat), formatBytes(disk.freeBytes), formatBytes(disk.totalBytes)))
                    .font(AppFont.label)
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
                        .font(AppFont.rowGlyph)
                }
            }
            .buttonStyle(.borderless)
            .disabled(ejectingDiskId != nil)
            .opacity(ejectingDiskId != nil ? 0.5 : 1)
        }
        .cardStyle()
    }
    
    private func createAlert() -> Alert {
        if !processesToKill.isEmpty {
            let processList = processesToKill
                .map { String(format: L10n.tr(.processItemFormat), $0.name, $0.pid) }
                .joined(separator: "\n")
            return Alert(
                title: Text(L10n.tr(.confirmEjectTitle)),
                message: Text(String(format: L10n.tr(.occupiedProcessesMessage), processList)),
                primaryButton: .destructive(Text(L10n.tr(.confirmTerminateAndEject))) {
                    if let disk = diskToEject {
                        eject(disk: disk, processes: processesToKill)
                    }
                },
                secondaryButton: .cancel(Text(L10n.tr(.cancel))) {
                    ejectingDiskId = nil
                }
            )
        } else {
            return Alert(
                title: Text(L10n.tr(.confirmEjectTitle)),
                message: Text(L10n.tr(.confirmEjectMessage)),
                primaryButton: .destructive(Text(L10n.tr(.confirm))) {
                    if let disk = diskToEject {
                        eject(disk: disk, processes: processesToKill)
                    }
                },
                secondaryButton: .cancel(Text(L10n.tr(.cancel))) {
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
        VStack(spacing: 16) {
            Image(systemName: "externaldrive")
                .font(AppFont.emptyGlyph)
                .foregroundColor(.secondary)
            Text(L10n.tr(.noRemovableDisks))
                .font(AppFont.cardTitle)
                .foregroundColor(.secondary)
            Text(L10n.tr(.insertDiskHint))
                .font(AppFont.label)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .cardStyle()
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
