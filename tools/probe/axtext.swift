import ApplicationServices
import CoreGraphics
import Foundation

// axtext —— 把某个进程所有窗口里的**可读文本**抓出来（Accessibility 树）。
//
// ## 为什么需要它
//
// 第 30 行要验的是「自动更新那条路上，设置行『正在后台下载』那一格真的被设置了」。
// 唯一能读的应用日志通道 `log stream` 在本环境里报 `Cannot run while sandboxed`，
// 于是回执只能落在**界面**上。而那一瞬太短，截图 + 肉眼不可行 ⇒ 直接读 AX 文本。
//
// ## 装置自证（没有这三条，「什么都没抓到」与「那一格真的没设置」逐字相同）
//
//   ① 抓到 **0 条** 文本 ⇒ 判**装置死**，不是「那一格没显示」；
//   ② 抓到的文本里必须包含**设置面板的锚点串**（「自动更新」），
//      否则说明读的不是设置窗口 ——「读错窗口」与「那一格没显示」也逐字相同；
//   ③ 调用方必须在**已知会显示**的状态下先跑一遍（见 `validate_axtext`）。
//
// 用法：
//   axtext <pid> [关键字]             —— 抓一次
//   axtext <pid> --watch <秒> <关键字> —— 连续抓（**进程内**轮询，省掉每次 spawn 的开销，
//                                          于是能压到 0.15s 一拍）
//   axtext <pid> --press <关键字>      —— 按**第一个**「带 AXPress 且文本匹配」的元素
//   axtext <pid> --press --list        —— 列出所有可 press 的元素（先用它找名字，再按）
//   - 不带关键字：打印全部文本（每行一条，去重后按出现顺序）
//   - 带关键字：只打印包含关键字的行（仍然先做 ①② 自证，自证失败就 exit 3）
let args = CommandLine.arguments
guard args.count >= 2, let pidInt = Int(args[1]) else {
    FileHandle.standardError.write(
        Data(
            "用法：axtext <pid> [关键字] ｜ axtext <pid> --watch <秒> <关键字> ｜ axtext <pid> --press <关键字>|--list\n"
                .utf8))
    exit(2)
}
let watchMode = args.count >= 5 && args[2] == "--watch"
let pressMode = args.count >= 4 && args[2] == "--press"
let pressKeyword = pressMode ? args[3] : ""
let watchSeconds = watchMode ? (Double(args[3]) ?? 60) : 0
let filter = watchMode ? args[4] : (args.count >= 3 ? args[2] : "")
let pid = pid_t(pidInt)
let app = AXUIElementCreateApplication(pid)

