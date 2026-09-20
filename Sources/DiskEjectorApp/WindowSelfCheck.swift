import AppKit

/// `--preview-*` 真机自检里**不碰应用状态**的那一半量测函数。
///
/// **为什么单独一个类型**：这些函数**只吃参数、不读任何 `AppDelegate` 成员**，
/// 做成 `static func` 之后这件事就由**编译器**保证（`static` 里没有 `self`）——
/// 而不是靠「我扫过一遍」。想加一个读应用状态的函数，**别放这里**。
///
/// 搬出来的那一半是 7 个（按源文件顺序）：``trafficLightUnion`` /
/// ``checkTrafficLightBaseline`` / ``checkTitleBarHorizontalSymmetry`` /
/// ``measureRedLightInkCenter`` / ``checkEmptyStateInsteadOfSkeleton`` /
/// ``dumpSettingsWindowState`` / ``waitUntilAppIsActive``；
/// 需要读窗口/状态属性的入口与 `dump*` 仍在 `DiskEjectorApp.swift` 里。
///
/// ⚠️ 判据是**实测**的（SPEC §8.101.4–§8.101.5）：同一份测量连踩过三次「口径错」，
/// 最终以「能不能编译成 `static func`」为准 —— 编译器是这件事唯一的裁判。
///
/// ⚠️ **搬运的边界口径**（§8.101.5 踩过）：一个函数的「单元」= 它**自己的**文档注释 +
/// 属性行 + 声明 + 函数体。别用「到下一个函数声明前」当区间 —— 那会把**下一个函数的**
/// 文档注释算进来（第一版就是这么错的：4 个函数丢了注释，`waitUntilMainWindowIsKey`
/// 顶上了别人的注释）。验收必须**按顺序**比：多行集合比对是**位置盲**的，查不出错位。
@MainActor
enum WindowSelfCheck {

    /// 等应用真的变成前台（最多 2 秒）。
    ///
    /// `NSApp.activate(ignoringOtherApps:)` 只是**请求**激活，真正生效要等下一次
    /// 激活通知；而 `NSPopover.show` 在应用不在前台时会**静默失败**（`isShown` 保持 false）。
    @MainActor
    static func waitUntilAppIsActive() async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !NSApp.isActive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 系统交通灯在**窗口坐标**里的并集（原点在左下）。
    ///
    /// 三个按钮各自 `convert(_:to: nil)` 到窗口坐标后再求并集 —— 它们的父视图是
    /// `NSThemeFrame`，直接读 `frame` 拿到的是标题栏容器坐标系，与窗口坐标**不是一回事**
    /// （实测差一个标题栏高度，会把「距顶 16pt」算成「距顶 550pt」）。
    static func trafficLightUnion(in window: NSWindow) -> NSRect {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(NSRect.null) { $0.union($1) }
    }

