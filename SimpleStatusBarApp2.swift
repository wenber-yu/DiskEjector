import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("SimpleStatusBarApp launched")
        
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        guard let button = statusItem.button else {
            print("Failed to get status item button")
            return
        }
        
        print("Got status item button")
        button.title = "TEST"
        button.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        button.toolTip = "Test App"
        
        // 确保按钮能响应点击
        button.target = self
        button.action = #selector(showMenu)
        
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
    
    @objc func showMenu() {
        print("Show menu called")
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: statusItem.button)
    }
    
    @objc func testAction() {
        print("Test action triggered")
    }
}

print("Starting SimpleStatusBarApp")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()