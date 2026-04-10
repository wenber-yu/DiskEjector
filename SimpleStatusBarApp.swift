import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Application launched")
        
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        guard let button = statusItem.button else {
            print("Failed to get status item button")
            return
        }
        
        print("Got status item button")
        button.title = "EJECT"
        button.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        button.toolTip = "DiskEjector"
        
        let menu = NSMenu()
        
        let testItem = NSMenuItem(title: "Test", action: #selector(testAction), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        
        print("Menu bar setup complete")
    }
    
    @objc func testAction() {
        print("Test action triggered")
    }
}

print("Starting application")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()