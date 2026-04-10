import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow!

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
        
        // 4. 创建菜单
        let menu = NSMenu()
        
        // 5. 添加菜单项
        let openWindowItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        openWindowItem.target = self
        menu.addItem(openWindowItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        
        // 6. 设置菜单
        statusItem.menu = menu
        
        print("Menu bar setup complete")
        
        // 7. 延迟创建主窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setupMainWindow()
            print("Main window setup complete")
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

print("Starting DiskEjector")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()