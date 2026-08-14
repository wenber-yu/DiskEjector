import AppKit
import SwiftUI

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow!
    private let diskService = DiskService.shared
    private let processService = ProcessService.shared
    
    private var currentDisks: [DiskInfo] = []
    private var ejectButtons: [String: NSButton] = [:]
    private var ejectingDiskId: String?
    private var accentColor: String {
        return UserDefaults.standard.string(forKey: "accentColor") ?? "blue"
    }
    
    private var accentColorValue: NSColor {
        switch accentColor {
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "red": return .systemRed
        case "purple": return .systemPurple
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        default: return .systemBlue
        }
    }
    
    // 更新 Dock 图标可见性
    private func updateDockIconVisibility() {
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        print("Dock icon visibility updated: \(showDockIcon)")
    }
    
    // 监听 UserDefaults 变化（KVO 回调在主线程触发）
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated {
            if keyPath == "showDockIcon" {
                updateDockIconVisibility()
            } else if keyPath == "accentColor" {
                refreshDiskList()
            }
        }
    }

    static func main() {
        print("Starting DiskEjector")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("DiskEjector launched")

        if let appIcon = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "DiskEjector") {
            NSApp.applicationIconImage = appIcon
            print("Application icon set successfully")
        }

        updateDockIconVisibility()

        UserDefaults.standard.addObserver(self, forKeyPath: "showDockIcon", options: .new, context: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            print("Failed to get status item button")
            return
        }

        print("Got status item button")

        let ejectImage = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        button.image = ejectImage
        button.toolTip = "DiskEjector"

        print("Button image set: \(button.image != nil)")

        refreshDiskList()

        print("Menu bar setup complete")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setupMainWindow()
            print("Main window setup complete")
        }

        setupDiskMonitoring()

        setupAccentColorMonitoring()
    }

    private func setupAccentColorMonitoring() {
        UserDefaults.standard.addObserver(self, forKeyPath: "accentColor", options: [.new], context: nil)
    }

    private func setupDiskMonitoring() {
        let workspace = NSWorkspace.shared
        
        NotificationCenter.default.addObserver(forName: NSWorkspace.didMountNotification, object: workspace, queue: .main) { [weak self] notification in
            print("=== Disk mounted notification received ===")
            if let volumeURL = notification.userInfo?["NSWorkspaceVolumeURLKey"] as? URL {
                print("Mounted volume URL: \(volumeURL)")
            }
            print("Refreshing disk list...")
            MainActor.assumeIsolated {
                self?.refreshDiskList()
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSWorkspace.didUnmountNotification, object: workspace, queue: .main) { [weak self] notification in
            print("=== Disk unmounted notification received ===")
            if let volumeURL = notification.userInfo?["NSWorkspaceVolumeURLKey"] as? URL {
                print("Unmounted volume URL: \(volumeURL)")
            }
            print("Refreshing disk list...")
            MainActor.assumeIsolated {
                self?.refreshDiskList()
            }
        }
        
        print("Disk monitoring setup complete")
    }
    
    private func refreshDiskList() {
        print("=== refreshDiskList called ===")
        currentDisks = diskService.fetchExternalDisks()
        print("Found \(currentDisks.count) disks")
        for (index, disk) in currentDisks.enumerated() {
            print("Disk \(index): \(disk.displayName), mountPath: \(disk.mountPath)")
        }
        ejectButtons.removeAll()
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        let spaceItem = NSMenuItem()
        spaceItem.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        menu.addItem(spaceItem)
        
        let titleItem = NSMenuItem()
        let titleView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let titleLabel = NSTextField(frame: NSRect(x: 12, y: 0, width: 380, height: 20))
        titleLabel.stringValue = "硬盘列表"
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleView.addSubview(titleLabel)
        titleItem.view = titleView
        menu.addItem(titleItem)
        
        menu.addItem(.separator())
        
        if currentDisks.isEmpty {
            let noDiskItem = NSMenuItem(title: "没有可推出的磁盘", action: nil, keyEquivalent: "")
            noDiskItem.isEnabled = false
            menu.addItem(noDiskItem)
        } else {
            for (index, disk) in currentDisks.enumerated() {
                let customView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
                customView.wantsLayer = true
                
                if let diskImage = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Disk") {
                    let diskImageView = NSImageView(frame: NSRect(x: 12, y: 16, width: 16, height: 16))
                    diskImageView.image = diskImage
                    diskImageView.contentTintColor = accentColorValue
                    customView.addSubview(diskImageView)
                }
                
                let infoContainer = NSView(frame: NSRect(x: 36, y: 8, width: 280, height: 32))
                customView.addSubview(infoContainer)
                
                let nameLabel = NSTextField(frame: NSRect(x: 0, y: 12, width: 280, height: 16))
                nameLabel.stringValue = disk.displayName
                nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
                nameLabel.isBezeled = false
                nameLabel.drawsBackground = false
                nameLabel.isEditable = false
                nameLabel.isSelectable = false
                infoContainer.addSubview(nameLabel)
                
                let usageLabel = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 12))
                let usedBytes = disk.totalBytes - disk.freeBytes
                let usagePercentage = Double(usedBytes) / Double(disk.totalBytes) * 100
                usageLabel.stringValue = String(format: "%.1f%% 已使用 (%@ / %@)", usagePercentage, formatBytes(usedBytes), formatBytes(disk.totalBytes))
                usageLabel.font = NSFont.systemFont(ofSize: 11)
                usageLabel.textColor = NSColor.secondaryLabelColor
                usageLabel.isBezeled = false
                usageLabel.drawsBackground = false
                usageLabel.isEditable = false
                usageLabel.isSelectable = false
                infoContainer.addSubview(usageLabel)
                
                let ejectButton = NSButton(frame: NSRect(x: 330, y: 12, width: 60, height: 24))
                ejectButton.target = self
                ejectButton.action = #selector(ejectDiskButton(_:))
                ejectButton.tag = index
                ejectButton.bezelStyle = .rounded
                ejectButton.contentTintColor = accentColorValue
                ejectButton.setButtonType(.momentaryPushIn)
                
                if ejectingDiskId == disk.id {
                    ejectButton.title = ""
                    ejectButton.isEnabled = false
                    
                    let progressIndicator = NSProgressIndicator(frame: NSRect(x: 20, y: 4, width: 16, height: 16))
                    progressIndicator.style = .spinning
                    progressIndicator.controlSize = .small
                    progressIndicator.startAnimation(nil)
                    progressIndicator.isHidden = false
                    ejectButton.addSubview(progressIndicator)
                } else {
                    ejectButton.title = "推出"
                    ejectButton.isEnabled = true
                }
                
                customView.addSubview(ejectButton)
                ejectButtons[disk.id] = ejectButton
                
                let menuItem = NSMenuItem()
                menuItem.view = customView
                menu.addItem(menuItem)
            }
        }
        
        menu.addItem(.separator())
        
        let openWindowItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        openWindowItem.target = self
        menu.addItem(openWindowItem)
        
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        print("Menu rebuilt and assigned to status item")
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
    
    @objc private func refreshMenu() {
        refreshDiskList()
    }
    
    @objc private func ejectDisk(_ sender: NSMenuItem) {
        print("=== ejectDisk called ===")
        print("Sender: \(sender)")
        print("Sender title: \(sender.title)")
        print("Sender action: \(String(describing: sender.action))")
        print("Sender target: \(String(describing: sender.target))")
        print("Sender representedObject: \(String(describing: sender.representedObject))")
        guard let disk = sender.representedObject as? DiskInfo else { 
            print("No disk found in representedObject")
            return 
        }
        print("Disk: \(disk.displayName)")
        print("Disk mount path: \(disk.mountPath)")
        ejectDiskWithDiskInfo(disk)
    }
    
    @objc private func ejectDiskMenuItem(_ sender: NSMenuItem) {
        guard let disk = sender.representedObject as? DiskInfo else { 
            print("=== ejectDiskMenuItem called ===")
            print("No disk found in representedObject")
            return 
        }
        print("=== ejectDiskMenuItem called ===")
        print("Disk: \(disk.displayName)")
        print("Disk mount path: \(disk.mountPath)")
        ejectDiskWithDiskInfo(disk)
    }
    
    @objc private func ejectDiskButton(_ sender: Any) {
        var diskIndex: Int
        
        if let button = sender as? NSButton {
            diskIndex = button.tag
            print("=== ejectDiskButton called from NSButton ===")
        } else if let menuItem = sender as? NSMenuItem {
            diskIndex = menuItem.tag
            print("=== ejectDiskButton called from NSMenuItem ===")
        } else {
            print("=== ejectDiskButton called with unknown sender type ===")
            return
        }
        
        print("=== ejectDiskButton called ===")
        print("Disk index: \(diskIndex)")
        print("Current disks count: \(currentDisks.count)")
        if diskIndex < currentDisks.count {
            let disk = currentDisks[diskIndex]
            print("Ejecting disk: \(disk.displayName)")
            print("Disk mount path: \(disk.mountPath)")
            
            // 设置正在推出的磁盘ID，用于显示加载动效
            ejectingDiskId = disk.id
            // 刷新菜单栏以显示加载状态
            refreshDiskList()
            
            ejectDiskWithDiskInfo(disk)
        } else {
            print("Disk index out of range: \(diskIndex), currentDisks.count: \(currentDisks.count)")
        }
    }
    
    @objc private func ejectDiskSwitch(_ sender: Any) {
        print("=== ejectDiskSwitch called ===")
        print("Sender type: \(type(of: sender))")
        
        var diskIndex: Int = -1
        
        if let button = sender as? NSButton {
            diskIndex = button.tag
            print("Sender is NSButton, tag: \(diskIndex)")
        } else if let `switch` = sender as? NSSwitch {
            diskIndex = `switch`.tag
            print("Sender is NSSwitch, tag: \(diskIndex)")
        } else {
            print("Unknown sender type")
            return
        }
        
        // 将状态设置为开启（蓝色）
        if let button = sender as? NSButton {
            button.state = .on
        } else if let `switch` = sender as? NSSwitch {
            `switch`.state = .on
        }
        
        print("Disk index: \(diskIndex)")
        print("Current disks count: \(currentDisks.count)")
        if diskIndex < currentDisks.count {
            let disk = currentDisks[diskIndex]
            print("Ejecting disk: \(disk.displayName), mountPath: \(disk.mountPath)")
            // 执行推出操作
            ejectDiskWithDiskInfo(disk)
        } else {
            print("Disk index out of range: \(diskIndex), currentDisks.count: \(currentDisks.count)")
        }
    }
    
    private func ejectDiskWithDiskInfo(_ disk: DiskInfo) {
        print("=== ejectDiskWithDiskInfo called ===")
        print("Disk: \(disk.displayName)")
        print("Disk mount path: \(disk.mountPath)")
        
        // 先关闭菜单栏
        statusItem.menu?.cancelTracking()
        
        // 强制关闭菜单栏，确保在所有情况下都能关闭
        NSApp.abortModal()
        
        // 在后台检查是否有进程占用该磁盘（lsof/ps 最多耗时 2 秒，不能阻塞主线程）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let processes = self.processService.findProcessesAccessingDisk(mountPath: disk.mountPath)
            DispatchQueue.main.async {
                if processes.isEmpty {
                    // 无进程占用，直接推出
                    self.performEject(disk: disk, processes: [])
                } else {
                    // 有进程占用，先弹确认框，列出占用程序并提示数据丢失风险
                    self.confirmEjectWithOccupiedProcesses(disk: disk, processes: processes)
                }
            }
        }
    }
    
    /// 磁盘被进程占用时弹出确认框：列出占用程序，警告数据丢失风险，由用户决定是否终止进程并推出
    private func confirmEjectWithOccupiedProcesses(disk: DiskInfo, processes: [ProcessInfo]) {
        // 激活应用，确保弹窗显示在最前（菜单栏 app 可能是 .accessory 模式，不激活可能不置前）
        NSApp.activate(ignoringOtherApps: true)
        
        let processList = processes.map { "• \($0.name) (PID: \($0.pid))" }.joined(separator: "\n")
        
        let alert = NSAlert()
        alert.messageText = "磁盘正被程序占用"
        alert.informativeText = """
        以下程序正在访问磁盘 "\(disk.displayName)"：
        
        \(processList)
        
        直接推出可能导致数据丢失（这些程序中未保存的工作将被丢弃）。是否终止这些程序并推出磁盘？
        """
        alert.alertStyle = .warning
        // 第一个按钮为默认按钮（回车触发），将「取消」设为默认更安全
        alert.addButton(withTitle: "取消")
        // 危险操作按钮：红色 + 无回车快捷键，必须主动点按才会触发
        let ejectButton = alert.addButton(withTitle: "终止程序并推出")
        ejectButton.hasDestructiveAction = true
        ejectButton.keyEquivalent = ""
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // 用户确认终止进程并推出
            performEject(disk: disk, processes: processes)
        } else {
            // 用户取消，恢复菜单按钮状态
            ejectingDiskId = nil
            refreshDiskList()
        }
    }
    
    private func performEject(disk: DiskInfo, processes: [ProcessInfo]) {
        print("=== performEject called ===")
        print("Disk: \(disk.displayName)")
        print("Processes to kill: \(processes.count)")
        diskService.ejectDisk(disk, killProcesses: processes) { result in
            DispatchQueue.main.async {
                // 清除正在推出的磁盘ID
                self.ejectingDiskId = nil
                
                switch result {
                case .success:
                    print("Disk \(disk.displayName) ejected successfully")
                    // 显示成功提示
                    let alert = NSAlert()
                    alert.messageText = "推出成功"
                    alert.informativeText = "磁盘 \"\(disk.displayName)\" 已成功推出"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "确定")
                    alert.runModal()
                    // 立即刷新磁盘列表，而不是延迟
                    self.refreshDiskList()
                case .failure(let error):
                    print("Failed to eject disk: \(error.localizedDescription)")
                    // 显示失败提示
                    let alert = NSAlert()
                    alert.messageText = "推出失败"
                    alert.informativeText = "无法推出磁盘 \"\(disk.displayName)\": \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "确定")
                    alert.runModal()
                    // 刷新磁盘列表以恢复按钮状态
                    self.refreshDiskList()
                }
            }
        }
    }

    private func setupMainWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "DiskEjector"
        win.contentView = NSHostingView(rootView: ContentView())
        win.center()
        win.minSize = NSSize(width: 600, height: 400)
        win.isReleasedWhenClosed = false
        mainWindow = win
    }

    @objc func showMainWindow() {
        print("Show main window called")
        if mainWindow == nil {
            setupMainWindow()
        }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        print("Main window activated")
    }
    
    @objc func quitApplication() {
        print("Quit application called")
        NSApplication.shared.terminate(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshDiskList()
    }
}
