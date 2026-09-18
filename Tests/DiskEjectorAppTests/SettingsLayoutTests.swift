import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 设置面板的**排版契约**测试。
///
/// **为什么需要**：面板高度是常量，六段内容的自然高度却随文案与内边距变化。
/// 历史上两者脱节（内容约 718pt vs 面板 520pt），结果是「关于 / 更新」两段被折叠线
/// 挡在滚动区外 —— 用户打开设置看不到它们，反馈为「设置界面排版不好看」。
/// 光靠人眼打开面板看一遍发现不了「几乎溢出」，所以把三件事钉成测试：
/// ① 头部 + 六段内容 + 底部留白 必须 ≤ 面板高度（放不下就会有内容被藏）；
/// ② 面板高度也不许虚高（差距超过一行就该同步收窄 token，而不是留一片空白）；
/// ③ 分隔线只出现在**段与段之间**（第一段上方不该有一条线顶着头部）。
///
/// 高度断言用「≤」而不是「==」：中文与英文文案长度不同，折行数可能不同，
/// 只要**任何语言下都放得下**就成立（`SettingsView` 仍保留 `ScrollView` 兜底）。
@MainActor
struct SettingsLayoutTests {

    private let panelWidth = DesignTokens.Size.settingsPanel.width

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/SettingsLayoutTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 从 CSS 文本里取 `token` **之后**第一个 `<数字>px`。
    ///
    /// ⚠️ 只在 token 之后找 —— `ds.css` 的 token 上方有一大段解释性注释（里面也写着 800 / 826），
    /// 全文搜数字会搜到注释里的那个，然后「改代码不改注释」也会绿。
    private func pxValue(in css: String, token: String) -> Double? {
        guard let t = css.range(of: token) else { return nil }
        let rest = css[t.upperBound...]
        guard
            let m = rest.range(of: #"[0-9]+(?:\.[0-9]+)?px"#, options: .regularExpression)
        else { return nil }
        return Double(rest[m].dropLast(2))
    }

    /// 在给定宽度下渲染并返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    ///
    /// ⚠️ **必须用 `sizeThatFits(in:)`，不能用 `setFrameSize + fittingSize`**（2026-09-15 修正）。
    /// `NSHostingView.fittingSize` 返回的是**无宽度约束的理想尺寸** —— 宽度根本没生效。
    /// 实测同一份内容：`fittingSize` 报 `497×470`（宽度 497 ≠ 传入的 440），
    /// `sizeThatFits(in: 440×∞)` 报 `440×484`。
    ///
    /// 这个差别**恰好掩盖了一整类缺陷**：内容横向放不下时，弹性列（设置行的标签列）
    /// 会被压窄、文字改竖排，高度随之暴涨 —— 但理想尺寸里没有这回事，高度看着一直正常。
    /// 旧写法因此让「视觉效果」那行被压成竖排单字、内容真实高度 910pt 而面板只有 498pt
    /// 可用（45% 内容被卷走）长达一整个版本没被发现。
    ///
    /// 手法可靠性用**已知高度的磁盘行**做过对照（真值 158pt）：
    /// `sizeThatFits` → 158 ✓ ／ `fittingSize` → 158（高度对但宽度错）／ 位图扫描 → 369 ✗
    /// （`bitmapImageRepForCachingDisplay` 的缓冲区不保证清零，会扫到未初始化内存）。
    ///
    /// ⚠️ **在中文下渲染**：本文件断言的面板尺寸（480×800）是**按中英实测**出来的，
    /// 其中宽度按英文定、高度按英文 782.6 + 余量定。
    /// 不钉就跟随 `Locale.current` → 英文机器上必红（2026-09-17 CI 连续 6 次红即此因）。
    /// 英文下的表现由本文件的 ``英文下也必须放得下()`` 覆盖。
    ///
    /// ⚠️ **`view` 必须是 `@autoclosure`**：实参表达式在**进入本函数之前**求值，
    /// 而它可能含 `L10n.tr`（分区标题、行标签 …），不推迟求值就会解析成 `Locale.current` 的
    /// 那一版，钉住渲染也救不回来。理由同 `OnboardingLayoutTests.renderedSize`。
    private func renderedSize<V: View>(
        _ view: @autoclosure () -> V,
        width: CGFloat,
        language: String = TestLanguage.design
    ) -> CGSize {
        TestLanguage.with(language) {
            _ = NSApplication.shared
            let hosting = NSHostingController(rootView: view())
            return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
    }

    /// 渲染成位图后，统计**卡片内部的行间分隔线**条数。
    ///
    /// **为什么不能用「整行都有 alpha」来判定**：v2 的设置项放在 `.scard` 里
    /// （`bg-raised` 实心填充），卡片内**每一行**都是不透明的 —— 按老办法会把
    /// 卡片的每一行都数成分隔线（实测 298 条）。
    ///
    /// 现在的判据是「**相对上下都变暗、且横向均匀**」：
    /// - 分隔线是 8% 黑叠在白色卡片上 → 比上下都暗一点点，且横向亮度方差接近 0；
    /// - 卡片填充行 → 与上下同色，不构成凹陷；
    /// - 文字行 → 横向亮度方差很大（黑字 + 白底），被方差条件排除；
    /// - 卡片自身的圆角描边行 → 上下相邻行里有一行落在卡片外（覆盖率不足），被邻居条件排除。
    private func horizontalDividerCount(_ view: some View, width: CGFloat) -> Int {
        _ = NSApplication.shared
        // 高度取 `sizeThatFits` 的**真实**高度（理由见 `renderedSize` 注释）：
        // 用 `fittingSize` 会拿到偏小的理想高度，把内容底部裁掉，
        // 万一分隔线正好落在被裁区域就会漏数。
        let realHeight = renderedSize(view, width: width).height
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: max(realHeight, 10))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            let data = rep.bitmapData
        else { return -1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel

        /// 逐行统计：覆盖率（alpha > 8 的像素占比）与不透明像素的亮度均值/标准差。
        func rowStats(_ y: Int) -> (coverage: Double, luma: Double, std: Double) {
            var opaque = 0
            var covered = 0
            var sum = 0.0
            var sumSq = 0.0
            for x in 0..<w {
                let p = y * bpr + x * spp
                let a = data[p + 3]
                if a > 8 { covered += 1 }
                guard a > 200 else { continue }
                let luma =
                    0.2126 * Double(data[p]) + 0.7152 * Double(data[p + 1])
                    + 0.0722 * Double(data[p + 2])
                opaque += 1
                sum += luma
                sumSq += luma * luma
            }
            guard opaque > 0 else { return (Double(covered) / Double(w), 0, 0) }
            let mean = sum / Double(opaque)
            let variance = max(0, sumSq / Double(opaque) - mean * mean)
            return (Double(covered) / Double(w), mean, variance.squareRoot())
        }

        let stats = (0..<h).map(rowStats)
        let gap = 4
        var dividerRows: [Int] = []
        for y in gap..<(h - gap) {
            guard stats[y].coverage > 0.85,
                stats[y - gap].coverage > 0.85,
                stats[y + gap].coverage > 0.85
            else { continue }
            // 横向必须均匀（排除文字行），且比上下都暗（排除填充行）。
            guard stats[y].std < 2.5,
                stats[y].luma < stats[y - gap].luma - 1,
                stats[y].luma < stats[y + gap].luma - 1
            else { continue }
            dividerRows.append(y)
        }
        // 相邻像素行合并成一条线。
        //
        // ⚠️ **不能用 `y != previous + 1` 这种「严格相邻」判据**（2026-09-15 修正）。
        // 一条 0.5pt 的分隔线在 scale=2 的位图里是 1 个像素，但**抗锯齿会把它的
        // 上下各染一个半透明像素**，实测三行的亮度是 `250.95 / 238.95 / 250.95`
        // （上下两行只比卡片底色 254.95 暗 4）。这三行**全都**满足「比上下都暗」
        // 的判据，于是进入 `dividerRows`。旧写法只在计数时推进 `previous`，
        // 遇到 `[246, 247, 248]` 会数成 2 条（246 计一次、247 被吞、248 又计一次）——
        // 两根真实分隔线被数成 4 条，测试报「多画了线」而产品其实完全正确。
        //
        // 正确判据是「**与上一条线的距离超过一根线的像素跨度**」：
        // 同一根线内部的行间隔 ≤ 2 个像素，而真实两根线至少隔着一个行高（≈44pt ≈ 88px）。
        // 阈值取 `4 × scale`（2pt）—— 远大于抗锯齿跨度、远小于行高，中间有两个数量级的余量。
        let scale = max(1, w / max(1, Int(width)))
        let mergeGap = 4 * scale
        var count = 0
        var previous = -1_000
        for y in dividerRows {
            if y - previous > mergeGap { count += 1 }
            previous = y
        }
        return count
    }

    /// 离屏渲染，返回**首列有墨迹的 x（pt）**与**末列有墨迹的 x（pt）**。
    ///
    /// **为什么非要量像素**：SwiftUI 的 `Text` 在 AppKit 视图树里**没有任何对应视图** ——
    /// 实测 `NSHostingView` 的 `subviews` 是空的、整棵树里找不到 `NSTextField`，
    /// 无障碍子树也是懒建的（`accessibilityChildren` 返回 nil）。
    /// 所以「标题从第几列开始」问不到 AppKit，只能看**渲染结果**。
    ///
    /// **判据是「相对白底变暗」而不是看 alpha**：先给视图垫一层 `Color.white`，
    /// 每个像素都是不透明的，`colorAt` 拿到的就是真实渲染色。
    /// （`bitmapImageRepForCachingDisplay` 的缓冲区**不保证清零**，所以这里显式
    /// `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 让系统分配一块干净的，
    /// 并用 `colorAt` 而不是直接读 `bitmapData` —— 后者会扫到未初始化内存。）
    ///
    /// **扫描带取 y ∈ [8, 44]**（52pt 头部的中段）：**必须避开底部那条 `Hairline`** ——
    /// 它横跨整宽，会把 x=0 也算成墨迹。
    ///
    /// - Returns: `(first, last)`；没扫到任何墨迹时返回 `nil`。
    private func inkColumnRange(
        _ view: some View, width: CGFloat, height: CGFloat
    ) -> (first: CGFloat, last: CGFloat)? {
        _ = NSApplication.shared
        let scale: CGFloat = 2
        let hosting = NSHostingView(rootView: view.background(Color.white))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(width * scale),
                pixelsHigh: Int(height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        rep.size = CGSize(width: width, height: height)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let rows = Int(8 * scale)..<Int(44 * scale)
        var first: Int?
        var last: Int?
        for x in 0..<rep.pixelsWide {
            let hasInk = rows.contains { y in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return c.redComponent < 0.75 || c.greenComponent < 0.75 || c.blueComponent < 0.75
            }
            if hasInk {
                if first == nil { first = x }
                last = x
            }
        }
        guard let first, let last else { return nil }
        return (CGFloat(first) / scale, CGFloat(last) / scale)
    }

    @Test func 面板高度放得下头部与全部四组() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth)
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        #expect(
            need <= DesignTokens.Size.settingsPanel.height,
            "头部 \(header.height) + 内容 \(sections.height) + 底留白 \(SettingsMetrics.bottomInset) = \(need)pt，超过面板 \(DesignTokens.Size.settingsPanel.height)pt——多出来的部分会被折叠线藏在滚动区外（「关于」曾因此整个看不见）"
        )
    }

