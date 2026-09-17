import AppKit
import SwiftUI

/// 离屏渲染工具：把 SwiftUI 视图画进位图，再量**墨迹**（深色像素）或**某个颜色的覆盖范围**。
///
/// ## 为什么只能这么量
///
/// SwiftUI 的 `Text` / `Image` 在 AppKit 视图树里**没有任何对应视图**
/// （`NSHostingView.subviews` 是空的，整棵树里找不到 `NSTextField`，
/// 无障碍子树也是懒建的），「这个视图到底画了多大」问不到 AppKit —— 只能看**渲染结果**。
///
/// ## 两个必须记住的坑
///
/// 1. **缓冲区不保证清零** → 必须显式分配 `NSBitmapImageRep`，不要复用别人的。
/// 2. **量之前先确认渲染通路是通的**（放一个已知会命中的对照组）。
///    「0 命中」有两种含义：真的没有，或**判据本身坏了** —— 两者长得一模一样。
///    本仓库已经在这上面栽过两次。
///
/// ⚠️ `TitleBarBaselineTests` 里有一份**更早的、只量列/行范围**的实现，先于本文件存在。
/// 两者判据一致（深色阈值 0.75），只是那两份返回的是区间而不是总数/包围盒。
/// 新写的测试请用本文件，不要再来第三份。
@MainActor
enum OffscreenRender {

