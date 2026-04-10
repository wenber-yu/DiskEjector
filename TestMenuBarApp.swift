import AppKit

class TestAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            print("Button is nil")
            return
        }
        
        button.title = "T"
        button.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        button.toolTip = "Test Menu Bar App"
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Test Item", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        
        statusItem.menu = menu
        
        print("Test menu bar app started")
        print("Button title: \(button.title)")
        print("Menu items: \(menu.items.count)")
    }
}

let app = NSApplication.shared
let delegate = TestAppDelegate()
app.delegate = delegate
app.run()