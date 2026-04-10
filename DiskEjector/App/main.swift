import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow!
    private let diskService = DiskService.shared
    private let processService = ProcessService.shared
    
    private var currentDisks: [DiskInfo] = []

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
    }
    
    private func refreshDiskList() {
        currentDisks = diskService.fetchExternalDisks()
        updateMenu()
    }
    
    private func updateMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        // 添加磁盘列表
        if currentDisks.isEmpty {
            let noDiskItem = NSMenuItem(title: "没有可推出的磁盘", action: nil, keyEquivalent: "")
            noDiskItem.isEnabled = false
            menu.addItem(noDiskItem)
        } else {
            for disk in currentDisks {
                let diskItem = NSMenuItem(title: disk.displayName, action: nil, keyEquivalent: "")
                diskItem.isEnabled = false
                menu.addItem(diskItem)
                
                let ejectItem = NSMenuItem(title: "  推出", action: #selector(ejectDisk(_:)), keyEquivalent: "")
                ejectItem.target = self
                ejectItem.representedObject = disk
                menu.addItem(ejectItem)
            }
        }
        
        menu.addItem(.separator())
        
        // 打开主窗口
        let openWindowItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        openWindowItem.target = self
        menu.addItem(openWindowItem)
        
        // 刷新
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(.separator())
        
        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func refreshMenu() {
        refreshDiskList()
    }
    
    @objc private func ejectDisk(_ sender: NSMenuItem) {
        guard let disk = sender.representedObject as? DiskInfo else { return }
        
        let processes = processService.findProcessesAccessingDisk(mountPath: disk.mountPath)
        
        if !processes.isEmpty {
            let alert = NSAlert()
            alert.messageText = "磁盘正在被占用"
            alert.informativeText = "以下进程正在访问磁盘 \"\(disk.displayName)\"：\n\n\(processes.map { "- \($0.name) (PID: \($0.pid))" }.joined(separator: "\n"))\n\n是否强制结束这些进程并推出磁盘？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "强制结束并推出")
            
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                performEject(disk: disk, processes: processes)
            }
        } else {
            performEject(disk: disk, processes: [])
        }
    }
    
    private func performEject(disk: DiskInfo, processes: [ProcessInfo]) {
        diskService.ejectDisk(disk, killProcesses: processes) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    print("Disk \(disk.displayName) ejected successfully")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.refreshDiskList()
                    }
                case .failure(let error):
                    print("Failed to eject disk: \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "推出失败"
                    alert.informativeText = "无法推出磁盘 \"\(disk.displayName)\": \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "确定")
                    alert.runModal()
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

print("Starting DiskEjector")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()