    /// 把 `view` 画进 `size` 大小的位图（scale 2，与真机 Retina 一致）。
    ///
    /// `appearance` 默认 `.aqua`（浅色）。**深色页面必须显式传 `.darkAqua`** ——
    /// AppKit 宿主的外观会覆盖 SwiftUI 环境值，深色稿在浅色宿主里渲染出来的是浅色版。
    ///
    /// `background` 默认白（``inkCount`` 的「深色墨迹」判据依赖它）。
    /// **量 `ContentView` 这类自带不透明玻璃的页面时必须传 `.clear`** ——
    /// 垫一层白底会把半透明玻璃透出来的地方抬到接近 255，
    /// 亮像素判据（见 ``brightPixels(_:size:in:above:appearance:background:)``）就废了。
    static func bitmap(
        _ view: some View, size: CGSize, appearance: NSAppearance.Name = .aqua,
        background: Color = .white
    ) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let scale: CGFloat = 2
        let hosting = NSHostingView(rootView: view.background(background))
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// 深色像素个数（任一通道 < 0.75）。判据与 `TitleBarBaselineTests` 一致。
    static func inkCount(_ view: some View, size: CGSize) -> Int {
        guard let rep = bitmap(view, size: size) else { return -1 }
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75 { n += 1 }
            }
        }
        return n
    }

    /// 符合 `matching` 的像素的**包围盒**（pt，原点左上）。用来量「某块底色到底画了多大」。
    ///
    /// **必须用纯色去量**：判定一个接近背景色的半透明填充，阈值怎么定都说不清；
    /// 换成纯黑/纯白之后「覆盖到哪」就是确定的。
    static func boundingBox(
        _ view: some View, size: CGSize, scale: CGFloat = 2,
        matching: (NSColor) -> Bool
    ) -> CGRect? {
        guard let rep = bitmap(view, size: size) else { return nil }
        var minX = rep.pixelsWide
        var minY = rep.pixelsHigh
        var maxX = -1
        var maxY = -1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y), matching(c) else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale)
    }

    /// `rect`（pt，原点左上）内**亮度 > `above`** 的像素个数。区域外不参与。
    ///
    /// ## 判据选型的实测依据（2026-09-16）
    ///
    /// 要判「标题栏刷新按钮那一格画的是箭头还是 spinner」，在**离屏出图**的环境里量过三种判据
    /// （`main-window-dark.png`，2x，刷新盒 x ∈ [730, 758]、y ∈ [0, 32]pt，
    /// 设置盒 x ∈ [760, 788]pt 作同款图标参照）：
    ///
    /// | 判据 | 箭头 | spinner | 分辨力 |
    /// |---|---|---|---|
    /// | 峰值亮度 | 168 | 158 | ❌ 只差 10 |
    /// | 最大连通块 | 174 | 36 | ✅ 5 倍，但要写洪泛填充 |
    /// | **亮度 >118 的像素数** | **174** | **93** | ✅ **近 2 倍，够用** |
    ///
    /// ⚠️ **别把真机量到的「箭头 245 / spinner 160」搬过来** —— 那是 `screencapture`
    /// 拍真实窗口的数，离屏渲染里同一个 `mutedForeground` 图标只有 168。
    /// **同一个判据不能跨环境搬**（本轮踩到，第一版断言就是照搬真机数字写死的）。
    ///
    /// ⚠️ `above` 是**相对阈值**，只在深色底（背景峰值 78）上有意义；
    /// 浅色页面图标是深色的，得换判据。`background` 默认白，
    /// **量 `ContentView` 这类自带不透明玻璃的页面必须传 `.clear`**。
    static func brightPixels(
        _ view: some View, size: CGSize, in rect: CGRect, above: Int = 118,
        appearance: NSAppearance.Name = .aqua, background: Color = .white
    ) -> Int {
        guard let rep = bitmap(view, size: size, appearance: appearance, background: background)
        else { return -1 }
        let scale: CGFloat = 2
        let x0 = max(0, Int(rect.minX * scale))
        let x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale))
        let y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        guard x0 < x1, y0 < y1 else { return -1 }
        var n = 0
        for x in x0..<x1 {
            for y in y0..<y1 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if Int(max(c.redComponent, c.greenComponent, c.blueComponent) * 255) > above { n += 1 }
            }
        }
        return n
    }

    /// `rect`（pt，原点左上）内**红色占优**的像素个数：`r − max(g, b) > above`（0…255）。
    ///
    /// ## 用途：断言「某段文字不是红的」
    ///
    /// 「这个视图有没有被染红」问不到视图树（SwiftUI 的 `Text` 在 AppKit 里没有对应视图），
    /// 只能看渲染结果。判据要能**同时**满足两件事：红字算红、灰字不算红。
    ///
    /// | 被测像素 | `r − max(g,b)` | 结论 |
    /// |---|---|---|
    /// | `#FF3B30`（`Palette.error`） | 255 − 59 = **196** | ✅ 算红 |
    /// | 上面这红与白各半混（抗锯齿边） | 255 − 157 = **98** | ✅ 仍算红 |
    /// | `#1D1D1F`（`Palette.foreground`） | 29 − 31 = **−2** | ✅ 不算红 |
    /// | `rgba(60,60,67,.62)` 压在白上 ≈ `#86868B` | 134 − 139 = **−5** | ✅ 不算红 |
    /// | 纯白底 | 0 | ✅ 不算红 |
    ///
    /// `above` 默认 **60**：离抗锯齿边的 98 留了近 40 的余量，离灰字的 0 附近也留了 60。
    /// ⚠️ **必须带对照组**：本仓库已经栽过两次「0 命中」——
    /// 真的没有红色，与判据本身坏了，两者长得一模一样。
    /// 所以断言里要有一条「已知会命中」的红色样本。
    static func redPixels(
        _ view: some View, size: CGSize, in rect: CGRect, above: Int = 60,
        appearance: NSAppearance.Name = .aqua, background: Color = .white
    ) -> Int {
        guard let rep = bitmap(view, size: size, appearance: appearance, background: background)
        else { return -1 }
        let scale: CGFloat = 2
        let x0 = max(0, Int(rect.minX * scale))
        let x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale))
        let y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        guard x0 < x1, y0 < y1 else { return -1 }
        var n = 0
        for x in x0..<x1 {
            for y in y0..<y1 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = c.redComponent * 255
                let g = c.greenComponent * 255
                let b = c.blueComponent * 255
                if Int(r - max(g, b)) > above { n += 1 }
            }
        }
        return n
    }
}
