import CoreGraphics
import Foundation

// windowid —— 列出**在屏**窗口的 `(窗口号, 拥有者, 尺寸, 标题)`。
//
// ## 为什么需要它
//
// 验证 UI 时不想抢焦点、也不想截整屏：`screencapture -x -o -l<窗口号>` 能只截那一个窗口，
// 但它要**窗口号**，而窗口号只有 `CGWindowListCopyWindowInfo` 拿得到。
// 本仓库此前每次都要临时写一段，索性收成一个探针（与 `axtext.swift` / `sendkey.swift` 同款）。
//
// ## 用法
//
//     source Tools/clt_swift_env.sh
//     swift Tools/probe/windowid.swift <拥有者名子串>      # 只列拥有者名含该子串的窗口
//     swift Tools/probe/windowid.swift                     # 列全部（在屏、非桌面元素）
//
// 输出一行一个窗口，制表符分隔：`<窗口号>\t<拥有者>\t<宽>x<高>\tonscreen=<0|1>\t<标题>`
//
// ## 两个实测坑（都会让「窗口明明在」被判成「没找到」）
//
// 1. **`kCGWindowIsOnscreen` 是 `NSNumber`，`as? Bool` 恒失败**
//    ⇒ 那样写出来的 always-false 会被读成「窗口不在屏上」，于是白白怀疑窗口没建起来。
//    必须走 `NSNumber.boolValue`。
// 2. **`kCGWindowName` 需要屏幕录制权限**才给得出真名（没权限时是空串）——
//    所以**判据不要挂在标题上**，挂拥有者名 + 尺寸。窗口号本身不受影响，
//    `screencapture` 也不需要这个权限就能按窗口号截。
let args = CommandLine.arguments
let filter: String? = args.count > 1 ? args[1] : nil

guard
    let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else {
    FileHandle.standardError.write("取不到窗口列表（CGWindowListCopyWindowInfo 返回 nil）\n".data(using: .utf8)!)
    exit(3)
}

var rows: [String] = []
for info in list {
    let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
    if let filter, !owner.contains(filter) { continue }
    let number = info[kCGWindowNumber as String] as? Int ?? -1
    let title = info[kCGWindowName as String] as? String ?? ""
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    // ⚠️ 见文件头第 1 条：`as? Bool` 会恒失败，必须走 NSNumber。
    let onscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    rows.append(
        "\(number)\t\(owner)\t\(Int(width))x\(Int(height))\tonscreen=\(onscreen ? 1 : 0)\t\(title)")
}

for row in rows { print(row) }

// ⚠️ 装置自证：**一条都没列出来**与「那个窗口不在」逐字相同 ⇒ 用非 0 退出码分开这两件事。
// 调用方（脚本）据此判断「是没找到」还是「是装置瞎了」。
if rows.isEmpty {
    FileHandle.standardError.write(
        "没有任何窗口匹配「\(filter ?? "<全部>")」—— 要么它真的不在屏上，要么它属于别的会话/空间\n"
            .data(using: .utf8)!)
    exit(1)
}
