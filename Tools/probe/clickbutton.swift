import AppKit
import ApplicationServices
import Foundation

// clickbutton —— 在某个进程的窗口里**真实点击**一个辅助功能按钮（AX 定位 + CGEvent 注入）。
//
// ## 为什么需要它
//
// 「自绘弹窗上的按钮到底能不能被点」这件事，此前一直是一个**验不到的缺口**：
// `System Events` 的两条路都失败过 ——
// `click button "关闭并推出" of window 1` 报 `-1728`，
// `repeat with e in (entire contents of window 1)` **返回空**。
// 当时的结论是「SwiftUI 的按钮没暴露给辅助功能」。
//
// ⚠️ **那个结论是错的**（2026-09-28 实测修正）：`Tools/probe/axdump.swift` 用
// `AXUIElementCopyAttributeValue` 直接读同一个窗口，**两个按钮都在**：
//
//     AXButton desc=「取消」      @(898,496) 50x30
//     AXButton desc=「关闭并推出」 @(956,496) 88x30
//
// 所以真相是**桥接层的问题**（`System Events` 的元素映射对无障碍实现不完整的窗口
// 静默返回空，不报错），不是「按钮不存在」。差别很关键：前者换一条 API 就能拿到，
// 后者才是没救。
//
// ## 用法
//
//     source Tools/clt_swift_env.sh
//     swift Tools/probe/clickbutton.swift 磁盘推出助手 关闭并推出
//     swift Tools/probe/clickbutton.swift 磁盘推出助手 好 --coords    # 强制走坐标注入
//     swift Tools/probe/clickbutton.swift 磁盘推出助手 好 --press     # 强制走语义点击
//
// 进程名可以是子串，也可以是**纯数字 PID**（accessory app 不在
// `NSWorkspace.runningApplications` 里，此时按窗口拥有者解析，见下）。
//
// ## 两条点击路径，都保留
//
// | | 走什么 | 说明 |
// |---|---|---|
// | `AXPress`（默认先试） | 无障碍动作 | 语义点击，`accessibilityPerformPress` → action，**不依赖坐标** |
// | 坐标注入（回落 / `--coords`） | `CGEvent` 鼠标事件 | 字面意义的「把鼠标移过去点一下」，**依赖 `CGPreflightPostEventAccess`** |
//
// 两条都要能单独跑：前者证明「按钮的 action 接线是通的」，后者证明
// 「真实鼠标事件能被 SwiftUI 接收」—— 它们是**两件不同的事**，只验一条会漏另一条的坏法。
//
// ## 权限
//
// 两样都要，缺一不可，且**都要自证**：
// - `AXIsProcessTrusted()` —— 读元素树需要**辅助功能**授权；
// - `CGPreflightPostEventAccess()` —— 投递鼠标事件需要**事件注入**授权。
// 后者是**按二进制**给的：`osascript` 有权限 ≠ 你这段脚本有权限。
// 权限不足时事件被系统**静默丢弃**，看起来与「按钮点了没反应」逐字相同 ——
// 所以本探针先自检再干活，不把「没权限」读成「按钮坏了」。
let arguments = CommandLine.arguments
let tail = Array(arguments.dropFirst(2))
guard let needle = arguments.count > 2 ? arguments[1] : nil,
    let buttonNeedle = tail.first(where: { !$0.hasPrefix("--") })
else {
    let usage = "用法: swift clickbutton.swift <进程名子串|PID> <按钮标题子串> [--coords|--press]\n"
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}
let onlyCoords = tail.contains("--coords")
let onlyPress = tail.contains("--press")

var problems: [String] = []
if !AXIsProcessTrusted() { problems.append("AXIsProcessTrusted() == false（缺辅助功能授权）") }
if !CGPreflightPostEventAccess() { problems.append("CGPreflightPostEventAccess() == false（缺事件注入授权）") }
if !problems.isEmpty {
    let message = "⚠️ 权限不足，结论不可信：\n  - " + problems.joined(separator: "\n  - ") + "\n"
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(3)
}

// ⚠️ accessory 型 app（`LSUIElement`）常常不在 `NSWorkspace.runningApplications` 里，
// 而窗口列表的 `kCGWindowOwnerPID` 由窗口服务器给出、与激活策略无关 —— 优先用它。
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

let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 3.0)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func rect(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = attribute(element, kAXPositionAttribute as String),
        let rawSize = attribute(element, kAXSizeAttribute as String),
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
        AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

/// 递归找第一个「角色是按钮，且标题/描述含目标子串」的元素。
func findButton(_ element: AXUIElement, depth: Int) -> (AXUIElement, CGRect, String)? {
    guard depth < 40 else { return nil }
    let role = text(element, kAXRoleAttribute as String) ?? ""
    if role.contains("Button") {
        let title = text(element, kAXTitleAttribute as String) ?? ""
        let description = text(element, kAXDescriptionAttribute as String) ?? ""
        let label = title.isEmpty ? description : title
        if label.contains(buttonNeedle), let frame = rect(element) {
            return (element, frame, label)
        }
    }
    for kid in children(element) {
        if let hit = findButton(kid, depth: depth + 1) { return hit }
    }
    return nil
}

guard let (element, frame, label) = findButton(root, depth: 0) else {
    let message = "没找到标题含「\(buttonNeedle)」的按钮（pid \(pid)）\n"
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(1)
}

let center = CGPoint(x: frame.midX, y: frame.midY)
print(
    String(
        format: "找到按钮「%@」@(%.0f,%.0f) %.0fx%.0f → 点击中心 (%.0f,%.0f)",
        label, frame.origin.x, frame.origin.y, frame.width, frame.height, center.x, center.y))

// 先试 `AXPress`（语义点击）—— 它是**不走坐标**的点击，命中率最高。
//
// ⚠️ 但它对 SwiftUI 的某些元素会返回 `kAXErrorActionUnsupported` —— 那不是「按钮坏了」，
// 只是该元素没实现 `AXPress`。所以**失败不算错**，继续走坐标注入那条路。
if !onlyCoords {
    let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if pressResult == .success {
        print("AXPress 成功（语义点击，无需坐标）")
        exit(0)
    }
    print("AXPress 返回 \(pressResult.rawValue)（该元素未实现语义点击）")
    if onlyPress {
        FileHandle.standardError.write("按 --press 要求只走语义点击，但它没成功\n".data(using: .utf8)!)
        exit(4)
    }
}

// 走坐标：`mouseMoved` → `leftMouseDown` → `leftMouseUp`。
// 中间留一点间隔：SwiftUI 的按钮要 down/up 落在同一个视图内才认这一击。
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?
    .post(tap: .cghidEventTap)
print("已注入鼠标点击")
