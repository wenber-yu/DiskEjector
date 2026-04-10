import AppKit
import SwiftUI

let app = NSApplication.shared
app.delegate = nil

// 创建 SwiftUI 应用
let swiftUIApp = SwiftUIMenuBarApp()

// 运行应用
app.run()