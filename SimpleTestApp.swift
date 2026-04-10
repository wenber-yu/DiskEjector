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
        button.title = "TEST"
        button.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        button.toolTip = "Test Menu Bar"
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = menu
        
        print("Menu bar setup complete")
    }
}

print("Starting application")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()