    /// 核对「系统交通灯的垂直中心」与「标题栏内容带的中心」是否重合，并打印数字。
    ///
    /// **为什么这条断言必须存在**：交通灯的位置由 AppKit 决定，而内容带高度
    /// ``DesignTokens/Size/titleBarBandHeight`` 是**设计稿给的** 52。两边靠
    /// ``alignTrafficLights(in:)`` 主动对齐 —— 那是一次「改系统按钮 frame」的操作，
    /// AppKit 哪天改了行为（或某个 macOS 把灯挪了），代码不会自己知道 ——
    /// 只有真机量一遍才会红。
    /// 而**离屏出图结构上测不到**这件事：离屏没有窗口，也就没有交通灯。
    ///
    /// 断言的是**两个数**：交通灯中心距窗口顶的距离，与内容带高度的一半。
    /// 前者不对时，把 ``DesignTokens/Size/systemTrafficLightCenterFromTop``
    /// 改成失败信息里的实测值即可。
    ///
    /// - Returns: 交通灯并集（取不到时为 `.null`），供调用方接着做横向判断。
    @discardableResult
    static func checkTrafficLightBaseline(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> NSRect {
        let lights = trafficLightUnion(in: window)
        guard !lights.isNull else {
            mismatches.append("\(label) 取不到交通灯位置（standardWindowButton 全为 nil）")
            return .null
        }
        // 窗口坐标原点在左下 → 「距顶」= 窗口高 − y。
        let centerFromTop = window.frame.height - lights.midY
        let band = DesignTokens.Size.titleBarBandHeight
        let expected = band / 2
        print("    交通灯并集=\(lights) 垂直中心距顶=\(centerFromTop)pt（内容带 \(band)pt 的中心应为 \(expected)pt）")
        if abs(centerFromTop - expected) > 1 {
            mismatches.append(
                "\(label) 交通灯垂直中心距顶 \(centerFromTop)pt，内容带中心 \(expected)pt，"
                    + "相差 \(centerFromTop - expected)pt —— 标题与红绿灯不在同一条基线上。"
                    + "对齐是**幂等**的（``alignTrafficLights(in:)`` 量出当前位置再补差额），"
                    + "所以这里红通常意味着它没被调用，或被后续布局拨回 —— "
                    + "检查调用时机，而不是去改某个补偿常量")
        }
        return lights
    }

    /// 核对「红灯中心距窗口左边」与「设置按钮中心距窗口右边」是否**对称**。
    ///
    /// **为什么这条断言必须存在**：红灯的位置由 AppKit 决定（我们只在竖直方向挪过它，
    /// 见 ``alignTrafficLights(in:)``），设置按钮的位置由 SwiftUI 的 `padding` 决定 ——
    /// **两边来源不同**，凭印象对齐一定会对错。设计稿 DOM 探针实测（2026-09-17）：
    /// 红灯中心距左 **26.5pt**、设置按钮中心距右 **26.5pt**，即设计意图是**镜像对称**。
    ///
    /// ⚠️ **不要拿「按钮盒边缘」去比「圆点边缘」** —— 红灯是 12pt 圆点，
    /// 设置按钮是 28pt 的盒（里面 14pt 图标）。盒边缘距边 12.5、圆点边缘距边 20.5，
    /// 看着差 8pt，但**光学上是齐的**。判据只能用**中心**。
    ///
    /// - Returns: `红灯中心距左 − 设置按钮中心距右`，供调用方接着判断。
    @discardableResult
    static func checkTitleBarHorizontalSymmetry(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> CGFloat {
        guard let close = window.standardWindowButton(.closeButton) else {
            mismatches.append("\(label) 取不到关闭按钮（红灯），无法核对水平对称")
            return .nan
        }
        // `NSTitlebarView` 的坐标与窗口一致（原点左下），x 方向不用翻转。
        let light = close.convert(close.bounds, to: nil)
        let lightCenter = light.midX
        // 设置按钮是 SwiftUI 画的，布局是确定的，不必量渲染：
        // 右边距（trailing padding）+ 28pt 按钮盒的一半。
        let gearCenter =
            DesignTokens.Spacing.titleBarTrailing + DesignTokens.Size.titleBarIconButton / 2
        let delta = lightCenter - gearCenter
        print(
            "    红灯中心距左=\(lightCenter)pt（按钮 frame=\(light)） "
                + "设置按钮中心距右=\(gearCenter)pt 差=\(delta)pt")
        if abs(delta) > 1 {
            mismatches.append(
                "\(label) 标题栏左右不对称：红灯中心距左 \(lightCenter)pt，"
                    + "设置按钮中心距右 \(gearCenter)pt，相差 \(delta)pt。"
                    + "设计稿两侧都是 \(DesignTokens.Size.titleBarInsetCenter)pt —— "
                    + "调 DesignTokens.Spacing.titleBarTrailing 或 "
                    + "DesignTokens.Size.systemTrafficLightCenterFromLeft 使其相等")
        }

        // **绝对断言兜底**：上面比的两个数里，红灯那个是我们自己改出来的 frame ——
        // 同源比较守不住「改歪了」。这里数一遍真机像素，独立确认红灯**画**在哪。
        if let ink = measureRedLightInkCenter(window: window, label: label, mismatches: &mismatches) {
            let anchor = DesignTokens.Size.titleBarInsetCenter
            if abs(ink - anchor) > 1.5 {
                mismatches.append(
                    "\(label) 红灯**渲染**出来的中心距左 \(ink)pt，设计稿锚点 \(anchor)pt —— "
                        + "frame 层面是对齐的，但画出来的位置不是 —— "
                        + "检查 alignTrafficLights 是否真的作用到了被绘制的那个视图")
            }
        }
        return delta
    }

    /// 从**真机渲染的像素**里量红灯的墨迹中心，兜住「frame 对了但画的位置不对」。
    ///
    /// **为什么必须有这条**：``checkTitleBarHorizontalSymmetry`` 比较的是
    /// 「红灯 frame 中心」与「设置按钮中心」，而红灯的 frame **正是我们自己改的**
    /// （``alignTrafficLights(in:)``）—— 这是典型的自证陷阱：
    /// 断言与被断言的对象同源，改歪了它可能照样是绿的。
    /// 这里绕开 frame，直接**数屏幕上的红色像素**，是独立的一条证据。
    ///
    /// **扫描范围为什么只取左半侧的一小条**：主窗口里有 `.btn--danger` 红色按钮
    /// （「关闭并推出」），全窗口扫红色会把那些按钮也算进来 —— 与「量不到」
    /// 一样会让数字失去意义。红灯只在标题栏那一条（距顶 20…32pt）里。
    ///
    /// - Returns: 量到的红灯墨迹中心距窗口左边的距离（pt）；量不到时为 `nil`。
    static func measureRedLightInkCenter(
        window: NSWindow, label: String, mismatches: inout [String]
    ) -> CGFloat? {
        let scale = window.backingScaleFactor
        let band = DesignTokens.Size.titleBarBandHeight
        let y0 = Int((band / 2 - 7) * scale)
        let y1 = Int((band / 2 + 7) * scale)
        let xLimit = Int(200 * scale)

        // ⚠️ **交通灯的红色只在窗口处于活跃态时才画**（2026-09-17 实测）：
        // 应用还没抢到前台时，系统把三个灯画成**灰色** —— 窗口已上屏、内容墨迹正常，
        // 但红色像素是 **0**。抓一次就断言，会把「还没激活完」误报成「红灯没画出来」，
        // 于是这条断言**偶发变红**（实测约 1/3 次），跑久了没人再看它 ——
        // 一个会随机变红的守卫比没有守卫更糟。
        //
        // 所以这里**轮询重试**，而不是抓一次就下结论：每轮之间跑一次 run loop，
        // 让 AppKit 有机会把标题栏按活跃态重画。重试只在「数不可信」时发生，
        // **红灯真的画歪了不会重试**（那时 count 仍是合理的 450 上下，直接走下面的中心断言）。
        var count = 0
        var minX = Int.max
        var maxX = Int.min
        var pixelsWide = 0
        let deadline = Date().addingTimeInterval(3)
        while true {
            let windowID = CGWindowID(window.windowNumber)
            if let cg = CGWindowListCreateImage(
                CGRect.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming)
            {
                // `NSBitmapImageRep(cgImage:)` 在 macOS 上**不是** Optional，不能放 `guard let` 里。
                let rep = NSBitmapImageRep(cgImage: cg)
                pixelsWide = rep.pixelsWide
                count = 0
                minX = Int.max
                maxX = Int.min
                for y in y0..<min(rep.pixelsHigh, y1) {
                    for x in 0..<min(rep.pixelsWide, xLimit) {
                        guard let c = rep.colorAt(x: x, y: y) else { continue }
                        // 红灯 ≈ #FF5F57：红分量高、且明显压过绿蓝。
                        let isRed =
                            c.redComponent > 0.7
                            && c.redComponent - c.greenComponent > 0.25
                            && c.redComponent - c.blueComponent > 0.2
                        if isRed {
                            count += 1
                            if x < minX { minX = x }
                            if x > maxX { maxX = x }
                        }
                    }
                }
                // **自证**：12pt 直径的圆在 2x 下约 450 个像素。太少说明只扫到抗锯齿边缘，
                // 太多说明把别的东西（红色按钮、窗口外内容）扫了进来 —— 两种都不能算通过。
                if count > 50, count < 4000 { break }
            }
            guard Date() < deadline else { break }
            // 跑一次 run loop：激活状态的变化要靠它才会变成一次重绘。
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        guard count > 50, count < 4000 else {
            // **失败信息必须能分辨两种原因**：环境（没抢到前台 → 灯是灰的）还是缺陷。
            // 第一版只说「这个数不可信」，排查时得自己重跑一遍才知道是哪种。
            let inactive = !window.isKeyWindow || !NSApp.isActive
            mismatches.append(
                "\(label) 标题栏那一条里扫到 \(count) 个红色像素（12pt 圆的合理量级是 200…900）——"
                    + "当时 NSApp.isActive=\(NSApp.isActive) 主窗口isKey=\(window.isKeyWindow) "
                    + "图像宽=\(pixelsWide)px。"
                    + (count == 0 && inactive
                        ? "**应用没抢到前台**，系统把交通灯画成了灰色 —— 这是环境问题，"
                            + "不是布局缺陷；在交互式终端里重跑，或先点一下窗口再跑。"
                        : "要么玻璃没渲染完，要么扫描范围把红色按钮包了进来。这个数不可信"))
            return nil
        }
        let center = CGFloat(minX + maxX) / 2 / scale
        print(
            "    红灯墨迹（真机像素）=\(CGFloat(minX) / scale)…\(CGFloat(maxX) / scale)pt "
                + "中心距左=\(center)pt 像素数=\(count)")
        return center
    }

    /// 无外置磁盘时，列表区必须画**空状态**，而不是卡在首屏骨架层。
    ///
    /// **为什么只有真机测得到**：`cacheDisplay` 不跑 SwiftUI 的 `.task`
    /// （没有事件循环），离屏渲染时两个状态位都停在初始值 `false` ——
    /// 无论实现对不对，离屏结果都一样。**结构上测不到**，与交通灯同类。
    ///
    /// **判据**：数列表区（标题栏以下）的**深色像素**。
    /// 空状态有图标 + 标题 + 两行说明 + 按钮，墨迹成千；
    /// 骨架层只有 `Palette.subtle` 的浅灰圆角块，**几乎没有深色墨迹** ——
    /// 两者量级差得远，不需要精细阈值。
    ///
    /// **列表非空时跳过**：那时列表区画的是磁盘行（也有大量深色文字），判据不成立。
    /// 跳过而不是硬跑 —— 假红比不测更糟。
    ///
    /// ⚠️ **`diskStore` 必须是窗口里那个视图真正在读的 store**，不能写 `DiskListStore.shared`：
    /// 空状态自检（`--preview-main-window-empty-keys`）注入的是一个**独立实例**，
    /// 拿 `.shared` 去数「有几块盘」会读到真实硬件，然后心安理得地跳过 —— 断言静默失效。
    ///
    /// **这个「跳过」曾经是常态**（2026-09-17 查明）：列表来源硬编码 `.shared`，
    /// 而开发者本机长期插着盘 —— 于是这条断言只在少数时候执行。
    /// 注入点就位后，它在**任何硬件状态下**都能跑。
    static func checkEmptyStateInsteadOfSkeleton(
        window: NSWindow, diskStore: DiskListStore, label: String, mismatches: inout [String]
    ) {
        let diskCount = diskStore.disks.count
        guard diskCount == 0 else {
            print("    空状态核对：跳过（本次渲染用的列表有 \(diskCount) 块磁盘，列表区画的是磁盘行）")
            return
        }
        // ⚠️ **判据只在浅色外观下成立**：深色底本身就是「深色像素」，
        // 整屏都会被算成墨迹，这条断言会假绿。深色模式跳过，不硬跑。
        // ⚠️ **深色外观下必须跳过，不能硬跑**：深色底本身就是「深色像素」，
        // `listInk` 会无条件远超阈值 —— 那不是通过，是**假绿**。
        //
        // ⚠️ 而这条跳过在 `--preview-main-window-empty-keys` 下**不应该发生**：
        // 那个模式会把窗口切成浅色（见 ``runMainWindowPreview``），判据要什么底就给什么底。
        // 留着它是防御 —— 万一外观强制没生效，宁可跳过也不要假绿。
        guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua else {
            print(
                "    空状态核对：跳过（当前是深色外观，「深色像素」判据不成立 —— "
                    + "深色底上这条断言会无条件假绿）")
            return
        }
        let windowID = CGWindowID(window.windowNumber)
        guard
            let cg = CGWindowListCreateImage(
                CGRect.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming)
        else {
            mismatches.append("\(label) 抓不到主窗口图像，无法核对空状态")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = window.backingScaleFactor
        let band = DesignTokens.Size.titleBarBandHeight

        /// 数指定 y 带里的深色像素。
        func darkCount(fromTop y0: CGFloat, to y1: CGFloat) -> Int {
            let a = max(0, Int(y0 * scale))
            let b = min(rep.pixelsHigh, Int(y1 * scale))
            guard a < b else { return 0 }
            var n = 0
            for y in a..<b {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75 {
                        n += 1
                    }
                }
            }
            return n
        }

        // **自证**：标题栏必须先有墨迹（标题「外置磁盘」），否则是玻璃没渲染完 ——
        // 那种情况下列表区也一定是空的，会把「没渲染」误读成「骨架层」。
        let titleInk = darkCount(fromTop: 0, to: band)
        guard titleInk > 50 else {
            mismatches.append(
                "\(label) 标题栏只数到 \(titleInk) 个深色像素 —— 窗口玻璃还没渲染完，"
                    + "这次的列表区结果不可信（不能当作「画了骨架」）")
            return
        }

        let listInk = darkCount(fromTop: band, to: window.frame.height)
        // **阈值是变异验证定出来的，不是拍的**：
        // 实测空状态 **11175 ~ 11210**（强制浅色 / 原生浅色各量一次）、
        // 把 bug 造回去（强制显示骨架）后 **394** —— 差 28 倍。
        // 取 2000：离两边都有 5 倍余量，既不因抗锯齿抖动误报，也不漏掉骨架。
        // ⚠️ 第一版阈值写的 200，变异后 394 **照样绿** —— 断言看着在守，其实守不住。
        // **动这个数之前先重跑一次变异验证。**
        let emptyStateInkFloor = 2000
        print(
            "    空状态核对：标题栏墨迹=\(titleInk) 列表区墨迹=\(listInk)"
                + "（空状态实测 11175~11210，骨架层 ≈394，阈值 \(emptyStateInkFloor)）")
        if listInk < emptyStateInkFloor {
            mismatches.append(
                "\(label) 这次渲染用的列表里没有磁盘，列表区却只数到 \(listInk) 个深色像素 —— "
                    + "画的多半是**首屏骨架层**（浅灰圆角块，没有文字），而不是空状态。"
                    + "空状态有图标 + 标题 + 说明 + 按钮，墨迹应是数千量级。"
                    + "判据见 ContentView.showsSkeleton —— 骨架只能由「首屏加载结束」关闭，"
                    + "不能依赖 onChange(of: disks)（无盘时列表永远不变，那个回调不会触发）")
        }
    }

    /// 把设置窗口的状态打到终端，并就地核对。
    ///
    /// 四条断言各有明确后果：
    /// 1. 窗口必须是设计稿的 **480 × 800**（`DesignTokens.Size.settingsPanel`）——
    ///    这条抓的是「`NSHostingView` 把 800+32 的固有尺寸回推给窗口」（实测会撑到 832）；
    /// 2. **玻璃必须覆盖整个窗口内容区**（含 52pt 头部那一带）—— 与主窗口同款的露底捕手。
    ///    判据不是看颜色（离屏取不到桌面），而是问 AppKit 那块 `NSVisualEffectView`
    ///    在窗口里占多大：``GlassSurface`` 用的材质是 `.underWindowBackground`，
    ///    系统标题栏自带的不是这一档，所以能精确挑出「我们自己画的那块玻璃」；
    /// 3. 系统标题栏的标题必须隐藏 —— 否则「设置」在同一个窗口上出现两遍；
    /// 4. **三个系统按钮必须都藏着**（``SettingsWindow``）—— 设计稿的 `.shead` 里没有
    ///    `traffic`，红绿灯的关窗与头部的「完成」是**同一个动作的两个出口**
    ///    （用户 2026-09-16 报告）。
    ///
    /// 第 4 条**只能真机验**：`standardWindowButton(_:)` 是「窗口」才有的东西，
    /// 离屏没有窗口，也就没有按钮可问（返回 `nil`）。
    ///
    /// ⚠️ 这里**曾经**有第 4、5 两条量交通灯的断言（垂直基线、横向不压标题）。
    /// 设置面板不再画红绿灯之后它们失去意义 —— 但**不是删掉了**：
    /// 主窗口仍然在画，那两条原样留在 ``dumpMainWindowState`` / ``checkTrafficLightBaseline``
    /// 里，继续守着「内容带高度 32」这个从灯的实测位置反推出来的常数。
    @MainActor
    static func dumpSettingsWindowState(
        label: String, window: NSWindow, mismatches: inout [String]
    ) {
        let hosting = window.contentView
        // ⚠️ **两边都必须转成窗口坐标再比**。`NSHostingView` 是 flipped 的
        // （`isFlipped == true`，原点在左上），它的 `bounds` 与 `glassEffectFrames`
        // 返回的窗口坐标（原点在左下）**y 轴方向相反** —— 直接比会得到荒谬的结论。
        let contentRect = hosting?.convert(hosting?.bounds ?? .zero, to: nil) ?? .zero
        let glasses = window.glassEffectFrames
        let ours = glasses.filter { $0.material == .underWindowBackground }
        let covered = ours.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        // 显式写类型：在字符串插值里 `.zero` 没有上下文类型可推，Swift 会去猜
        // （实测猜成 `Int.zero`），然后在一个莫名其妙的地方报运算符不匹配。
        let insets: NSEdgeInsets = hosting?.safeAreaInsets ?? NSEdgeInsetsZero
        let size = "\(window.frame.width)×\(window.frame.height)"

        print(
            "  \(label)：上屏=\(window.isVisible) 尺寸=\(size) "
                + "内容区(窗口坐标)=\(contentRect) 安全区=\(insets)"
        )
        print(
            "    标题栏透明=\(window.titlebarAppearsTransparent) "
                + "标题隐藏=\(window.titleVisibility == .hidden) "
                + "背景 alpha=\(window.backgroundColor.alphaComponent) "
                + "不透明=\(window.isOpaque)"
        )
        for (index, glass) in glasses.enumerated() {
            print("    玻璃[\(index)] material=\(glass.material.rawValue) frame=\(glass.frame)")
        }
        print("    自定义玻璃并集=\(covered)")

        // 设置窗口底部那行「版本 x · 构建 y」——用户报 bug 时唯一能给出的定位信息。
        //
        // ⚠️ **这个值取决于跑法**：`.app` 里读到的是 Info.plist 的真值；
        // 直接跑 `.build/debug/DiskEjectorApp`（本自检的常规跑法）时 `Bundle.main`
        // 没有那两个键，界面会落到兜底值 `1.0.0` / `1` —— **这是预期，不是 bug**。
        // 所以这里只**打印**并说明来源，不当断言（否则每次跑自检都会假红）。
        // 真值的守卫在 `AppVersionInfoTests`（含一条读打包产物的断言）。
        // ⚠️ 「（兜底）」只能标在**真的用了兜底值**的那一项上。
        // 第一版把后缀无条件拼在 `?? "1.0.0"` 之后，读到真值时也显示「兜底」——
        // 一条会骗人的诊断输出比没有诊断更糟。
        let short = AppVersionInfo.shortVersion()
        let build = AppVersionInfo.build()
        let source =
            Bundle.main.bundleIdentifier == nil
            ? "裸可执行，读不到 Info.plist，界面显示兜底值（预期）"
            : "从 .app 的 Info.plist 读取"
        print(
            "    版本行：\(short ?? "1.0.0")\(short == nil ? "（兜底）" : "")"
                + " · \(build ?? "1")\(build == nil ? "（兜底）" : "")"
                + " · bundle=\(Bundle.main.bundlePath)（\(source)）")

        // 版本行下方那条「本次构建含 N 处未提交改动」——只在 `DEBuildDirtyCount > 0` 时出现。
        //
        // 与版本行同理：裸可执行读不到这两个键 → 不显示，**这是预期**，所以只打印不当断言。
        // 这条输出真正的价值在于**从 `/Applications/DiskEjector.app` 跑**时能看到它确实会显示 ——
        // 也就是证明「版本号看着像 tag 那次正式构建、实际跑的却是工作区」这件事
        // 在界面上被说清楚了。不打印的话，这个功能从命令行完全看不出有没有生效。
        if let dirty = AppVersionInfo.dirtyCount() {
            if dirty > 0 {
                print(
                    "    脏构建提示行："
                        + String(
                            format: L10n.tr(.versionDirtyNoticeFormat), dirty,
                            AppVersionInfo.commit() ?? "—"))
            } else {
                print("    脏构建提示行：不显示（工作区干净，dirty=0）")
            }
        } else {
            print("    脏构建提示行：不显示（读不到 DEBuildDirtyCount —— 裸可执行下预期）")
        }

        // 1 · 窗口尺寸
        let expected = DesignTokens.Size.settingsPanel
        if abs(window.frame.width - expected.width) > 0.5
            || abs(window.frame.height - expected.height) > 0.5
        {
            mismatches.append(
                "A 窗口应为 \(expected.width)×\(expected.height)，实得 "
                    + "\(window.frame.width)×\(window.frame.height)"
                    + "（多出来的高度就是标题栏安全区 32pt）")
        }

        // 2 · 玻璃铺满整个内容区。留 0.5pt 容差给坐标取整。
        let tolerance: CGFloat = 0.5
        if ours.isEmpty || contentRect.height <= 0 {
            mismatches.append("A 没找到设置窗口的自定义玻璃（material=.underWindowBackground）—— 背景没铺上")
        } else {
            let covers =
                covered.minX <= contentRect.minX + tolerance
                && covered.minY <= contentRect.minY + tolerance
                && covered.maxX >= contentRect.maxX - tolerance
                && covered.maxY >= contentRect.maxY - tolerance
            if !covers {
                mismatches.append(
                    "A 玻璃只覆盖 \(covered)，未铺满内容区 \(contentRect) —— "
                        + "上/下缺口 \(contentRect.minY - covered.minY) / "
                        + "\(contentRect.maxY - covered.maxY)pt（顶部 32pt 安全区就是红绿灯那一带）")
            }
        }

        // 3 · 系统标题栏的标题必须隐藏
        if window.titleVisibility != .hidden {
            mismatches.append(
                "A 系统标题栏标题未隐藏（titleVisibility=\(window.titleVisibility.rawValue)）—— "
                    + "会与面板自己头部的「设置」重复")
        }

        // 4 · 三个系统按钮必须都藏着（照设计稿：设置面板不画红绿灯）。
        //
        // **只能真机验**：`standardWindowButton(_:)` 属于「窗口」，离屏没有窗口就没有按钮可问。
        // 而它恰恰是本轮要守的东西 —— 一旦被改回可见，用户看到的就又是「红灯 + 完成」
        // 两个功能相同的出口。
        let traffic = zip(["红", "黄", "绿"], SettingsWindow.hiddenButtonTypes).map {
            name, type -> String in
            guard let button = window.standardWindowButton(type) else { return "\(name)=无此按钮" }
            return "\(name)=\(button.isHidden ? "已隐藏" : "仍在画")"
        }
        print("    系统按钮=\(traffic.joined(separator: " "))")
        if !SettingsWindow.standardButtonsAreHidden(in: window) {
            mismatches.append(
                "A 设置窗口还在画系统交通灯（\(traffic.joined(separator: " "))）—— "
                    + "设计稿的 `.shead` 里没有 traffic，红绿灯的关窗与头部的「完成」是"
                    + "同一个动作的两个出口（用户 2026-09-16 报告）")
        }
    }
}
