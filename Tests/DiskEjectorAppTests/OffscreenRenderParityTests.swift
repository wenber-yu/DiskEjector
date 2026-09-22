import AppKit
import SwiftUI
import Testing

/// ``OffscreenRender`` 的**快路径**（缓冲区直读）与**参考实现**（逐像素 `colorAt`）的等价性守卫。
///
/// ## 为什么必须有这条（2026-09-23）
///
/// 为了让最重的离屏量测快起来，``OffscreenRender`` 把逐像素 `colorAt` 换成了直读
/// `NSBitmapImageRep.bitmapData`。这一步**改变了读像素的方式**，而它的失效方式恰好是本仓库
/// 最怕的那种 —— **数字看起来照样是个数字**：预乘 / 非预乘弄反，扫出来的计数仍是个合理的
/// 整数，只是**悄悄偏了**，没有任何东西会红。
///
/// 所以这里不写「看着差不多」，而是把两条路**逐像素**对一遍：
/// ``白底样本直读与colorAt逐像素相等`` / ``透明底样本直读与colorAt逐像素相等``（容差 1e-12，
/// 实测语义差是 0.498、浮点末位是 2.8e-17，见 `assertPixelParity` 的说明）
/// 加上 ``四个量与参考实现一致``（四个量**精确**相等）。
///
/// ## 覆盖面是**挑过**的，不是随便画个视图
///
/// 直读与 `colorAt` 只在**半透明**像素上会分叉（缓冲区是预乘的、`colorAt` 不是）。
/// 所以样本里必须同时有不透明纯色、**半透明压透明底**（分叉点）、半透明压白底、抗锯齿边。
/// 全是纯色的话这条守卫**看着绿、其实一个字都没验到** —— 所以另有 ``分叉点真的被扫到了``
/// 一条，专门证明「这次渲染里确实有半透明像素、且预乘与非预乘确实不同」。
@MainActor
struct OffscreenRenderParityTests {

    // MARK: - 样本

    private let side: CGFloat = 40

    private var size: CGSize { CGSize(width: side, height: side) }

    /// 白底样本：四条横带（半透明红 / 不透明黑 / 半透明白 / 不透明蓝）+ 一个圆形。
    ///
    /// 白底 ⇒ 整张图**没有未绘制区域**，逐像素对比不会碰到未初始化内存。
    /// 圆形是为了拿到**抗锯齿边**（大量非整数通道值）—— 纯色横带的通道值都是 `n/255`，
    /// 覆盖不到取整 / 舍入那类偏差。
    private var onWhite: some View {
        ZStack {
            VStack(spacing: 0) {
                Color.red.opacity(0.5).frame(height: side / 4)
                Color.black.frame(height: side / 4)
                Color.white.opacity(0.25).frame(height: side / 4)
                Color.blue.frame(height: side / 4)
            }
            Circle().fill(Color.black).frame(width: side / 2, height: side / 2)
        }
        .frame(width: side, height: side)
    }

    /// 透明底样本：**整幅**半透明红压 `.clear`，两条横带各一个 alpha
    /// —— 这是唯一会出现「预乘 ≠ 非预乘」的场合。
    ///
    /// 故意**铺满整幅**（不用圆角矩形）：那样四角会是「未绘制区域」，
    /// 缓冲区里是什么取决于 `NSBitmapImageRep` 有没有清零 —— 那是另一个问题，
    /// 不该混进这条守卫里。
    ///
    /// ## ⚠️ 两个 alpha 是**挑过**的（变异测试逼出来的，2026-09-23）
    ///
    /// 「忘掉除以 alpha」这个变异在**计数**层面能不能被看见，取决于**阈值**：
    ///
    /// | alpha | 预乘字节 | `brightPixels`(>118) | `redPixels`(>60) |
    /// |---|---|---|---|
    /// | 0.5 | 128 | 越过（128 > 118）⇒ **看不出来** | 越过 ⇒ **看不出来** |
    /// | **0.2** | **51** | 51 < 118 ⇒ **分叉** | 51 < 60 ⇒ **分叉** |
    ///
    /// 实测：只有 alpha = 0.5 时，变异「把 `r / a` 改回 `r`」下
    /// `四个量与参考实现一致` **仍然全绿**（只有逐像素那条红）——
    /// 也就是说**判据的阈值也是样本的一部分**，挑样本时要连着阈值一起挑。
    /// 0.5 那条留着是因为它在**逐像素**层面更干净（`128 / 128` 恰好是 1.0）。
    private var onClear: some View {
        VStack(spacing: 0) {
            Color.red.opacity(0.2).frame(height: side / 2)
            Color.red.opacity(0.5).frame(height: side / 2)
        }
        .frame(width: side, height: side)
    }

