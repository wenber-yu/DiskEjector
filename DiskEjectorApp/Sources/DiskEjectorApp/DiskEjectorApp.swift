import AppKit
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow!
    private let diskService = DiskService.shared
    private let processService = ProcessService.shared
    
    private var currentDisks: [DiskInfo] = []
    private var ejectButtons: [String: NSButton] = [:]
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

    static func main() {
        print("Starting DiskEjector")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("DiskEjector launched")
        
        // 1. 确保应用显示在 Dock 栏
        NSApp.setActivationPolicy(.regular)
        
        // 2. 创建状态栏项 - 使用可变长度
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            print("Failed to get status item button")
            return
        }
        
        print("Got status item button")
        
        // 3. 设置按钮属性 - 使用图标
        let ejectImage = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        button.image = ejectImage
        button.toolTip = "DiskEjector"
        
        print("Button image set: \(button.image != nil)")
        
        // 4. 初始刷新磁盘列表
        refreshDiskList()
        
        print("Menu bar setup complete")
        
        // 5. 延迟创建主窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setupMainWindow()
            print("Main window setup complete")
        }
        
        // 6. 监听磁盘插入和弹出事件
        setupDiskMonitoring()
    }
    
    private func setupDiskMonitoring() {
        // 使用 NSWorkspace 监听磁盘挂载和卸载事件
        let workspace = NSWorkspace.shared
        
        // 监听磁盘挂载事件
        NotificationCenter.default.addObserver(forName: NSWorkspace.didMountNotification, object: workspace, queue: nil) { [weak self] notification in
            print("=== Disk mounted notification received ===")
            if let volumeURL = notification.userInfo?["NSWorkspaceVolumeURLKey"] as? URL {
                print("Mounted volume URL: \(volumeURL)")
            }
            print("Refreshing disk list...")
            self?.refreshDiskList()
        }
        
        // 监听磁盘卸载事件
        NotificationCenter.default.addObserver(forName: NSWorkspace.didUnmountNotification, object: workspace, queue: nil) { [weak self] notification in
            print("=== Disk unmounted notification received ===")
            if let volumeURL = notification.userInfo?["NSWorkspaceVolumeURLKey"] as? URL {
                print("Unmounted volume URL: \(volumeURL)")
            }
            print("Refreshing disk list...")
            self?.refreshDiskList()
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
        // 清除按钮字典，因为菜单项会被重新创建
        ejectButtons.removeAll()
        updateMenu()
        
        // 手动刷新菜单栏
        statusItem.menu?.update()
        
        // 强制更新状态栏按钮，确保菜单栏能够立即反映新的磁盘列表
        statusItem.button?.needsDisplay = true
        
        // 强制重新设置菜单，确保菜单栏能够立即更新
        if let menu = statusItem.menu {
            statusItem.menu = nil
            statusItem.menu = menu
        }
        
        // 强制刷新状态栏项
        statusItem.button?.display()
    }
    
    private func updateMenu() {
        print("=== updateMenu called ===")
        let menu = NSMenu()
        menu.delegate = self
        
        // 添加顶部空白
        let spaceItem = NSMenuItem()
        spaceItem.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        menu.addItem(spaceItem)
        print("Added space item")
        
        // 添加硬盘列表标题
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
        print("Added title item")
        
        menu.addItem(.separator())
        print("Added separator")
        
        // 添加磁盘列表
        if currentDisks.isEmpty {
            let noDiskItem = NSMenuItem(title: "没有可推出的磁盘", action: nil, keyEquivalent: "")
            noDiskItem.isEnabled = false
            menu.addItem(noDiskItem)
            print("Added no disk item")
        } else {
            for (index, disk) in currentDisks.enumerated() {
                // 创建一个自定义视图，高度增加以显示更多信息
                let customView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
                customView.wantsLayer = true
                
                // 添加磁盘图标
                if let diskImage = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Disk") {
                    let diskImageView = NSImageView(frame: NSRect(x: 12, y: 16, width: 16, height: 16))
                    diskImageView.image = diskImage
                    diskImageView.contentTintColor = accentColorValue
                    customView.addSubview(diskImageView)
                    print("Added disk image for \(disk.displayName)")
                }
                
                // 添加磁盘信息容器
                let infoContainer = NSView(frame: NSRect(x: 36, y: 8, width: 280, height: 32))
                customView.addSubview(infoContainer)
                
                // 添加磁盘名称
                let nameLabel = NSTextField(frame: NSRect(x: 0, y: 12, width: 280, height: 16))
                nameLabel.stringValue = disk.displayName
                nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
                nameLabel.isBezeled = false
                nameLabel.drawsBackground = false
                nameLabel.isEditable = false
                nameLabel.isSelectable = false
                infoContainer.addSubview(nameLabel)
                print("Added name label for \(disk.displayName)")
                
                // 添加磁盘存储使用情况
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
                print("Added usage label for \(disk.displayName)")
                
                // 添加推出按钮
                let ejectButton = NSButton(frame: NSRect(x: 330, y: 12, width: 60, height: 24))
                ejectButton.title = "推出"
                ejectButton.target = self
                ejectButton.action = #selector(ejectDiskButton(_:))
                ejectButton.tag = index
                ejectButton.bezelStyle = .rounded
                ejectButton.contentTintColor = accentColorValue
                ejectButton.isEnabled = true
                ejectButton.setButtonType(.momentaryPushIn)
                print("Created eject button for disk \(disk.displayName), tag: \(index), frame: \(ejectButton.frame)")
                print("Button target: \(String(describing: ejectButton.target))")
                print("Button action: \(String(describing: ejectButton.action))")
                customView.addSubview(ejectButton)
                
                // 将按钮添加到字典中，以便后续操作
                ejectButtons[disk.id] = ejectButton
                
                // 创建菜单项并设置视图
                let menuItem = NSMenuItem()
                menuItem.view = customView
                menu.addItem(menuItem)
                print("Added menu item for \(disk.displayName)")
            }
        }
        
        menu.addItem(.separator())
        print("Added separator")
        
        // 打开主窗口
        let openWindowItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        openWindowItem.target = self
        menu.addItem(openWindowItem)
        print("Added open window item")
        
        // 刷新
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        print("Added refresh item")
        
        menu.addItem(.separator())
        print("Added separator")
        
        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        print("Added quit item")
        
        statusItem.menu = menu
        print("Menu set to status item")
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
            
            // 禁用推出按钮，避免用户多次点击
            if let button = ejectButtons[disk.id] {
                button.isEnabled = false
                button.title = "推出中..."
            }
            
            ejectDiskWithDiskInfo(disk)
        } else {
            print("Disk index out of range: \(diskIndex), currentDisks.count: \(currentDisks.count)")
        }
    }
    
    @objc private func ejectDiskSwitch(_ sender: Any) {
        print("=== ejectDiskSwitch called ===")
        print("Sender type: \(type(of: sender))")
        
        var diskIndex: Int = -1
        var state: NSControl.StateValue = .off
        
        if let button = sender as? NSButton {
            diskIndex = button.tag
            state = button.state
            print("Sender is NSButton, tag: \(diskIndex)")
        } else if let `switch` = sender as? NSSwitch {
            diskIndex = `switch`.tag
            state = `switch`.state
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
        
        DispatchQueue.global(qos: .userInitiated).async {
            print("Finding processes for disk: \(disk.displayName)")
            let processes = self.processService.findProcessesAccessingDisk(mountPath: disk.mountPath)
            print("Found \(processes.count) processes")
            
            DispatchQueue.main.async {
                if !processes.isEmpty {
                    print("Disk is being used by processes, showing alert")
                    let alert = NSAlert()
                    alert.messageText = "磁盘正在被占用"
                    alert.informativeText = "以下进程正在访问磁盘 \"\(disk.displayName)\":\n\n\(processes.map { "- \($0.name) (PID: \($0.pid))" }.joined(separator: "\n"))\n\n是否强制结束这些进程并推出磁盘？"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "取消")
                    alert.addButton(withTitle: "强制结束并推出")
                    
                    let response = alert.runModal()
                    if response == .alertSecondButtonReturn {
                        print("User chose to force eject")
                        self.performEject(disk: disk, processes: processes)
                    } else {
                        print("User cancelled eject")
                        // 重新启用推出按钮
                        if let button = self.ejectButtons[disk.id] {
                            button.isEnabled = true
                            button.title = "推出"
                        }
                    }
                } else {
                    print("No processes found, ejecting directly")
                    self.performEject(disk: disk, processes: [])
                }
            }
        }
    }
    
    private func performEject(disk: DiskInfo, processes: [ProcessInfo]) {
        print("=== performEject called ===")
        print("Disk: \(disk.displayName)")
        print("Processes to kill: \(processes.count)")
        diskService.ejectDisk(disk, killProcesses: processes) { result in
            DispatchQueue.main.async {
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
                    // 重新启用推出按钮
                    if let button = self.ejectButtons[disk.id] {
                        button.isEnabled = true
                        button.title = "推出"
                    }
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
