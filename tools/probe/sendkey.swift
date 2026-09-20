import AppKit
import CoreGraphics
import Foundation

// sendkey —— 把某个 app 提到前台，然后发一个 ⌘<键>。
//
// ## 为什么需要它
//
// 菜单栏 app（`LSUIElement`）**普通启动后没有窗口、也不是 active**，
// 于是开不了设置窗。而测「检查更新」**必须普通启动** ——
// `--preview-*` 那条路**不建 updater**（§8.113.1），测不了更新。
// `osascript` 也不行：本环境发 Apple Event 会被沙箱挡，且它同样要先 active。
//
// ⇒ 只能自己发键盘事件。⚠️ 而发之前**必须先 activate**：
//   事件送不到目标 app 时**不报错、只是没反应**，与「快捷键根本没接」逐字相同。
//
// ## 用法
//
//   sendkey <pid> <keycode>       例：sendkey 1234 43   （43 = ','，即 ⌘,）
//
// ## 装置自证
//
// ⚠️ **退出码 0 只代表「事件发出去了」，不代表「窗口开了」**。
//   调用方必须随后用 `axtext` 抓一次，看到 `SELFCHECK ok`（含锚点）才算真开了。

let args = CommandLine.arguments
guard args.count >= 3, let pidInt = Int(args[1]), let keyCode = UInt16(args[2]) else {
    FileHandle.standardError.write(
        Data("用法：sendkey <pid> <keycode>   （例：43 = ',' ⇒ ⌘,）\n".utf8))
    exit(2)
}
let pid = pid_t(pidInt)

guard let app = NSRunningApplication(processIdentifier: pid) else {
    print("NORUNNING pid=\(pid)（进程不存在，或不是能 activate 的 GUI 应用）")
    exit(3)
}

// ① 先提到前台 —— 不这么做，后面的事件根本送不到它那儿，而且**不报错**。
app.activate(options: [.activateIgnoringOtherApps])
Thread.sleep(forTimeInterval: 0.6)

guard let src = CGEventSource(stateID: .hidSystemState) else {
    print("NOEVENTSOURCE（拿不到 HID 事件源 ⇒ 发不出事件；查辅助功能/输入监控权限）")
    exit(3)
}
let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
down?.flags = .maskCommand
up?.flags = .maskCommand
down?.post(tap: .cghidEventTap)
usleep(50_000)
up?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.8)

print("SENT ⌘key=\(keyCode) to pid=\(pid) active=\(app.isActive)")
print("⚠️ 这不是回执 —— 请用 axtext 抓一次确认窗口真的开了")
exit(0)