    private func render(_ view: some View, background: Color) throws -> NSBitmapImageRep {
        try #require(
            OffscreenRender.bitmap(view, size: size, background: background),
            "离屏出图失败 —— 这条守卫后面的对比一律作废")
    }

    // MARK: - 参考实现（改动**之前**的写法，逐字照抄）

    // ⚠️ 只有一处**非**逐字：旧写法里 `c.redComponent` 是 `CGFloat`，靠**隐式转换**进 `Double`。
    // 这里一律补成显式 `Double(...)`（§8.130：那个隐式转换在 Swift 6.3.3 上的行为我**没有证据**，
    // 而 `Double(x)` 与隐式转换语义完全一致 —— 补上它不改变任何一条断言的含义）。
    // 对照见 §8.130 的「为什么参考实现也要动」。

    private func refInkCount(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75 { n += 1 }
            }
        }
        return n
    }

    private func refBoundingBox(
        _ rep: NSBitmapImageRep, scale: CGFloat, _ matching: (Double, Double, Double) -> Bool
    ) -> CGRect? {
        var minX = rep.pixelsWide
        var minY = rep.pixelsHigh
        var maxX = -1
        var maxY = -1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                guard
                    matching(
                        Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                else { continue }
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

    private func refBrightPixels(
        _ rep: NSBitmapImageRep, in rect: CGRect, above: Int, scale: CGFloat
    ) -> Int {
        guard let (x0, x1, y0, y1) = clamped(rep, rect, scale) else { return -1 }
        var n = 0
        for x in x0..<x1 {
            for y in y0..<y1 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if Int(max(c.redComponent, c.greenComponent, c.blueComponent) * 255) > above { n += 1 }
            }
        }
        return n
    }

    private func refRedPixels(
        _ rep: NSBitmapImageRep, in rect: CGRect, above: Int, scale: CGFloat
    ) -> Int {
        guard let (x0, x1, y0, y1) = clamped(rep, rect, scale) else { return -1 }
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

    private func clamped(
        _ rep: NSBitmapImageRep, _ rect: CGRect, _ scale: CGFloat
    ) -> (Int, Int, Int, Int)? {
        let x0 = max(0, Int(rect.minX * scale))
        let x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale))
        let y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        return (x0, x1, y0, y1)
    }

    // MARK: - 断言

    /// **核心**：直读的 RGB 与 `colorAt` 的通道值**逐像素一致**。
    ///
    /// ## ⚠️ 容差 `1e-12` 是**量出来的**，不是随手写的（2026-09-23）
    ///
    /// 一开始写的是**逐位相等**（`worst == 0`）。它在白底样本上过，在透明底样本上**红**：
    ///
    /// | 情形 | 实测最大差 | 数量级 |
    /// |---|---|---|
    /// | **语义错**（忘掉除以 alpha） | `0.4980392156862745` | 1e-1 |
    /// | **浮点末位**（`colorAt` 自己的非预乘算法） | `2.7755575615628914e-17` | 1e-17 |
    ///
    /// ⇒ `colorAt` 的非预乘**不是** `Double(字节) / Double(alpha)` 的逐位复刻
    /// （它多半在内部用另一种运算次序 / 更窄的精度）。差 **15 个数量级**，
    /// 所以 `1e-12` 既能挡住语义错、又不会因为末位而假红。
    ///
    /// ⚠️ **但「末位差」不等于无害**：判据里那些 `Int(x * 255)` 是**截断**，
    /// 一个刚好落在整数上的值可能因为末位被截掉 1。所以这一层**只管语义**，
    /// 「截断有没有被末位改掉」由 ``四个量与参考实现一致`` 在**计数**层面兜 ——
    /// 那一条是**精确相等**的断言，末位差一旦翻掉某个像素的分类，它立刻红。
    private func assertPixelParity(_ view: some View, background: Color, tag: String) throws {
        let rep = try render(view, background: background)
        var checked = 0
        var worst = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let got = try #require(OffscreenRender.rgb(rep, x: x, y: y), "\(tag)：读不出 (\(x), \(y))")
                let want = try #require(rep.colorAt(x: x, y: y), "\(tag)：`colorAt` 读不出 (\(x), \(y))")
                let wantRGB = (
                    Double(want.redComponent), Double(want.greenComponent),
                    Double(want.blueComponent)
                )
                let d = max(
                    abs(got.0 - wantRGB.0),
                    max(abs(got.1 - wantRGB.1), abs(got.2 - wantRGB.2)))
                worst = max(worst, d)
                checked += 1
            }
        }
        #expect(
            checked == rep.pixelsWide * rep.pixelsHigh,
            "\(tag)：只比了 \(checked) 个像素，应比 \(rep.pixelsWide * rep.pixelsHigh) 个")
        #expect(
            worst < 1e-12,
            """
            \(tag)：两条路最大差 \(worst)（比了 \(checked) 个像素）—— 容差 1e-12。\
            差到 0.1 量级就是**预乘 / 非预乘弄反了**（缓冲区是预乘的，`colorAt` 返回非预乘，\
            实测差 0.498）；差到 1e-17 量级才是浮点末位，属正常（见本函数的说明）。
            """)
    }

    @Test func 白底样本直读与colorAt逐像素相等() throws {
        try assertPixelParity(onWhite, background: .white, tag: "白底")
    }

    @Test func 透明底样本直读与colorAt逐像素相等() throws {
        try assertPixelParity(onClear, background: .clear, tag: "透明底")
    }

    /// **对照组**：证明这次渲染里**确实**存在「预乘 ≠ 非预乘」的像素。
    ///
    /// 缺了它，上面两条有可能是在**全不透明**的样本上通过的 —— 那种情况下两条路本来就一样，
    /// 守卫看着绿、其实没验到东西（本项目在静态扫描器上栽过同一个坑：
    /// 阴性结论必须配阳性对照）。
    @Test func 分叉点真的被扫到了() throws {
        let rep = try render(onClear, background: .clear)
        let buf = try #require(
            OffscreenRender.PixelBuffer(rep), "缓冲区布局不认识 —— 快路径根本没启用，上面的对比是在拿兜底跟兜底比")

        var semiTransparent = 0
        var divergent = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let (r, _, _, a) = buf.rgba(x: x, y: y)
                guard a > 0, a < 1 else { continue }
                semiTransparent += 1
                // `r * a` 就是缓冲区里那个**预乘**字节 / 255；`r` 是 `colorAt` 的**非预乘**值。
                // 两者不同 ⇒ 「除以 alpha」这一步真的被验到了。
                if abs(r * a - r) > 0.1 { divergent += 1 }
            }
        }
        #expect(
            semiTransparent > 100,
            "样本里只有 \(semiTransparent) 个半透明像素 —— 这条对照组没验到东西，样本被换弱了")
        #expect(
            divergent > 100,
            "半透明像素里只有 \(divergent) 个「预乘 ≠ 非预乘」—— 缓冲区不是预乘的了？整段推理要重来")
    }

    /// 四个量各自与参考实现对齐 —— `rgb` 逐像素相等还不够：**区域裁剪、阈值取整**都是独立代码。
    @Test func 四个量与参考实现一致() throws {
        let whole = CGRect(x: 0, y: 0, width: side, height: side)
        let topHalf = CGRect(x: 0, y: 0, width: side, height: side / 2)
        let scale: CGFloat = 2
        let isRed: (Double, Double, Double) -> Bool = { r, g, b in
            Int(r * 255 - max(g * 255, b * 255)) > 60
        }

        // 白底：四个量都能对（`inkCount` / `boundingBox` 的底写死是白的）。
        let white = try render(onWhite, background: .white)
        #expect(
            OffscreenRender.inkCount(onWhite, size: size) == refInkCount(white),
            "inkCount 与参考实现不一致")
        #expect(
            OffscreenRender.boundingBox(white, scale: scale, matchingRGB: isRed)
                == refBoundingBox(white, scale: scale, isRed),
            "boundingBox 与参考实现不一致")
        #expect(
            OffscreenRender.brightPixels(onWhite, size: size, in: topHalf, above: 118)
                == refBrightPixels(white, in: topHalf, above: 118, scale: scale),
            "brightPixels 与参考实现不一致")
        #expect(
            OffscreenRender.redPixels(onWhite, size: size, in: whole, above: 60)
                == refRedPixels(white, in: whole, above: 60, scale: scale),
            "redPixels 与参考实现不一致")

        // 透明底：只对能传底的量。**这条是冲着预乘去的** —— 白底下半透明像素被背景抬到不透明，
        // 分叉根本不出现。
        let clear = try render(onClear, background: .clear)
        #expect(
            OffscreenRender.brightPixels(onClear, size: size, in: whole, above: 118, background: .clear)
                == refBrightPixels(clear, in: whole, above: 118, scale: scale),
            "透明底 brightPixels 与参考实现不一致")
        #expect(
            OffscreenRender.redPixels(onClear, size: size, in: whole, above: 60, background: .clear)
                == refRedPixels(clear, in: whole, above: 60, scale: scale),
            "透明底 redPixels 与参考实现不一致")
    }
}