func attrString(_ e: AXUIElement, _ key: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    // AXValue 只有几何类型（point/size/rect/range），文本不会走这条路；
    // 这里留个兜底只是为了让「取不到值」与「值不是字符串」分开报。
    if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

var seen: [String] = []
var seenSet = Set<String>()
func collect(_ s: String) {
    guard !s.isEmpty else { return }
    if !seenSet.contains(s) {
        seenSet.insert(s)
        seen.append(s)
    }
}

func walk(_ e: AXUIElement, depth: Int) {
    if depth > 40 { return }
    for k in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let s = attrString(e, k) { collect(s) }
    }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
    if let r = role as? String, r == "AXStaticText" {
        if let s = attrString(e, kAXValueAttribute) { collect(s) }
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
        let kids = children as? [AXUIElement]
    else { return }
    for kid in kids { walk(kid, depth: depth + 1) }
}

/// 抓一拍。返回这一拍抓到的全部文本。
func snapshot() -> [String] {
    seen = []
    seenSet = []
    var rawWindows: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
    guard err == .success, let windows = rawWindows as? [AXUIElement], !windows.isEmpty else {
        return []
    }
    for w in windows { walk(w, depth: 0) }
    return seen
}

/// 列出所有**真的带 `AXPress` 动作**的元素。
///
/// ⚠️ 为什么不能「按第一个名字匹配的」：同名文本**常有两个**（`AXStaticText` 与
/// `AXButton` 各一个），而静态文本**按不动**。必须筛出带 `AXPress` 的那个 ——
/// 这是 `axdump --press` 那条经验的由来（它以前没入库，2026-09-21 补回这里）。
func pressableElements() -> [(role: String, label: String, el: AXUIElement)] {
    var out: [(String, String, AXUIElement)] = []
    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
        let windows = rawWindows as? [AXUIElement]
    else { return out }
    func visit(_ e: AXUIElement, depth: Int) {
        if depth > 40 { return }
        var actionNames: CFArray?
        var canPress = false
        if AXUIElementCopyActionNames(e, &actionNames) == .success,
            let names = actionNames as? [String], names.contains(kAXPressAction as String)
        {
            canPress = true
        }
        if canPress {
            let role = attrString(e, kAXRoleAttribute) ?? "?"
            let label =
                attrString(e, kAXTitleAttribute)
                ?? attrString(e, kAXDescriptionAttribute)
                ?? attrString(e, kAXValueAttribute) ?? ""
            out.append((role, label, e))
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
            let kids = children as? [AXUIElement]
        else { return }
        for kid in kids { visit(kid, depth: depth + 1) }
    }
    for w in windows { visit(w, depth: 0) }
    return out
}

let t0 = Date()
let first = snapshot()

// ① 自证：一条都没抓到 ⇒ 装置死
if first.isEmpty {
    print("NOTEXT pid=\(pid)（AX 读不到任何文本：要么没窗口、要么 Accessibility 权限没给）")
    exit(3)
}
// ② 自证：必须读到设置面板的锚点串 —— 否则说明读的不是设置窗口
if !first.contains(where: { $0.contains("自动更新") }) {
    print("NOANCHOR pid=\(pid) 抓到 \(first.count) 条，但没有「自动更新」⇒ 读的不是设置窗口：")
    for s in first.prefix(15) { print("  · \(s)") }
    exit(3)
}
print("SELFCHECK ok windows texts=\(first.count) anchor=自动更新")

// ---- --press：按第一个「可 press 且文本匹配」的元素 ----
if pressMode {
    let all = pressableElements()
    if pressKeyword == "--list" || pressKeyword.isEmpty {
        print("PRESSABLE \(all.count) 个：")
        for (i, it) in all.enumerated() { print("  [\(i)] \(it.role) 『\(it.label)』") }
        // 一条都没有 ⇒ 装置死（与「这个窗口没有按钮」输出相同，所以显式报）
        if all.isEmpty { print("⚠️ 一个可 press 的元素都没有 ⇒ 判装置死，别当成『这里没按钮』") }
        exit(all.isEmpty ? 3 : 0)
    }
    guard let hit = all.first(where: { $0.label.contains(pressKeyword) }) else {
        print("NOPRESS-TARGET 关键字=『\(pressKeyword)』；可 press 的共 \(all.count) 个：")
        for (i, it) in all.enumerated() { print("  [\(i)] \(it.role) 『\(it.label)』") }
        exit(3)
    }
    let err = AXUIElementPerformAction(hit.el, kAXPressAction as CFString)
    print("PRESS \(hit.role) 『\(hit.label)』 -> \(err == .success ? "success" : "err=\(err.rawValue)")")
    // ⚠️ 返回 success **不等于真的按了**（沙箱下 `terminate()` 也照样返回 true —— 同一个病）
    //    ⇒ 调用方必须**再去读一次界面**确认，别拿这个返回值当回执。
    print("⚠️ 上面这行不是回执 —— 请用 --watch 或再抓一次确认界面真的变了")
    exit(err == .success ? 0 : 4)
}

if !watchMode {
    if filter.isEmpty {
        for s in first { print("  · \(s)") }
    } else {
        for s in first where s.contains(filter) { print("  ★ \(s)") }
    }
    exit(0)
}

// ---- --watch：进程内轮询 ----
print("WATCH pid=\(pid) seconds=\(Int(watchSeconds)) keyword=『\(filter)』")
var hits: [String] = []
var lastAll: [String] = first
let deadline = Date().addingTimeInterval(watchSeconds)
var lastTimeline = Date()
var warnedGone = false
// 时间线：每 2s 打一次更新区文本。**没有它，只能看到「命中了」，看不到「后来变成什么」**
// —— 而「一直停在下载中」与「下载完就转已就绪」是两种完全不同的结论。
while Date() < deadline {
    let snap = snapshot()
    if !snap.isEmpty { lastAll = snap }
    for s in snap where s.contains(filter) && !hits.contains(s) {
        hits.append(s)
        print("  ★ [\(String(format: "%.1f", Date().timeIntervalSince(t0)))s] \(s)")
        fflush(stdout)
    }
    if snap.isEmpty {
        // 「抓不到窗口」必须**显式报出来**：它与「那一格没显示」的输出逐字相同（都是空）。
        if !warnedGone {
            warnedGone = true
            print(
                "  ⚠️ \(String(format: "%.1f", Date().timeIntervalSince(t0)))s：AX 抓不到窗口/文本"
                    + "（进程可能已退出，也可能窗口关了 —— 后面用 aliveness 采样区分）")
            fflush(stdout)
        }
    }
    if Date().timeIntervalSince(lastTimeline) >= 3.0 {
        lastTimeline = Date()
        let area = snap.filter {
            $0.contains("更新") || $0.contains("下载") || $0.contains("重启") || $0.contains("安装")
        }
        print("  ⏱ \(String(format: "%.0f", Date().timeIntervalSince(t0)))s: \(area.joined(separator: " ｜ "))")
        fflush(stdout)
    }
    usleep(150_000)
}
print("WATCH-END hits=\(hits.count) elapsed=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
print("--- 最后一拍的更新区文本（用来判断终点是「已就绪」还是别的）---")
for s in lastAll where s.contains("更新") || s.contains("下载") || s.contains("重启") || s.contains("版本") {
    print("  · \(s)")
}
