import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("IconStatusBarApp launched")
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            print("Failed to get status item button")
            return
        }
        
        print("Got status item button")
        
        // 使用系统图标
        if let image = NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject") {
            image.isTemplate = true
            button.image = image
            print("Set eject icon")
        } else {
            print("Failed to load system image, using text fallback")
            button.title = "E"
        }
        
        // 不设置action，使用系统默认行为
        let menu = NSMenu()
        
        let testItem = NSMenuItem(title: "Test Action", action: #selector(testAction), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        
        print("Menu bar setup complete")
    }
    
    @objc func testAction() {
        print("Test action triggered")
        // 显示一个简单的提示
        let alert = NSAlert()
        alert.messageText = "Test Action"
        alert.informativeText = "Test action was triggered successfully!"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

print("Starting IconStatusBarApp")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()