    @Test func 面板高度不留大片空白() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth)
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        let slack = DesignTokens.Size.settingsPanel.height - need
        #expect(
            slack >= 0 && slack <= 40,
            "面板比内容高出 \(slack)pt（超过一行）。要么把 DesignTokens.Size.settingsPanel.height 收窄到 \(need)pt，要么补内容——否则面板底部会留下一条明显的空白带"
        )
    }

    /// 英文下也必须放得下。
    ///
    /// **这条原来在 `LanguageLayoutGapTests` 里，而且是一条「已知缺陷」的锁**：
    /// 2026-09-17 实测英文需要 612.25pt、容器只有 566pt，那条测试专门断言
    /// 「英文确实放不下」，并写明「修好后它会变红，提醒你删掉它」。
    ///
    /// 2026-09-18 面板加宽到 480（临界宽度 477）+ 加高到 800 之后，它**如期变红**
    /// —— 于是按它自己写的要求，把设置面板那两条从 `LanguageLayoutGapTests` 摘掉，
    /// 英文覆盖**并入本文件**：从「记录缺陷」变成「必须通过的门槛」。
    ///
    /// （`LanguageLayoutGapTests` 没有整个删掉 —— 它还有一条**引导面板**的英文缺陷是活的。）
    @Test func 英文下也必须放得下() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth, language: "en")
        let sections = renderedSize(
            SettingsSectionsColumn { _ in }, width: panelWidth, language: "en")
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        print(
            "  [设置面板] 英文需要 \(need)pt，容器 \(DesignTokens.Size.settingsPanel.height)pt"
        )
        #expect(
            need <= DesignTokens.Size.settingsPanel.height,
            "英文下头部 \(header.height) + 内容 \(sections.height) + 底留白 \(SettingsMetrics.bottomInset) = \(need)pt，超过面板 \(DesignTokens.Size.settingsPanel.height)pt —— 英文文案最长，是**最坏情况**，容器必须按它定"
        )
    }

    /// 面板尺寸的**依据**：中文必须与设计稿几乎逐点相同。
    ///
    /// 这一条是上面两条「放得下」的**前提校验**。只有「≤ 容器」时，
    /// 把内容整体缩小（字号、内边距改小）也能让断言变绿 —— 而那是排版走样，不是修好了。
    /// 所以这里钉住绝对值：**中文下实现与设计稿的差必须 ≤ 2pt**。
    ///
    /// 实测（2026-09-18，设计稿用无头 Chrome 探针量，实现用 `sizeThatFits`）：
    ///
    /// | | 中文 | 英文 |
    /// |---|---|---|
    /// | 设计稿（CSS） | 766.44 | 814.25 |
    /// | 实现（SwiftUI） | **766.60** | **782.60** |
    ///
    /// 中文差 **0.16pt** → 结构忠实；英文差 31.65pt → CSS 与 CoreText 的英文断行差异
    /// （本仓库已记为「已知不是 bug」）。
    /// ⚠️ 量设计稿时**必须先把 `.settings__body` 的 `flex: 1 1 auto` 关掉** ——
    /// 它被拉伸填满面板，直接量到的是「被撑开的高度」（面板高 − 52），不是内容自然高度。
    /// 2026-09-18 之前设计稿写的是 826（= 它自己 Chrome 口径的英文自然高 814.25 + 余量），
    /// 它对自己的渲染没错，**但对实现偏大**：照它做会在中文下留 59.4pt 空白带。
    /// → 已拍板把设计稿同步成 800（§8.43），两份文档现在同数，
    /// 由 ``设计稿与实现的面板尺寸必须同数()`` 钉住。
    @Test func 中文高度与设计稿几乎逐点相同() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth)
        let zh = header.height + sections.height + SettingsMetrics.bottomInset
        let en =
            renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth, language: "en").height
            + renderedSize(SettingsSectionsColumn { _ in }, width: panelWidth, language: "en").height
            + SettingsMetrics.bottomInset
        print(
            "  [设置面板] 实现 中文 \(zh) / 英文 \(en) ｜ 设计稿 中文 766.44 / 英文 814.25 ｜ "
                + "面板 \(DesignTokens.Size.settingsPanel.width)×\(DesignTokens.Size.settingsPanel.height)"
        )
        #expect(
            abs(zh - 766.44) <= 2,
            """
            中文下需要 \(zh)pt，设计稿实测 766.44pt。差得超过 2pt 说明**结构**变了
            （少/多一行、组间距或内边距改动），不只是英文折行差异 —— 请同步复核设计稿与面板尺寸。
            """
        )
        // 「英文更长」是上面那条「英文是最坏情况」的前提。不成立只有两种可能：
        // ① 钉语言失效；② 英文文案缺失、`tr` 回退到中文源语言。**都不是「缺陷被修好」**。
        #expect(en > zh, "英文（\(en)）没比中文（\(zh)）高 —— 检查 L10n.forcedLocale 是否还能传到渲染")
    }

    /// 设计稿的 `--w-settings` / `--h-settings` 与实现的面板尺寸**必须同数**。
    ///
    /// **为什么需要**：这两份数字曾经分叉了整整一轮 —— 设计稿写 826、实现写 800，
    /// 双方各自的文档里都留着一句「另一边还没同步，待拍板」，
    /// 而**没有任何机制会提醒谁去还这笔账**（2026-09-18 拍板统一成 800，见 §8.43）。
    /// 这一条负责让它们**不再分叉**：改任何一边而忘了另一边，这里立刻红。
    ///
    /// ⚠️ 读的是**设计稿的源文件**（`ds.css`），不是常量自己跟自己比 —— 那是没牙的断言
    /// （`UpdateFeedTests` 读 `build_app.sh` 是同一个道理：唯一真相在别处时，测试就得去读那里）。
    ///
    /// ⚠️ 判据只能是「**两边相等**」，**不能写成「等于 800」**：
    /// 后者在有人把两边**同时**改成 900 时依然会红 —— 那是假失败，会把下一个人引向错误方向。
    @Test func 设计稿与实现的面板尺寸必须同数() throws {
        let css = try String(
            contentsOf: repoRoot.appendingPathComponent("DiskEjector-UI-Design/v2/assets/ds.css"),
            encoding: .utf8)
        let designW = try #require(
            pxValue(in: css, token: "--w-settings:"), "ds.css 里找不到 --w-settings 的 px 值")
        let designH = try #require(
            pxValue(in: css, token: "--h-settings:"), "ds.css 里找不到 --h-settings 的 px 值")
        print(
            "  [设置面板] 设计稿 \(designW)×\(designH) ｜ "
                + "实现 \(DesignTokens.Size.settingsPanel.width)×\(DesignTokens.Size.settingsPanel.height)"
        )
        #expect(
            designW == Double(DesignTokens.Size.settingsPanel.width),
            "设计稿 --w-settings = \(designW)px，实现 settingsPanel.width = \(DesignTokens.Size.settingsPanel.width)pt —— 两边必须同数"
        )
        #expect(
            designH == Double(DesignTokens.Size.settingsPanel.height),
            """
            设计稿 --h-settings = \(designH)px，实现 settingsPanel.height = \
            \(DesignTokens.Size.settingsPanel.height)pt —— 两边必须同数。
            这两份数字曾经分叉一整轮（826 vs 800）而没人还账（§8.43）。改一边就改另一边。
            """
        )
    }

    /// 「更新」行**七态渲染出来必须一样高**。
    ///
    /// **为什么**：这一行是设置面板里**唯一**会在运行中换画法的行 ——
    /// 其余行的形态由偏好决定，只有它随事件（检查中 / 下载中 / 已就绪 / 失败…）变形。
    /// 而面板是**固定高度**的：只要有一态比别的高，切到那一态时要么多出一条空白带、
    /// 要么把最后一行挤到折叠线外（历史上「关于」整段就是这样消失的，见文件头）。
    /// 「下载中」那一态尤其危险 —— 它多画了一条轨道 + 一个百分比。
    ///
    /// ⚠️ 这条断言**与渲染机器无关**（只比七个高度互相相等，不比绝对值），所以能进 CI。
    /// 七态的出图进不了 CI（`DE_SNAPSHOTS=1` 才跑）→ **光出图不补守卫等于没补**（§8.33）。
    @Test func 更新行七态渲染出来必须一样高() {
        let lastCheck = Date(timeIntervalSince1970: 1_789_000_000)
        func row(_ phase: UpdatePhase, skipped: String? = nil) -> UpdateController.CheckRowState {
            UpdateController.rowState(phase: phase, skippedVersion: skipped, lastCheck: lastCheck)
        }
        let states: [(String, UpdateController.CheckRowState)] = [
            ("尚未检查", UpdateController.rowState(phase: .idle, skippedVersion: nil, lastCheck: nil)),
            ("已是最新", row(.idle)),
            ("已跳过", row(.idle, skipped: "1.1.0")),
            ("发现新版本", row(.found(version: "1.1.0"))),
            ("下载中", row(.downloading(version: "1.1.0", fraction: 0.42))),
            ("已就绪", row(.ready(version: "1.1.0"))),
            ("失败", row(.failed(version: "1.1.0"))),
        ]

        var heights: [(String, CGFloat)] = []
        for (name, state) in states {
            let h = renderedSize(
                SettingsSectionsColumn(updateStateOverride: state), width: panelWidth
            ).height
            heights.append((name, h))
        }
        let printed = heights.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [更新行七态] \(printed)")

        // 判据是「**七个互相相等**」，不是「等于某个数」—— 后者会把「整体挪了 1pt」
        // 报成七条失败，而真正要防的是**某一态与别的不一样**。
        let first = heights[0].1
        for (name, h) in heights.dropFirst() {
            #expect(
                abs(h - first) <= 0.5,
                """
                「\(name)」渲染出来 \(h)pt，而「\(heights[0].0)」是 \(first)pt —— 七态必须一样高。
                设置面板是固定高度：某一态更高就会挤掉最后一行（或留出空白带）。
                全部七态：\(printed)
                """
            )
        }
    }

    /// 「自动更新」行**三种形态渲染出来必须一样高**。
    ///
    /// 与上面那条同一个理由：面板是固定高度。而这一行的说明是**整句替换**的
    /// （`autoUpdateHint` ↔ `autoUpdateUnavailableHint`）—— 换长了就可能多折一行，
    /// 把最后一行挤出折叠线。这三态在真机上都会出现（未签名构建恒为「不允许」）。
    @Test func 自动更新行三态渲染出来必须一样高() {
        let states: [(String, AutoUpdateRowState)] = [
            ("开 · 允许", AutoUpdateRowState(isOn: true, isAllowed: true)),
            ("关 · 允许", AutoUpdateRowState(isOn: false, isAllowed: true)),
            ("关 · 不允许", AutoUpdateRowState(isOn: false, isAllowed: false)),
        ]

        var heights: [(String, CGFloat)] = []
        for (name, state) in states {
            let h = renderedSize(
                SettingsSectionsColumn(autoUpdateRowOverride: state), width: panelWidth
            ).height
            heights.append((name, h))
        }
        let printed = heights.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [自动更新行三态] \(printed)")

        let first = heights[0].1
        for (name, h) in heights.dropFirst() {
            #expect(
                abs(h - first) <= 0.5,
                """
                「\(name)」渲染出来 \(h)pt，而「\(heights[0].0)」是 \(first)pt —— 三态必须一样高。
                说明文案是整句替换的，长了就会多折一行、把最后一行挤出折叠线。
                全部三态：\(printed)
                """
            )
        }
    }

    @Test func 分段控件不许吃掉标签列的宽度() {
        _ = NSApplication.shared
        let control = SettingsSegmentedControl(
            options: VisualStyle.allCases.map { ($0.rawValue, $0.shortName, $0.displayName) },
            selection: .constant(VisualStyle.default.rawValue),
            accent: .default
        )
        // 量**固有宽度**：提案给无穷大，控件才会报出自己真正想要的宽度。
        // （若按面板宽 440 去提案，`.fixedSize()` 会被裁到 440，量不出溢出。）
        let hosting = NSHostingController(rootView: control)
        let ideal = hosting.sizeThatFits(
            in: CGSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))

        // 行内可用宽 ≈ 面板宽 − 卡片与行的左右内边距；留一半以上给标签列。
        let budget = panelWidth * 0.45
        #expect(
            ideal.width <= budget,
            """
            分段控件固有宽 \(Int(ideal.width))pt，超过预算 \(Int(budget))pt（面板的 45%）。\
            它末尾带 `.fixedSize()`，**不可压缩**——同行的标签列是 `maxWidth: .infinity` 的弹性列，\
            会独吞这个差额并被压成竖排单字（2026-09-15 实测：长标签让该行理想宽 745pt vs 面板 440pt，\
            内容真实高度 910pt vs 可用 498pt）。可见标签必须用 `VisualStyle.shortName`（「透明」/「色调」）。
            """
        )
    }

    @Test func 分隔线只画在卡片内的行与行之间() {
        // 外观卡 2 行 → 1 条；通用卡 3 行 → 2 条；诊断卡 1 行 → 0 条；更新卡 2 行 → 1 条。合计 4 条。
        // 首行上方那条要是画出来，卡片会被一条横线从顶部切开；
        // 卡片自身的圆角描边不算行间分隔线（检测器已按「上下都变暗」排除）。
        //
        // ⚠️ **这个数会随「每张卡几行」变**：加一行就要 +1。
        // 它抓的是「某张卡的首行上方也画了线」——那种错会让总数**多**出来，
        // 而少画一条（卡片看起来糊成一块）同样要被抓到。
        let count = horizontalDividerCount(SettingsSectionsColumn { _ in }, width: panelWidth)
        #expect(
            count == 4,
            "测到 \(count) 条卡片内行间分隔线，期望 4 条（外观 1 + 通用 2 + 更新 1；诊断只有一行，不画线）。数目不符说明某张卡的首行上方也画了线，或某条行间线没画出来"
        )
    }

    // MARK: 头部与设计稿内边距

    /// 头部标题的**渲染起点**必须等于设计稿的内边距（`.shead { padding: 0 16px }`）。
    ///
    /// **必须量渲染结果**：拿 `SettingsMetrics` 里的常量跟自己比是**没牙的**。
    /// 本项目踩过 —— 这条测试原先判的是「红绿灯有没有压住标题」，用的常量
    /// `headerTitleMinX` 本身就是从让位宽度算出来的，于是**删掉视图里那句让位它照样是绿的**。
    /// 后来改成量墨迹；2026-09-16 让位连同红绿灯一起删掉（`DESIGN-SPEC.md` §8.17），
    /// 期望值也跟着变成**前导内边距本身**。
    ///
    /// 实测（离屏，scale 2）：前导 16 → 首列墨迹 **16.0pt**（2026-09-16 本轮实测，最右 412.5）；
    /// 让位还在时（前导 20 + 让位 52 + 间距 8）→ **80.0pt**。
    /// 上界 +6 是给字形侧边距留的：中文「设」几乎贴边，英文 "Settings" 的 `S` 会再右偏一点。
    /// 下界 −1 是抗锯齿。
    @Test func 头部标题渲染起点等于设计稿内边距() {
        let range = inkColumnRange(
            SettingsHeaderBar(onDone: {}),
            width: panelWidth,
            height: SettingsMetrics.headerHeight)
        guard let range else {
            Issue.record("头部离屏渲染后没扫到任何墨迹 —— 渲染本身没成功，这条断言不能算通过")
            return
        }

        // 自证：右半侧也该有墨迹（「完成」按钮）。两侧都扫到，才说明渲出的是一整个头部，
        // 而不是某个只画了一半的半成品（量到半成品会得出错误基准值）。
        #expect(
            range.last > panelWidth / 2,
            "最右侧墨迹只到 \(range.last)pt（面板宽 \(panelWidth)）—— 渲染不完整，下面的断言无意义"
        )

        let expected = SettingsMetrics.headerPaddingLeading
        // 把量到的数打出来 —— 像素量测最容易的失败方式是「量错了东西」，
        // 有这两个数才能当场分辨「对齐坏了」和「扫描带落在空白上」。
        print("  [设置面板头部] 首列墨迹 \(range.first)pt、最右 \(range.last)pt（期望首列 ≈ \(expected)）")
        #expect(
            range.first >= expected - 1 && range.first <= expected + 6,
            """
            标题首列墨迹在 \(range.first)pt，设计稿内边距 \(expected)pt。\
            偏大（≈20.0）说明前导内边距被改回了 20；再大（≈80.0）说明红绿灯让位块又回来了 —— \
            设计稿的 `.shead` 里没有 traffic；偏小则说明内边距被改小。
            """
        )
    }

    /// 「后台下载中」那一行的进度条**固定 16pt 高**，与说明行同高。
    ///
    /// 设计稿 `08-update.html` B3 的 spec-note 点名要求「进度条外层固定 16pt，
    /// 与 `.sline__desc` 同一行高，**下载中这一行不会被撑高**」。
    ///
    /// **为什么必须钉**：不钉的话，把外层高度去掉（只留 5pt 轨道 + 文字行盒）
    /// 会让整块设置面板在下载过程中**跳一下** —— 而这件事只在真机下载时看得到，
    /// 离屏出图与其它单测都不会红。
    @Test func 行内进度条固定16pt高() {
        let size = renderedSize(SettingsProgressLine(fraction: 0.42), width: 200)
        #expect(
            size.height == DesignTokens.Size.settingsProgressLineHeight,
            "行内进度条渲染出来 \(size.height)pt，不是固定的 \(DesignTokens.Size.settingsProgressLineHeight)pt")
        #expect(
            DesignTokens.Size.settingsProgressLineHeight == 16,
            "设计稿写的是 16 —— 改这个数要同时改设计稿 B3 的 spec-note")
    }
}
