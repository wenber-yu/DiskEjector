import SwiftUI

struct SwiftUIMenuBarApp: App {
    @State private var showWindow = false
    
    var body: some Scene {
        // 主窗口
        WindowGroup {
            Text("DiskEjector Main Window")
                .padding()
        }
        
        // 菜单栏额外项
        MenuBarExtra("EJECT", systemImage: "eject") {
            Button("打开主窗口") {
                showWindow = true
                print("Open main window clicked")
            }
            
            Divider()
            
            Button("退出") {
                NSApplication.shared.terminate(nil)
                print("Quit clicked")
            }
        }
    }
}

// 辅助扩展
extension NSApplication {
    static func terminate(_ sender: Any?) {
        shared.terminate(sender)
    }
}