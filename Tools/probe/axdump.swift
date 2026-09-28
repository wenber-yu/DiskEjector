import AppKit
import ApplicationServices
import Foundation

// axdump —— 递归打印某个进程的**辅助功能（AX）元素树**：`(角色, 标题, 位置, 尺寸)`。
//
// ## 为什么需要它
//
// 验证弹窗时遇到过一个硬钉子：`System Events` 的 `click button "关闭并推出" of window 1`
// 报 `-1728`，换成 `entire contents of window 1` 遍历也**返回空**
// —— 看起来像「SwiftUI 的按钮根本没暴露给辅助功能」。
//
// ⚠️ 但那是**桥接层**的结论，不是 AX 本身：AppleScript 的 `System Events` 走的是它自己
// 那套元素映射，对无障碍实现不完整的窗口会静默返回空（不报错、也拿不到东西）。
// 直接调 `AXUIElementCopyAttributeValue` 是另一条路，本探针就是用来把这两件事分开的：
// **到底是「没暴露」还是「System Events 读不到」**。
//
// 顺带的用处：找到按钮的 `kAXPositionAttribute` / `kAXSizeAttribute` 后，
// 就有了**真实鼠标点击**的落点（AX 的坐标与 `CGEvent` 同一套：左上原点、全局屏幕坐标）。
//
// ## 用法
//
//     source Tools/clt_swift_env.sh
//     swift Tools/probe/axdump.swift 磁盘推出助手          # 按进程名子串
//     swift Tools/probe/axdump.swift 磁盘推出助手 --buttons # 只列按钮
//
// ## 权限
//
// 需要**辅助功能**授权（`AXIsProcessTrusted()`）。没授权时所有属性都是空的 ——
// 那与「窗口里真的没有元素」逐字相同，所以本探针会**先自证权限**再干活。
let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("用法: swift axdump.swift <进程名子串> [--buttons]\n".data(using: .utf8)!)
    exit(2)
}
let needle = args[1]
let buttonsOnly = args.contains("--buttons")

// ⚠️ 自证权限：没授权时下面全是空树，而「空树」与「窗口里真没元素」长得一模一样。
if !AXIsProcessTrusted() {
    let warning =
        "⚠️ 本进程没有辅助功能授权（AXIsProcessTrusted() == false）——\n"
        + "   下面即便打出空树也不能证明「窗口里没有元素」。请先授权再跑。\n"
    FileHandle.standardError.write(warning.data(using: .utf8)!)
}

// ⚠️ 不能只靠 `NSWorkspace.shared.runningApplications` 找进程：**accessory 型 app
// （`LSUIElement`）常常不在那份清单里**，于是「进程明明在、窗口也画着」却报「没找到进程」。
// 窗口列表里的 `kCGWindowOwnerPID` 反而最可靠 —— 它由窗口服务器给出，与激活策略无关。
func resolvePID(_ needle: String) -> pid_t? {
    if let numeric = Int(needle) { return pid_t(numeric) }
    if let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    {
        for info in list {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner.contains(needle), let raw = info[kCGWindowOwnerPID as String] as? NSNumber {
                return pid_t(raw.int32Value)
            }
        }
    }
    return NSWorkspace.shared.runningApplications.first { candidate in
        let name = candidate.localizedName ?? ""
        let path = candidate.bundleURL?.lastPathComponent ?? ""
        let bundleID = candidate.bundleIdentifier ?? ""
        return name.contains(needle) || path.contains(needle) || bundleID.contains(needle)
    }?.processIdentifier
}

guard let pid = resolvePID(needle) else {
    FileHandle.standardError.write("没找到进程「\(needle)」\n".data(using: .utf8)!)
    exit(1)
}

print("进程 \(needle)（pid \(pid)）")

let root = AXUIElementCreateApplication(pid)
// AX 调用会跨进程阻塞；给个超时，免得某个卡住的元素把整个探针拖死。
AXUIElementSetMessagingTimeout(root, 3.0)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var value = CGPoint.zero
    guard AXValueGetValue(raw as! AXValue, .cgPoint, &value) else { return nil }
    return value
}

func size(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var value = CGSize.zero
    guard AXValueGetValue(raw as! AXValue, .cgSize, &value) else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

var visited = 0
let visitLimit = 600
var buttonCount = 0

func describe(_ element: AXUIElement) -> String {
    var parts: [String] = [text(element, kAXRoleAttribute as String) ?? "?"]
    for (label, attr) in [
        ("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
        ("value", kAXValueAttribute), ("id", kAXIdentifierAttribute),
    ] {
        if let v = text(element, attr as String), !v.isEmpty { parts.append("\(label)=「\(v)」") }
    }
    if let p = point(element, kAXPositionAttribute as String),
        let s = size(element, kAXSizeAttribute as String)
    {
        parts.append(String(format: "@(%.0f,%.0f) %.0fx%.0f", p.x, p.y, s.width, s.height))
    }
    return parts.joined(separator: " ")
}

func walk(_ element: AXUIElement, depth: Int) {
    guard visited < visitLimit else { return }
    visited += 1
    let role = text(element, kAXRoleAttribute as String) ?? "?"
    let isButton = role.contains("Button")
    if isButton { buttonCount += 1 }
    if !buttonsOnly || isButton {
        print(String(repeating: "  ", count: depth) + describe(element))
    }
    for kid in children(element) { walk(kid, depth: depth + 1) }
}

walk(root, depth: 0)
print("--- 访问 \(visited) 个元素（上限 \(visitLimit)），其中按钮 \(buttonCount) 个 ---")

// ⚠️ 装置自证：**「一个按钮都没有」与「树没读进来」在输出上逐字相同** ⇒ 用退出码分开。
if buttonCount == 0 {
    let warning = "⚠️ 没读到任何按钮 —— 可能是该窗口真的没有按钮，也可能是辅助功能树没长出来。\n"
    FileHandle.standardError.write(warning.data(using: .utf8)!)
    exit(1)
}
